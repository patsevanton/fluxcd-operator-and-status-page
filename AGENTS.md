# AGENTS.md

## Обзор проекта

GitOps-репозиторий, демонстрирующий миграцию Flux CD (CLI bootstrap) на **Flux Operator** (FluxInstance) с подключённой **FluxCD Status Page** и стеком наблюдаемости (VictoriaMetrics + Grafana + Alertmanager) в Yandex Cloud.

## Стек технологий

| Технология | Назначение |
|---|---|
| **Terraform (HCL)** | Инфраструктура Yandex Cloud: VPC, K8s-кластер, DNS, ingress-nginx |
| **Kubernetes / FluxCD / Kustomize (YAML)** | GitOps-манифесты: FluxInstance, Kustomization, HelmRelease, HelmRepository, Provider, Alert, PodMonitor |
| **Grafana (JSON)** | Дашборды: cluster, control-plane, flux2 |

Нет исходного кода на Go/Python/JS — репозиторий состоит целиком из декларативных конфигураций.

## Структура репозитория

| Путь | Описание |
|---|---|
| `base/` | Корневой Flux-путь (bootstrap): `apps.yaml`, `flux-system/flux-instance.yaml` |
| `apps/` | Приложения: `flux-operator/`, `flux-resources/`, `victoria-metrics/`, `prometheus-crds/`, `broken-demo/` |
| `dashboard/` | JSON-дашборды Grafana |
| `*.tf` | Terraform-файлы инфраструктуры Yandex Cloud |

## Команды

В проекте нет Makefile, package.json или скриптов сборки. Основные операции:

```bash
# Bootstrap Flux
flux bootstrap github --token-auth --owner=patsevanton --repository=fluxcd-operator-and-status-page --branch=main --path=base

# Проверка состояния Flux
flux get all -A
flux get kustomizations -A
flux get helmreleases -n flux-system

# Локальная валидация kustomize
kubectl kustomize apps/flux-resources

# Terraform
terraform plan
terraform apply
```

## Правила коммитов

Следовать формату из `.cursor/rules/commit.mdc` и `.agents/skills/commit/SKILL.md`:

- **Заголовок:** до 30 символов, прошедшее время, без эмодзи
- **Начинать с:** Fixed, Changed, Updated, Improved, Added, Removed, Reverted, Moved, Released, Bumped, Cleaned
- **3-я строка:** пустая
- **4-я строка (опционально):** `ref <url>` / `fixes <url>` / `closes <url>`
- **Далее:** краткое обоснование «why»

Пример:
```
Added PodMonitor for Flux

ref https://github.com/patsevanton/fluxcd-operator-and-status-page/issues/123

- collects metrics from all Flux controllers
- uses http-prom port matching controller config
```

## Что нельзя делать

- Не коммитить `terraform.tfstate`, `*.tfvars`, секреты и токены
- Не пушить без явной просьбы пользователя
- Не делать `push --force` на main/master
- Не обходить git-хуки

## Валидация изменений

После изменения YAML-манифестов проверять:

```bash
kubectl kustomize <путь-к-каталогу>   # локальная сборка kustomize
```

После коммита — проверить синхронизацию в кластере:

```bash
flux get kustomizations -A
```

## Доступные навыки агентов

Репозиторий содержит набор навыков в `.agents/skills/`. Использовать по назначению:

| Навык | Когда применять |
|---|---|
| `gitops-knowledge` | Вопросы по Flux CRD, генерация YAML |
| `gitops-repo-audit` | Аудит и валидация GitOps-репозитория |
| `gitops-cluster-debug` | Отладка Flux на живом кластере |
| `yaml-check` | Валидация YAML |
| `commit` | Формат коммитов |
