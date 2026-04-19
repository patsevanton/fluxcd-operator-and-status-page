# Миграция на FluxCD Operator и обзор FluxCD Status Page

GitOps-репозиторий для кластера Kubernetes: классический Flux CD (bootstrap), переход на **Flux Operator** с **FluxInstance**, веб-интерфейс **FluxCD Status Page** и набор приложений (observability, безопасность, релизы).

## Возможности

- **Классический Flux CD** — `HelmRepository`, `HelmRelease`, `Kustomization` из Git (`base/apps.yaml`, каталоги `apps/<имя>`).
- **Flux Operator** — единая конфигурация через `FluxInstance`, опционально Mission Control.
- **Status Page** — отчёт FluxReport, события, метрики Prometheus (см. раздел [FluxCD Status Page](#fluxcd-status-page)).
- **Стек приложений** — VictoriaMetrics K8s Stack, VictoriaLogs, Vector, cert-manager, Argo Rollouts, Falco, KEDA, Chaos Mesh и др. (полный список — [ниже](#развёрнутый-стек)).

## Предварительные требования

- Чистый кластер Kubernetes.
- **Flux CLI** — [Installing the Flux CLI](https://fluxcd.io/flux/installation/). Проверка: `flux version --client`.
- Доступ к Git-репозиторию для `flux bootstrap`; при необходимости — PAT (раздел [PAT для bootstrap](#github-personal-access-token-pat-для-bootstrap)).

## Структура репозитория

| Путь | Назначение |
|------|------------|
| [base/apps.yaml](base/apps.yaml) | Отдельные Flux `Kustomization` на каталоги `apps/<имя>` |
| [base/flux-system/](base/flux-system/) | Компоненты Flux (`gotk-components.yaml`), [gotk-sync.yaml](base/flux-system/gotk-sync.yaml) — GitRepository + Kustomization с `path: ./base` |
| [apps/](apps/) | Манифесты приложений; [apps/kustomization.yaml](apps/kustomization.yaml) — для локального `kustomize build apps/` |

Пример стека VictoriaMetrics: [apps/victoria-metrics/sources.yaml](apps/victoria-metrics/sources.yaml) (`HelmRepository`), [namespaces.yaml](apps/victoria-metrics/namespaces.yaml), [helmrelease.yaml](apps/victoria-metrics/helmrelease.yaml).

При первом `flux bootstrap` CLI по умолчанию создаёт `flux-system/` в корне; здесь манифесты Flux уже лежат в **`base/flux-system/`**. Манифесты приложений и раскладку `base/` / `apps/` коммитят вручную до или после bootstrap.

## 1. Классический Flux CD: bootstrap и приложения

### GitHub Personal Access Token (PAT) для bootstrap

Для `flux bootstrap github` передайте токен через `GITHUB_TOKEN` или введите при запросе.

![Создание PAT (Fine-grained token)](docs/github-pat-creation.png)

1. [GitHub → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new).
2. **Repository access** — только нужный репозиторий (например `fluxcd-operator-and-status-page`).
3. **Permissions:** **Contents** — Read and write; **Metadata** — Read-only; **Administration** — Read-only.

С `--token-auth` Flux хранит PAT в Secret в кластере; для PAT достаточно **Administration → Read-only**.

### Bootstrap

```bash
flux bootstrap github \
  --token-auth \
  --owner=patsevanton \
  --repository=fluxcd-operator-and-status-page \
  --branch=main \
  --path=base
```

Ожидаемый результат: контроллеры Flux в `flux-system`, коммиты sync-манифестов, **GitRepository** + **Kustomization** на каталог **`base/`**.

Пример вывода (фрагмент):

```
Please enter your GitHub personal access token (PAT):
► connecting to github.com
► cloning branch "main" from Git repository "https://github.com/patsevanton/fluxcd-operator-and-status-page.git"
✔ cloned repository
...
✔ all components are healthy
```

### Проверка

```bash
kubectl get pods -n vmks
flux get helmreleases -n flux-system
flux get kustomizations -A
```

Пароль Grafana:

```bash
kubectl get secret vmks-grafana -n vmks -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

## 2. Переход на Flux Operator

Выполняйте после успешного bootstrap и работающего классического Flux. Манифесты приложений в Git не меняются; меняется способ установки и конфигурации компонентов Flux.

### Установить Flux Operator

```bash
helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace
```

Проверка: `helm list -n flux-system`. Другие способы: [kubectl](https://fluxoperator.dev/docs/guides/install/#kubectl), [Terraform](https://fluxoperator.dev/docs/guides/install/#terraform), [flux-operator CLI](https://fluxoperator.dev/docs/guides/install/#flux-operator-cli).

### Создать FluxInstance

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

Сохраните в `flux-instance.yaml`, при необходимости отредактируйте `url`, `ref`, для приватного репозитория — `spec.sync.pullSecret` ([документация](https://fluxoperator.dev/docs/instance/sync/#sync-from-a-git-repository)).

```bash
kubectl apply -f flux-instance.yaml
```

### Проверить миграцию

```bash
kubectl -n flux-system get fluxinstance flux
kubectl -n flux-system get pods
flux get kustomizations -A
flux get helmreleases -A
```

### Очистка репозитория после миграции

Удалите артефакты классического bootstrap, перенесите `flux-instance.yaml` в GitOps (например в `base/flux-system/`), обновите [base/flux-system/kustomization.yaml](base/flux-system/kustomization.yaml) — только `flux-instance.yaml`.

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

После установки Flux Operator доступны **FluxReport**, события по `FluxInstance` и метрики Prometheus.

**Веб-интерфейс:** [http://flux.apatsev.org.ru/](http://flux.apatsev.org.ru/) — host и `baseURL` в [apps/flux-operator/helmrelease.yaml](apps/flux-operator/helmrelease.yaml).

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

Сервис `flux-operator`, порт **8080**. Пример уменьшения интервала отчёта:

```bash
helm upgrade flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --set reporting.interval=30s
```

Для Prometheus Operator: `serviceMonitor.create=true`. Подробнее: [Flux Monitoring and Reporting](https://fluxcd.control-plane.io/operator/monitoring).

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
