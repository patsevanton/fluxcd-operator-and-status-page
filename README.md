# От Flux CLI к Flux Operator и Status Page: один репозиторий — полный путь

Когда вы впервые поднимаете GitOps в Kubernetes, **Flux CD** кажется достаточным: `flux bootstrap`, манифесты в Git, контроллеры тянут состояние кластера. Со временем появляется желание **централизованно** управлять версиями дистрибутива Flux, упростить миграции и получить **наглядную картину** синхронизации — без ручного запуска `flux get all -A`.

В этом материале зафиксирован путь от классического bootstrap к **[Flux Operator](https://fluxoperator.dev/)** с ресурсом **FluxInstance**, подключённому FluxCD Status Page и типичному «продуктовому» стеку вокруг observability и релизов (VictoriaMetrics, логи, сертификаты, безопасность, эксперименты с нагрузкой).

Ниже — суть подхода, [структура репозитория](#как-устроен-репозиторий) и пошаговые команды. Про **FluxReport**, события и метрики Status Page — [отдельный раздел](#fluxcd-status-page); полный перечень приложений — [в таблице стека](#развёрнутый-стек).


## Зачем такая схема

Классический bootstrap отлично **заводит** кластер, но операторский слой даёт:

- предсказуемое описание **дистрибутива** Flux (версия, реестр, набор контроллеров);
- единый объект **синхронизации** с Git (`FluxInstance.spec.sync`) вместо ручной связки нескольких манифестов;
- **встроенную наблюдаемость** — отчёты и веб-интерфейс поверх того же состояния кластера.

Репозиторий специально держит **и** legacy-путь (`base/flux-system/` с `gotk-*`), **и** путь миграции через `FluxInstance`, чтобы читатель мог воспроизвести переход по шагам, а не только увидеть «финальный» снимок.


## Как устроен репозиторий

| Путь | Роль |
|------|------|
| [base/apps.yaml](base/apps.yaml) | Отдельные Flux `Kustomization` на каталоги `apps/<имя>` |
| [base/flux-system/](base/flux-system/) | Компоненты Flux (`gotk-components.yaml`), [gotk-sync.yaml](base/flux-system/gotk-sync.yaml) — `GitRepository` + `Kustomization` с `path: ./base` |
| [apps/](apps/) | Манифесты приложений; [apps/kustomization.yaml](apps/kustomization.yaml) — для локального `kustomize build apps/` |

Типичный пример связки Helm: VictoriaMetrics — [apps/victoria-metrics/sources.yaml](apps/victoria-metrics/sources.yaml) (`HelmRepository`), [namespaces.yaml](apps/victoria-metrics/namespaces.yaml), [helmrelease.yaml](apps/victoria-metrics/helmrelease.yaml).

**Нюанс раскладки:** при первом `flux bootstrap` CLI по умолчанию кладёт `flux-system/` в корень репозитория; здесь манифесты Flux уже лежат в **`base/flux-system/`**. Содержимое `base/` и `apps/` вы коммитите в Git до или после bootstrap — главное, чтобы путь в bootstrap совпадал с тем, что ожидает кластер.


## Часть 1. Классический Flux: bootstrap и приложения

### Предварительные условия

- Чистый кластер Kubernetes.
- **Flux CLI** — [Installing the Flux CLI](https://fluxcd.io/flux/installation/). Проверка: `flux version --client`.
- Доступ к Git-репозиторию для `flux bootstrap`; при необходимости — PAT (см. ниже).

### GitHub Personal Access Token для bootstrap

Для `flux bootstrap github` токен передаётся через `GITHUB_TOKEN` или вводится в интерактиве.

![Создание PAT (Fine-grained token)](docs/github-pat-creation.png)

1. [GitHub → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new).
2. **Repository access** — только нужный репозиторий (например `fluxcd-operator-and-status-page`).
3. **Permissions:** **Contents** — Read and write; **Metadata** — Read-only; **Administration** — Read-only.

С флагом `--token-auth` Flux сохраняет PAT в Secret в кластере; для PAT достаточно **Administration → Read-only**.

### Команда bootstrap

```bash
flux bootstrap github \
  --token-auth \
  --owner=patsevanton \
  --repository=fluxcd-operator-and-status-page \
  --branch=main \
  --path=base
```

Ожидаемый результат: контроллеры Flux в `flux-system`, коммиты sync-манифестов, **GitRepository** + **Kustomization** на каталог **`base/`**.

Фрагмент типичного вывода:

```
Please enter your GitHub personal access token (PAT):
► connecting to github.com
► cloning branch "main" from Git repository "https://github.com/patsevanton/fluxcd-operator-and-status-page.git"
✔ cloned repository
...
✔ all components are healthy
```

### Проверка после bootstrap

```bash
kubectl get pods -n vmks
flux get helmreleases -n flux-system
flux get kustomizations -A
```


## Часть 2. Переход на Flux Operator

Имеет смысл делать **после** успешного bootstrap и когда классический Flux уже синхронизирует ваши приложения. Манифесты приложений в Git можно не трогать: меняется способ установки и конфигурации **самих** компонентов Flux.

### Установка Flux Operator

Чтобы **helm-controller** ставил оператор из Git (OCI-чарт и `HelmRelease`), создайте каталог **`apps/flux-operator`** и два файла с содержимым ниже.

**`apps/flux-operator/sources.yaml`**

```yaml
# OCI Helm-репозиторий ControlPlane (чарт flux-operator).
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cp-flux-operator
  namespace: flux-system
spec:
  interval: 24h
  type: oci
  url: oci://ghcr.io/controlplaneio-fluxcd/charts
```

**`apps/flux-operator/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 30m
  timeout: 10m
  chart:
    spec:
      chart: flux-operator
      version: "0.47.0"
      sourceRef:
        kind: HelmRepository
        name: cp-flux-operator
        namespace: flux-system
      interval: 30m
  releaseName: flux-operator
  values:
    web:
      enabled: true
      config:
        baseURL: http://flux.apatsev.org.ru/
      ingress:
        enabled: true
        className: nginx
        hosts:
          - host: flux.apatsev.org.ru
            paths:
              - path: /
                pathType: Prefix
```

В [base/apps.yaml](https://github.com/patsevanton/fluxcd-operator-and-status-page/blob/main/base/apps.yaml) ресурс **`Kustomization`** `flux-operator` по умолчанию закомментирован. Чтобы включить GitOps-путь, **удалите** закомментированный блок и **вставьте** на его место (между `falco` и `goldpinger`) следующий текст:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  serviceAccountName: kustomize-controller
  path: ./apps/flux-operator
  prune: true
  wait: true
  timeout: 10m
```

1. Сохраните [base/apps.yaml](https://github.com/patsevanton/fluxcd-operator-and-status-page/blob/main/base/apps.yaml) с этим блоком вместо закомментированного.
2. Закоммитьте изменения и дождитесь синхронизации: `flux get kustomizations -n flux-system`, `flux get helmreleases -n flux-system`.

Проверка: `flux get helmreleases -n flux-system` (релиз `flux-operator`). Версия чарта и `values` задаются в манифестах под `apps/flux-operator/`.

Установка оператора не через этот репозиторий — в [документации Flux Operator](https://fluxoperator.dev/docs/guides/install/) (Helm, kubectl, Terraform и др.).

### Создание FluxInstance

Укажите тот же репозиторий и ветку, что и при bootstrap. Минимальный пример для публичного Git:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.8.x"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  sync:
    kind: GitRepository
    url: "https://github.com/patsevanton/fluxcd-operator-and-status-page.git"
    ref: "refs/heads/main"
    path: "."
```

Сохраните в `flux-instance.yaml`, при необходимости отредактируйте `url`, `ref`; для приватного репозитория используйте `spec.sync.pullSecret` — [документация](https://fluxoperator.dev/docs/instance/sync/#sync-from-a-git-repository).

```bash
kubectl apply -f flux-instance.yaml
```

### Проверка миграции

```bash
kubectl -n flux-system get fluxinstance flux
kubectl -n flux-system get pods
flux get kustomizations -A
flux get helmreleases -A
```

### Очистка репозитория после миграции

Удалите артефакты классического bootstrap, перенесите `flux-instance.yaml` в GitOps (например в `base/flux-system/`), обновите [base/flux-system/kustomization.yaml](base/flux-system/kustomization.yaml) так, чтобы остался только `flux-instance.yaml`.

Если в `flux-instance` был `path: "."`, после переноса в дерево под `base/` задайте **`path: "./base"`**, как в прежнем `gotk-sync.yaml`, чтобы синхронизация шла из `base/`.

Подробнее: [Flux Bootstrap Migration](https://fluxcd.control-plane.io/operator/flux-bootstrap-migration).

```bash
git rm base/flux-system/gotk-components.yaml
git rm base/flux-system/gotk-sync.yaml
mv flux-instance.yaml base/flux-system/
git add base/flux-system/flux-instance.yaml
```

Пример `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- flux-instance.yaml
```


## FluxCD Status Page

После установки Flux Operator в игру входят **FluxReport**, события по `FluxInstance` и метрики Prometheus.

**Демо-интерфейс:** [http://flux.apatsev.org.ru/](http://flux.apatsev.org.ru/) — host и `baseURL` задаются в [apps/flux-operator/helmrelease.yaml](apps/flux-operator/helmrelease.yaml).

### Скриншоты

Файлы удобно складывать в [docs/screenshots/](docs/screenshots/).

| Описание | Файл |
|----------|------|
| Status Page — обзор | `docs/screenshots/flux-status-page-overview.png` |
| Dashboard / Mission Control (если включён) | `docs/screenshots/flux-dashboard.png` |

![FluxCD Status Page — обзор](docs/screenshots/flux-status-page-overview.png)

![Flux CD dashboard / Mission Control](docs/screenshots/flux-dashboard.png)

### FluxReport

Ресурс `FluxReport` `flux` в `flux-system` (обновление по умолчанию раз в 5 минут):

```bash
kubectl -n flux-system get fluxreport/flux -o yaml
```

Принудительное обновление:

```bash
kubectl -n flux-system annotate --overwrite fluxreport/flux \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

[Flux Report API](https://fluxoperator.dev/docs/crd/fluxreport).

### События

```bash
kubectl -n flux-system events --for fluxinstance/flux
```

Уведомления (Slack, Teams и др.) — через notification-controller, [Provider/Alert](https://fluxoperator.dev/docs/crd/provider).

### Метрики

Сервис `flux-operator`, порт **8080**. Чтобы изменить параметры чарта (например интервал отчёта `reporting.interval`), отредактируйте `spec.values` в [apps/flux-operator/helmrelease.yaml](apps/flux-operator/helmrelease.yaml) и закоммитьте.

Для Prometheus Operator: `serviceMonitor.create=true` в `values`. Подробнее: [Flux Monitoring and Reporting](https://fluxcd.control-plane.io/operator/monitoring).


## Развёрнутый стек

Состав задаётся в [base/apps.yaml](base/apps.yaml).

| Компонент | Namespace | Назначение |
|-----------|------------|------------|
| Flux Operator | flux-system | Оператор Flux, Mission Control, [Status Page](http://flux.apatsev.org.ru/) |
| VictoriaMetrics K8s Stack | vmks | VMSingle, vmagent, vmalert, Alertmanager, Grafana |
| VictoriaLogs | vlogs | Логи (single-node) |
| Vector | vector | Сбор логов в VictoriaLogs |
| cert-manager | cert-manager | TLS |
| External Secrets Operator | external-secrets | Секреты из внешних хранилищ |
| Blackbox Exporter | blackbox-exporter | HTTP/TCP пробы |
| Goldpinger | goldpinger | Связность между нодами |
| Prometheus Adapter | prometheus-adapter | Custom Metrics API для HPA |
| KEDA | keda | Автомасштабирование |
| Kubernetes Descheduler | descheduler | Перераспределение подов |
| Reloader | reloader | Перезапуск при смене ConfigMap/Secret |
| Falco | falco | Runtime security |
| Argo Rollouts | argo-rollouts | Canary / blue-green |
| Chaos Mesh | chaos-mesh | Хаос-инжиниринг |

Параметры VictoriaMetrics — `spec.values` в [apps/victoria-metrics/helmrelease.yaml](apps/victoria-metrics/helmrelease.yaml).


## Полезные команды

```bash
flux get sources helm
flux get helmreleases -A
flux get kustomizations -A
flux logs --all-namespaces --follow
kubectl get pods -n vmks
```


## Устранение неполадок

| Симптом | Что проверить |
|---------|----------------|
| `GitRepository` / `Kustomization` не Ready | `flux get sources git -A`, `kubectl describe gitrepository -n flux-system`, сеть и права PAT / deploy key |
| HelmRelease завис | `flux get helmreleases -A`, логи `helm-controller`, значения в `HelmRelease` |
| После миграции не применяется `base/` | В `FluxInstance.spec.sync.path` должно быть `./base`, если манифесты лежат под `base/` |
| Нет метрик оператора | Service `flux-operator`, порт 8080; при необходимости `ServiceMonitor` |


## Метрики и Grafana

[VictoriaMetrics K8s Stack](https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-metrics-k8s-stack) поднимает **Grafana** вместе с vmagent, VMSingle и правилами алертинга: в интерфейсе открываются готовые дашборды по Kubernetes и целям сбора метрик, можно строить свои запросы к тем же данным, что пишет VictoriaMetrics.

**Веб-доступ:** в этом репозитории для Grafana включён Ingress — [https://grafana.apatsev.org.ru](https://grafana.apatsev.org.ru) (см. [apps/victoria-metrics/helmrelease.yaml](apps/victoria-metrics/helmrelease.yaml)). Локально без Ingress: `kubectl port-forward -n vmks svc/vmks-grafana 3000:80` и открыть [http://127.0.0.1:3000](http://127.0.0.1:3000); логин по умолчанию — `admin`.

Пароль администратора Grafana:

```bash
kubectl get secret vmks-grafana -n vmks -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```


## Ссылки

- [Installing the Flux CLI](https://fluxcd.io/flux/installation/)
- [Flux Documentation](https://fluxcd.io/flux/)
- [Flux Get Started](https://fluxcd.io/flux/get-started/)
- [Manage Helm Releases](https://fluxcd.io/flux/guides/helmreleases/)
- [Flux Operator — Installation](https://fluxoperator.dev/docs/guides/install/)
- [Flux Operator — Cluster sync (GitRepository)](https://fluxoperator.dev/docs/instance/sync/)
- [Flux Bootstrap Migration](https://fluxcd.control-plane.io/operator/flux-bootstrap-migration)
- [Flux Monitoring and Reporting](https://fluxcd.control-plane.io/operator/monitoring)
- [VictoriaMetrics Helm Charts](https://github.com/VictoriaMetrics/helm-charts)
