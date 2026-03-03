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

- **`flux/`** — манифесты стека и источников (точка входа — `flux/kustomization.yaml`):
  - [flux/sources.yaml](flux/sources.yaml) — `HelmRepository` для чартов VictoriaMetrics;
  - [flux/namespaces.yaml](flux/namespaces.yaml) — неймспейс `vmks`;
  - [flux/vmks-helmrelease.yaml](flux/vmks-helmrelease.yaml) — `HelmRelease` victoria-metrics-k8s-stack;
  - [flux/vmks-values.yaml](flux/vmks-values.yaml) — values для Helm (Kustomize собирает из него ConfigMap);
  - [flux/kustomization.yaml](flux/kustomization.yaml) — сборка ресурсов и ConfigMap с values.

Все перечисленные файлы создаются вручную и коммитятся в Git до выполнения `flux bootstrap`.

### Bootstrap (если Flux ещё не установлен)

Пример для GitHub:

```bash
flux bootstrap github \
  --owner=patsevanton \
  --repository=fluxcd-operator-and-status-page \
  --branch=main \
  --path=flux
```

При таком вызове Flux создаёт в кластере только **GitRepository** и **Kustomization**; файлы в репозитории он не создаёт (их добавляют по списку выше).

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

FluxInstance должен указывать на тот же репозиторий и путь, что и текущий bootstrap (чтобы применялся тот же `flux/kustomization.yaml`).

Скопируйте пример и подставьте свой URL и ветку:

```bash
cp flux/flux-instance-example.yaml flux-instance.yaml
# Отредактируйте url, ref и при необходимости pullSecret
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
    path: "flux"
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

Если ранее использовался `flux bootstrap`, в Git мог появиться каталог `flux-system/` с манифестами Flux. После успешной миграции на Flux Operator эти манифесты можно удалить из репозитория — компоненты Flux теперь управляются оператором. Подробнее: [Flux Bootstrap Migration](https://fluxcd.control-plane.io/operator/flux-bootstrap-migration).

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

Параметры (реплики, лимиты, ingress) задаются в [flux/vmks-values.yaml](flux/vmks-values.yaml). Расширенный пример values с комментариями по нагрузке — [vmks-values.yaml](vmks-values.yaml) в корне.

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
