# Миграция на FluxCD Operator и обзор FluxCD Status Page

## Цель проекта

Мигрировать управление кластером с **классического FluxCD** на **Flux Operator**: единая точка настройки через FluxInstance, использование Mission Control и сохранение GitOps. В качестве примера разворачивается стек мониторинга **victoria-metrics-k8s-stack** (VictoriaMetrics VMSingle по умолчанию чарта, Grafana, Alertmanager).

### Последовательность шагов (обязательный порядок)

1. **Установить консольный Flux (Flux CLI)** — бинарник `flux` на машине, с которой выполняется bootstrap и дальнейшие команды. Без CLI нельзя выполнить `flux bootstrap` и проверять состояние кластера стандартными командами `flux get …`.
2. **Развернуть классический Flux в кластере** — `flux bootstrap` (или эквивалент), чтобы в кластере появились контроллеры Flux и синхронизация с Git (раздел [1](#1-приложения-через-классический-fluxcd)).
3. **Мигрировать на Flux Operator** — установка оператора, `FluxInstance` и перенос управления компонентами Flux на оператор (раздел [2](#2-переход-со-классического-fluxcd-на-flux-operator)).

Сначала всегда полноценный «классический» FluxCD через CLI и bootstrap; переход на оператор — отдельный этап после этого.

В репозитории описаны четыре части:

1. **Приложения через классический FluxCD** — классический GitOps: HelmRepository + HelmRelease.
2. **Переход на Flux Operator** — замена классического FluxCD на управление через [Flux Operator](https://fluxoperator.dev/) (Mission Control, единая точка управления).
3. **Обзор FluxCD Status Page** — единый отчёт о состоянии Flux (FluxReport), события, метрики и мониторинг.
4. Нотификации через alertmanager.

## 1. Приложения через классический FluxCD

Приложения разворачиваются классическими средствами FluxCD: источник чартов (HelmRepository), релиз (HelmRelease), Kustomization применяет манифесты из Git.

### Предусловия

- Чистый кластер Kubernetes.
- **Установлен Flux CLI** (консольный `flux`): см. [Installing the Flux CLI](https://fluxcd.io/flux/installation/). Проверка: `flux version --client`.
- Доступ к репозиторию Git (для `flux bootstrap`) и при необходимости PAT, как в разделе [GitHub Personal Access Token](#github-personal-access-token-pat-для-bootstrap).

После установки CLI следующий шаг — **bootstrap** (ниже), который ставит в кластер классический Flux; миграция на Flux Operator выполняется позже, по разделу [2](#2-переход-со-классического-fluxcd-на-flux-operator).

### Структура репозитория (Flux)

- **`base/kustomization.yaml`** — точка входа kustomize для синхронизации из каталога **`base/`** (`--path=base`): подключает [base/flux-system/](base/flux-system/) и каталог [base/flux-apps/](base/flux-apps/) с отдельными Flux `Kustomization` на каждое приложение (`path: ./apps/<имя>`).
- **`base/flux-system/`** — компоненты Flux (`gotk-components.yaml`), [gotk-sync.yaml](base/flux-system/gotk-sync.yaml) (GitRepository + Kustomization с `path: ./base`).
- **`apps/`** — манифесты приложений по подкаталогам; корневой [apps/kustomization.yaml](apps/kustomization.yaml) объединяет их для локальной сборки `kustomize build apps/`, в кластер же каждый подкаталог синхронизируется своим Flux `Kustomization` из `base/flux-apps/`. Для стека VictoriaMetrics:
  - [apps/victoria-metrics/sources.yaml](apps/victoria-metrics/sources.yaml) — `HelmRepository` VictoriaMetrics;
  - [apps/victoria-metrics/namespaces.yaml](apps/victoria-metrics/namespaces.yaml) — неймспейс `vmks`;
  - [apps/victoria-metrics/helmrelease.yaml](apps/victoria-metrics/helmrelease.yaml) — `HelmRelease` victoria-metrics-k8s-stack (`spec.values`);
  - [apps/victoria-metrics/kustomization.yaml](apps/victoria-metrics/kustomization.yaml) — сборка этого приложения.

При первом **`flux bootstrap`** CLI по умолчанию создаёт каталог `flux-system/` в корне; в этом репозитории манифесты Flux лежат в **`base/flux-system/`** (уже в Git). До bootstrap вручную коммитятся пользовательские манифесты (`apps/`, `base/flux-apps/` и т.д.).


### GitHub Personal Access Token (PAT) для bootstrap

Flux при `flux bootstrap github` запрашивает доступ к репозиторию. Токен можно передать переменной `GITHUB_TOKEN` или ввести при запросе.

**Создание PAT:**

![Создание PAT (Fine-grained token)](docs/github-pat-creation.png)

1. Откройте: [GitHub → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new).
2. **Repository access:** только нужный репозиторий (например `fluxcd-operator-and-status-page`).
3. **Permissions:**
   - **Contents** — Read and write (коммиты манифестов Flux).
   - **Metadata** — Read-only.
   - **Administration** — Read-only (доступ к API настроек репозитория).

Скопируйте токен и при запросе вставьте в `Please enter your GitHub personal access token (PAT):`

### Bootstrap

Флаг **`--token-auth`** указывается в той же команде при запуске bootstrap (см. ниже). С ним Flux сохраняет PAT в Kubernetes-кластере (в Secret) и использует его для доступа к Git (вместо создания deploy key). Тогда для PAT достаточно **Administration → Read-only**.

```bash
flux bootstrap github \
  --token-auth \
  --owner=patsevanton \
  --repository=fluxcd-operator-and-status-page \
  --branch=main \
  --path=base
```

Вывод примерно вот такой
```
Please enter your GitHub personal access token (PAT):
► connecting to github.com
► cloning branch "main" from Git repository "https://github.com/patsevanton/fluxcd-operator-and-status-page.git"
✔ cloned repository
► generating component manifests
✔ generated component manifests
✔ committed component manifests to "main" ("f9688b07b0b68cf20be87f921af6ba15dd01bb3b")
► pushing component manifests to "https://github.com/patsevanton/fluxcd-operator-and-status-page.git"
► installing components in "flux-system" namespace
✔ installed components
✔ reconciled components
► determining if source secret "flux-system/flux-system" exists
► generating source secret
► applying source secret "flux-system/flux-system"
✔ reconciled source secret
► generating sync manifests
✔ generated sync manifests
✔ committed sync manifests to "main" ("2fa415b4e32fd9331c9621e8e28429e0e3cf1a44")
► pushing sync manifests to "https://github.com/patsevanton/fluxcd-operator-and-status-page.git"
► applying sync manifests
✔ reconciled sync configuration
◎ waiting for GitRepository "flux-system/flux-system" to be reconciled
✔ GitRepository reconciled successfully
◎ waiting for Kustomization "flux-system/flux-system" to be reconciled
✔ Kustomization reconciled successfully
► confirming components are healthy
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all components are healthy
```

При таком вызове Flux устанавливает в кластере свои компоненты (контроллеры), коммитит манифесты синхронизации и настраивает **GitRepository** + **Kustomization** на синхронизацию из каталога **`base/`** (`--path=base`). Манифесты приложений и раскладку `base/` / `apps/` Flux не генерирует — их добавляют вручную до или после bootstrap.

### Проверка после реконсиляции

```bash
kubectl get pods -n vmks
flux get helmreleases -n flux-system
flux get kustomizations -A
```

Пароль Grafana:

```bash
kubectl get secret vmks-grafana -n vmks -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

## 2. Переход со классического FluxCD на Flux Operator

Этот раздел выполняется **только после** того, как установлен Flux CLI, выполнен `flux bootstrap` и в кластере работает классический Flux (и при желании уже развёрнуты приложения из части 1).

После того как стек уже развёрнут через классический FluxCD (часть 1), кластер можно перевести на управление через **Flux Operator**: оператор устанавливает и обновляет компоненты Flux, даёт единую точку конфигурации (FluxInstance) и при необходимости — [Mission Control](https://fluxoperator.dev/docs/) (веб-интерфейс).

Манифесты приложений (в т.ч. HelmRelease для vmks) остаются в Git; меняется только то, *кто* запускает Flux и откуда берётся конфигурация (из того же репозитория).

### Шаги миграции

#### 1. Установить Flux Operator

В тот же namespace, где работает Flux (обычно `flux-system`). **Первая установка и обновление чарта** — одной командой (`upgrade --install` не падает, если релиз уже есть; при необходимости зафиксируйте версию: `--version 0.47.0`):

```bash
helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace
```

Проверить существующий релиз: `helm list -n flux-system`. Если нужно поставить заново с нуля: `helm uninstall flux-operator -n flux-system`, затем снова команда выше.

Другие способы: [kubectl](https://fluxoperator.dev/docs/guides/install/#kubectl), [Terraform](https://fluxoperator.dev/docs/guides/install/#terraform), [CLI flux-operator](https://fluxoperator.dev/docs/guides/install/#flux-operator-cli).

#### 2. Создать FluxInstance

FluxInstance должен указывать на тот же репозиторий и путь, что и текущий bootstrap (в этом README — корень репозитория, `path: "."`).

Создайте `flux-instance.yaml` и подставьте свой URL и ветку:

```bash
touch flux-instance.yaml
# Добавьте манифест ниже, затем отредактируйте url, ref и при необходимости pullSecret
```

Пример минимальной конфигурации (публичный Git):

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

Для приватного репозитория создайте secret в `flux-system` и укажите `spec.sync.pullSecret` (см. [документацию](https://fluxoperator.dev/docs/instance/sync/#sync-from-a-git-repository)).

Применить:

```bash
kubectl apply -f flux-instance.yaml
```

#### 3. Проверить миграцию

```bash
kubectl -n flux-system get fluxinstance flux
kubectl -n flux-system get pods
flux get kustomizations -A
flux get helmreleases -A
```

После перехода управление Flux переходит к оператору; GitRepository и Kustomization для пути `path` создаются оператором. Рабочие нагрузки (в т.ч. victoria-metrics-k8s-stack в `vmks`) продолжают реконсилироваться из того же Git.

#### 4. (Опционально) Очистка репозитория

Если ранее использовался `flux bootstrap`, в Git появляется каталог `flux-system/` (часто в корне; в этом репозитории аналог — `base/flux-system/`). После успешной миграции на Flux Operator эти манифесты можно удалить из репозитория — компоненты Flux теперь управляются оператором. Подробнее: [Flux Bootstrap Migration](https://fluxcd.control-plane.io/operator/flux-bootstrap-migration).

## 3. Обзор FluxCD Status Page

Flux Operator даёт единую картину состояния Flux в кластере: отчёт (FluxReport), события и метрики Prometheus. Это удобно для мониторинга и поиска причин сбоев.

**Status Page в браузере:** веб-интерфейс открывается по адресу [http://flux.apatsev.org.ru/](http://flux.apatsev.org.ru/). Host и `baseURL` заданы в [apps/flux-operator/helmrelease.yaml](apps/flux-operator/helmrelease.yaml) (`web.config.baseURL` и `ingress.hosts`).

### FluxReport — единый отчёт о состоянии Flux

Оператор автоматически создаёт ресурс **FluxReport** (имя `flux` в namespace `flux-system`). В отчёте отображаются:

- готовность компонентов Flux (source-controller, kustomize-controller, helm-controller и др.);
- сведения о дистрибутиве (версия, registry);
- статистика реконсилеров;
- статус синхронизации кластера с Git.

Отчёт обновляется по расписанию (по умолчанию раз в 5 минут). Просмотр в YAML:

```bash
kubectl -n flux-system get fluxreport/flux -o yaml
```

Принудительное обновление отчёта:

```bash
kubectl -n flux-system annotate --overwrite fluxreport/flux \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

Подробнее: [Flux Report API](https://fluxoperator.dev/docs/crd/fluxreport).

### События FluxInstance

Оператор пишет события в API сервер Kubernetes по жизненному циклу FluxInstance. Просмотр:

```bash
kubectl -n flux-system events --for fluxinstance/flux
```

Через notification-controller можно настроить уведомления (Slack, Teams, Grafana и др.) по событиям FluxInstance — см. [документацию по Alert/Provider](https://fluxoperator.dev/docs/crd/provider).

### Метрики Prometheus

Flux Operator отдаёт метрики в формате Prometheus на порту **8080** (Service `flux-operator`). Доступны метрики по FluxInstance, ресурсам Flux (GitRepository, Kustomization, HelmRelease и т.д.) и контроллеру. При использовании Prometheus имеет смысл уменьшить интервал отчёта до 30s:

```bash
helm upgrade flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --set reporting.interval=30s
```

На кластерах с Prometheus Operator можно создать ServiceMonitor для автоматического сбора метрик; в Helm-чарте оператора есть опция `serviceMonitor.create=true`. Подробнее: [Flux Monitoring and Reporting](https://fluxcd.control-plane.io/operator/monitoring).

## Развёрнутый стек (кратко)

Состав приложений задаётся в [base/flux-apps/kustomization.yaml](base/flux-apps/kustomization.yaml) (отдельные Flux `Kustomization` на каждый каталог в `apps/`).

| Компонент | Namespace | Назначение |
| --------- | --------- | ---------- |
| Flux Operator | flux-system | Оператор Flux, Mission Control и [Status Page](http://flux.apatsev.org.ru/) |
| VictoriaMetrics K8s Stack | vmks | VMSingle, vmagent, vmalert, Alertmanager, Grafana |
| VictoriaLogs | vlogs | Хранение и запрос логов (single-node) |
| Vector | vector | Сбор и маршрутизация логов в VictoriaLogs |
| cert-manager | cert-manager | Автоматизация TLS-сертификатов |
| External Secrets Operator | external-secrets | Секреты из внешних хранилищ |
| Blackbox Exporter | blackbox-exporter | Blackbox-пробы (HTTP/TCP и др.) |
| Goldpinger | goldpinger | Проверка сетевой связности между нодами |
| Prometheus Adapter | prometheus-adapter | Custom Metrics API для HPA |
| KEDA | keda | Event-driven и метрик-based автомасштабирование |
| Kubernetes Descheduler | descheduler | Перераспределение подов по политикам |
| Reloader | reloader | Перезапуск workload при смене ConfigMap/Secret |
| Falco | falco | Обнаружение угроз в рантайме |
| Argo Rollouts | argo-rollouts | Canary / blue-green и прогрессивные релизы |
| Chaos Mesh | chaos-mesh | Хаос-инжиниринг и отказоустойчивость |

Параметры VictoriaMetrics (реплики, лимиты, ingress) — в `spec.values` [apps/victoria-metrics/helmrelease.yaml](apps/victoria-metrics/helmrelease.yaml).

## Полезные команды

- Статус Flux (источники, Kustomization, HelmRelease):
  ```bash
  flux get sources helm
  flux get helmreleases -A
  flux get kustomizations -A
  ```
- Логи контроллеров Flux:
  ```bash
  flux logs --all-namespaces --follow
  ```
- Проверка подов и релизов:
  ```bash
  kubectl get pods -n vmks
  ```

## Ссылки

- [Installing the Flux CLI](https://fluxcd.io/flux/installation/) (консольный `flux` — шаг до bootstrap)
- [Flux Documentation](https://fluxcd.io/flux/)
- [Flux Get Started](https://fluxcd.io/flux/get-started/)
- [Manage Helm Releases (Flux)](https://fluxcd.io/flux/guides/helmreleases/)
- [Flux Operator — Installation](https://fluxoperator.dev/docs/guides/install/)
- [Flux Operator — Cluster sync (GitRepository)](https://fluxoperator.dev/docs/instance/sync/)
- [Flux Bootstrap Migration (to Flux Operator)](https://fluxcd.control-plane.io/operator/flux-bootstrap-migration)
- [Flux Monitoring and Reporting (Status Page, FluxReport)](https://fluxcd.control-plane.io/operator/monitoring)
- [VictoriaMetrics Helm Charts](https://github.com/VictoriaMetrics/helm-charts)
