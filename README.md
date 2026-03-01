# Flux CD: Status Page и установка стека через GitOps

## О проекте

Проект посвящён **Flux CD** (GitOps для Kubernetes) и обзору того, как следить за статусом реконсиляции и состоянием развёрнутых приложений («status page»). В этом репозитории через Flux устанавливаются:

- **victoria-metrics-k8s-stack** — Helm-чарт (метрики, алерты, Grafana).

Инфраструктура (кластер, сеть) описана в Terraform (Yandex Cloud).

---

## Flux CD и «Status Page»

### Что такое Flux CD

[Flux](https://fluxcd.io/) — это GitOps-инструмент для Kubernetes: желаемое состояние (манифесты, Helm-релизы) хранится в Git, а контроллеры Flux непрерывно приводят кластер к этому состоянию. Основные сущности:

- **Source** — откуда брать конфигурацию: `GitRepository`, `HelmRepository`, `OCIRepository`, `Bucket`.
- **Kustomization** — что применять: сборка из одного или нескольких источников (Kustomize или сырые манифесты).
- **HelmRelease** — установка и обновление Helm-чартов по версии из `HelmRepository` или другого source.

Flux сам по себе не имеет встроенной «status page» в виде отдельного сайта. Под «status page» здесь понимается **обзор состояния реконсиляции и здоровья развёрнутых ресурсов**.

### Как смотреть статус (обзор)

1. **CLI `flux`**  
   Установка: [Get started with Flux](https://fluxcd.io/flux/get-started/).  
   Примеры:
   ```bash
   flux get sources git
   flux get sources helm
   flux get kustomizations
   flux get helmreleases -A
   flux logs --follow
   ```
   По выводу видно, какие источники и Kustomization/HelmRelease в состоянии Ready, есть ли ошибки и сообщения.

2. **Kubernetes API**  
   Статус реконсиляции хранится в полях `status` ресурсов Flux:
   ```bash
   kubectl get helmreleases -A
   kubectl get kustomizations -A
   kubectl describe helmrelease <name> -n <namespace>
   ```
   В `status.conditions` видны Ready, LastAppliedRevision, сообщения об ошибках.

3. **UI для Flux**  
   Дашборды дают сводку по Kustomization, HelmRelease, источникам и уведомлениям:
   - [Weave GitOps](https://github.com/weaveworks/weave-gitops) — open-source UI для Flux (Applications, Sources, Flux Runtime, Notifications);
   - [Flux Plugin for Headlamp](https://github.com/headlamp-k8s/plugins/tree/main/flux);
   - [Capacitor](https://github.com/gimlet-io/capacitor) — отладка и визуализация Flux;
   - [Flux Operator (Control Plane)](https://fluxoperator.dev/) — Mission Control с веб-интерфейсом.

   В таких UI отображаются статус реконсиляции, здоровье приложений и события.

4. **Уведомления (Alerts)**  
   [Notification controller](https://fluxcd.io/flux/components/notification/) и ресурсы `Alert`/`Provider` позволяют отправлять события (успех/ошибка реконсиляции) в Slack, Discord, Teams и т.д. — это тоже часть «статуса» в реальном времени.

### Итог

«Status page» в контексте Flux — это комбинация: `flux get` / `kubectl` по CR Flux + при необходимости UI (Weave GitOps, Headlamp, Capacitor, Flux Operator) и опционально уведомления. В этом репозитории развёртывание стека описано через Flux (HelmRelease), чтобы весь статус установки и обновлений был виден через эти же механизмы.

---

## Установка через Flux CD

Предполагается, что Flux уже установлен в кластере (`flux install` или через манифесты) и репозиторий зарегистрирован как источник (например, через `flux create source git` и `flux create kustomization`).

### Структура репозитория (Flux)

- **`flux/`** — манифесты Flux (каталог применяется Kustomization Flux по пути `./flux`):
  - [flux/sources.yaml](flux/sources.yaml) — `HelmRepository` для чартов VictoriaMetrics;
  - [flux/namespaces.yaml](flux/namespaces.yaml) — неймспейс `vmks`;
  - [flux/vmks-helmrelease.yaml](flux/vmks-helmrelease.yaml) — `HelmRelease` victoria-metrics-k8s-stack;
  - [flux/kustomization.yaml](flux/kustomization.yaml) — сборка и ConfigMap с values.
- **`flux/vmks-values.yaml`** — values для HelmRelease (Kustomize собирает из него ConfigMap).

### 1. VictoriaMetrics K8s Stack (Helm)

Чарт `victoria-metrics-k8s-stack` устанавливается через Flux `HelmRelease`. Источник — `HelmRepository` с URL репозитория VictoriaMetrics.

- Релиз в namespace `vmks`, values: [flux/vmks-values.yaml](flux/vmks-values.yaml).
- В values включены: Grafana ingress, VMCluster вместо vmsingle (HA), настройки vmalert/alertmanager/vmselect/vmstorage (см. комментарии в файле).

После реконсиляции проверка:
```bash
kubectl get pods -n vmks
flux get helmreleases -n vmks
```
Пароль Grafana: `kubectl get secret vmks-grafana -n vmks -o jsonpath='{.data.admin-password}' | base64 --decode; echo`.

---

## Развёрнутый стек (кратко)

| Компонент | Namespace | Назначение |
|-----------|-----------|------------|
| VictoriaMetrics K8s Stack | vmks | VMCluster, vmalert, vmagent, Alertmanager, Grafana |

Подробные параметры (реплики, лимиты, ingress) — в values-файлах в каталоге [flux/](flux/).

---

## Инфраструктура (Terraform)

Кластер Kubernetes и сеть в Yandex Cloud описаны в Terraform:

- `k8s.tf` — managed Kubernetes cluster;
- `net.tf` — VPC и подсети;
- `ip-dns.tf` — внешний IP (при необходимости).

После изменений: `terraform plan` / `terraform apply`. Подключение к кластеру: команда из output (например, `yc managed-kubernetes cluster get-credentials ...`).

---

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

---

## Ссылки

- [Flux Documentation](https://fluxcd.io/flux/)
- [Flux Get Started](https://fluxcd.io/flux/get-started/)
- [Flux UIs (Weave GitOps, Headlamp, Capacitor и др.)](https://fluxcd.io/ecosystem/#flux-uis--guis)
- [Manage Helm Releases (Flux)](https://fluxcd.io/flux/guides/helmreleases/)
- [VictoriaMetrics Helm Charts](https://github.com/VictoriaMetrics/helm-charts)
