# Миграция на FluxCD Operator и обзор FluxCD Status Page

## Цель проекта

Мигрировать управление кластером с **классического FluxCD** на **Flux Operator**: единая точка настройки через FluxInstance, использование Mission Control и сохранение GitOps. В качестве примера разворачивается стек мониторинга **victoria-metrics-k8s-stack** (VictoriaMetrics, Grafana, Alertmanager).

В репозитории описаны четыре части:

1. **Установка victoria-metrics-k8s-stack через классический FluxCD** — классический GitOps: HelmRepository + HelmRelease.
2. **Переход на Flux Operator** — замена классического FluxCD на управление через [Flux Operator](https://fluxoperator.dev/) (Mission Control, единая точка управления).
3. **Обзор FluxCD Status Page** — единый отчёт о состоянии Flux (FluxReport), события, метрики и мониторинг.
4. Нотификации через alertmanager.

## 1. Установка victoria-metrics-k8s-stack через классический FluxCD

Сначала стек ставится классическими средствами FluxCD: источник чартов (HelmRepository), релиз (HelmRelease), Kustomization применяет манифесты из Git.

### Предусловия

- Чистый кластер Kubernetes.
- Бинарник FluxCD установлен локально

### Структура репозитория (Flux)

- **`apps/`** — манифесты стека и источников (точка входа — `apps/kustomization.yaml`):
  - [apps/sources.yaml](apps/sources.yaml) — `HelmRepository` для чартов VictoriaMetrics;
  - [apps/namespaces.yaml](apps/namespaces.yaml) — неймспейс `vmks`;
  - [apps/vmks-helmrelease.yaml](apps/vmks-helmrelease.yaml) — `HelmRelease` victoria-metrics-k8s-stack (values заданы в `spec.values`);
  - [apps/kustomization.yaml](apps/kustomization.yaml) — сборка ресурсов.

Каталог `flux/` оставляется под служебные манифесты самого Flux (`gotk-*`), чтобы не смешивать их с манифестами приложений.

Все перечисленные файлы создаются вручную и коммитятся в Git до выполнения `flux bootstrap`.

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
  --path=apps
```

Вывод примерно вот такой
```
Please enter your GitHub personal access token (PAT):
► connecting to github.com
► cloning branch "main" from Git repository "https://github.com/patsevanton/fluxcd-operator-and-status-page.git"
✔ cloned repository
► generating component manifests
✔ generated component manifests
✔ committed component manifests to "main" ("144985eeefc3ca7459adf6c5f739613b0f04cdd0")
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
✔ committed sync manifests to "main" ("5dfb679970b8d39ac6df490b2100f6977b7df056")
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

При таком вызове Flux устанавливает в кластере свои компоненты (контроллеры) и создаёт ресурсы **GitRepository** и **Kustomization** для синхронизации из этого репозитория. Манифесты приложения (`apps/sources.yaml`, `apps/vmks-helmrelease.yaml`, `apps/kustomization.yaml` и т.д.) в репозитории Flux не создаёт — их добавляют вручную по списку выше до bootstrap.

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

После того как victoria-metrics-k8s-stack уже развёрнут через классический FluxCD (часть 1), кластер можно перевести на управление через **Flux Operator**: оператор устанавливает и обновляет компоненты Flux, даёт единую точку конфигурации (FluxInstance) и при необходимости — [Mission Control](https://fluxoperator.dev/docs/) (веб-интерфейс).

Манифесты приложений (в т.ч. HelmRelease для vmks) остаются в Git; меняется только то, *кто* запускает Flux и откуда берётся конфигурация (из того же репозитория).

### Шаги миграции

#### 1. Установить Flux Operator

В тот же namespace, где работает Flux (обычно `flux-system`):

```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace
```

Другие способы: [kubectl](https://fluxoperator.dev/docs/guides/install/#kubectl), [Terraform](https://fluxoperator.dev/docs/guides/install/#terraform), [CLI flux-operator](https://fluxoperator.dev/docs/guides/install/#flux-operator-cli).

#### 2. Создать FluxInstance

FluxInstance должен указывать на тот же репозиторий и путь, что и текущий bootstrap (чтобы применялся тот же `apps/kustomization.yaml`).

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
    version: "2.7.x"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  sync:
    kind: GitRepository
    url: "https://github.com/YOUR_ORG/fluxcd-operator-and-status-page.git"
    ref: "refs/heads/main"
    path: "apps"
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

Если ранее использовался `flux bootstrap`, в Git мог появиться каталог `apps/flux-system/` с манифестами Flux. После успешной миграции на Flux Operator эти манифесты можно удалить из репозитория — компоненты Flux теперь управляются оператором. Подробнее: [Flux Bootstrap Migration](https://fluxcd.control-plane.io/operator/flux-bootstrap-migration).

## 3. Обзор FluxCD Status Page

Flux Operator даёт единую картину состояния Flux в кластере: отчёт (FluxReport), события и метрики Prometheus. Это удобно для мониторинга и поиска причин сбоев.

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

| Компонент                 | Namespace   | Назначение                                      |
|||--|
| VictoriaMetrics K8s Stack | vmks       | VMCluster, vmalert, vmagent, Alertmanager, Grafana |

Параметры (реплики, лимиты, ingress) задаются в `spec.values` манифеста [apps/vmks-helmrelease.yaml](apps/vmks-helmrelease.yaml). Расширенный пример values с комментариями по нагрузке — [vmks-values.yaml](vmks-values.yaml) в корне.

## Инфраструктура (Terraform)

- `k8s.tf` — managed Kubernetes cluster (Yandex Cloud);
- `net.tf` — VPC и подсети;
- `ip-dns.tf` — внешний IP при необходимости.

После изменений: `terraform plan` / `terraform apply`. Подключение к кластеру — по команде из output (`yc managed-kubernetes cluster get-credentials ...`).

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

- [Flux Documentation](https://fluxcd.io/flux/)
- [Flux Get Started](https://fluxcd.io/flux/get-started/)
- [Manage Helm Releases (Flux)](https://fluxcd.io/flux/guides/helmreleases/)
- [Flux Operator — Installation](https://fluxoperator.dev/docs/guides/install/)
- [Flux Operator — Cluster sync (GitRepository)](https://fluxoperator.dev/docs/instance/sync/)
- [Flux Bootstrap Migration (to Flux Operator)](https://fluxcd.control-plane.io/operator/flux-bootstrap-migration)
- [Flux Monitoring and Reporting (Status Page, FluxReport)](https://fluxcd.control-plane.io/operator/monitoring)
- [VictoriaMetrics Helm Charts](https://github.com/VictoriaMetrics/helm-charts)
