# insider-one-devops

> InsiderOne DevOps Internship Case Study 2026 — Track A (Minikube on EC2 + Elastic IP).

A tiny Go HTTP service shipped through the full DevOps loop: container → Helm on minikube → GitHub Actions CI/CD with Trivy/gitleaks → Prometheus + Grafana observability → public URL.

The contract is in [`SPEC.md`](./SPEC.md). Every change in this repo traces to a numbered requirement (FR/NFR/AC/EC/OS) in that spec.

## Endpoints

| Method | Path       | Response                                                 |
|--------|------------|----------------------------------------------------------|
| GET    | `/ping`    | `pong` (text/plain)                                      |
| GET    | `/healthz` | `{"status":"ok"}` (200) or `{"status":"draining"}` (503) |
| GET    | `/version` | `{"sha":"<git-sha>","build_time":"<RFC3339>"}`           |
| GET    | `/metrics` | Prometheus exposition format                             |

## Quickstart (local)

```bash
# Run with defaults (port 8080, info logs)
go run .

# In another shell
curl -s localhost:8080/ping              # → pong
curl -s localhost:8080/healthz | jq .    # → {"status":"ok"}
curl -s localhost:8080/version | jq .    # → {"sha":"unknown","build_time":"unknown"}
curl -s localhost:8080/metrics | head    # → Prometheus text
```

Override via env:

```bash
PORT=9090 LOG_LEVEL=debug go run .
```

See `.env.example` for the full list of supported variables.

## Build

```bash
# Local binary (build SHA injected from git)
make build

# Container image
make docker-build      # tags ghcr.io/borailci/insider-one-devops:<short-sha>
```

## Test

```bash
go test ./... -race -cover
```

Tests map 1:1 to acceptance criteria in `SPEC.md` (`AC-1` through `AC-9`, plus `EC-1`, `EC-2`, `EC-3`). The SIGTERM test compiles and runs the binary in a subprocess; expect `~2 s` total.

## Project layout (Day 1)

```
.
├── main.go              # service: routes, middleware, signal handling
├── main_test.go         # AC-mapped unit + subprocess tests
├── Dockerfile           # multi-stage, distroless static:nonroot
├── .dockerignore
├── .golangci.yml
├── go.mod / go.sum
├── .env.example
├── .gitignore
├── CODEOWNERS
├── Makefile
├── CLAUDE.md            # guidance for AI assistants working in this repo
├── SPEC.md              # contract; every change references a requirement
├── README.md            # this file
└── .github/
    └── PULL_REQUEST_TEMPLATE.md
```

Subsequent days will add `.github/workflows/`, `terraform/`, `dashboards/`, `docs/adr/`, `RUNBOOK.md`, `SECURITY.md`.

## Helm chart (Day 2)

Hand-written chart at `charts/app/` rendering Deployment, Service (ClusterIP), Ingress, ConfigMap, and Secret (conditional). Two environment overlays:

| File                  | replicas | resources (req/lim cpu/mem)   | host                       | LOG_LEVEL |
|-----------------------|---------:|-------------------------------|----------------------------|-----------|
| `values-dev.yaml`     | 1        | 25m/100m, 32Mi/64Mi           | `app.dev.local`            | debug     |
| `values-prod.yaml`    | 2        | 100m/500m, 128Mi/256Mi        | `app.insider-one.example`  | info      |

Probes target `/healthz`. Pod and container `securityContext` enforce `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, and drop all capabilities — matching the distroless `nonroot` UID 65532.

Quick verification:

```bash
helm lint charts/app -f charts/app/values-prod.yaml
helm template app charts/app -f charts/app/values-prod.yaml | kubeconform -strict
```

Install against a local cluster:

```bash
helm upgrade --install app charts/app -f charts/app/values-dev.yaml
```

## CI/CD (Day 3)

Single workflow at `.github/workflows/ci.yml` runs on every push to `main` and every PR. Job graph:

```
 ┌──────┐  ┌──────┐  ┌──────────────┐  ┌─────────┐
 │ lint │  │ test │  │ helm-validate│  │ gitleaks│
 └──┬───┘  └──┬───┘  └──────┬───────┘  └────┬────┘
    └─────────┴─────────────┴────────────────┘
                       │
              ┌────────▼─────────┐
              │ build-scan-push  │  buildx → Trivy (CRITICAL/HIGH = fail) → GHCR
              └────────┬─────────┘
                       │ (push to main only)
              ┌────────▼─────────┐
              │     deploy       │  AWS OIDC → SSM → `kubectl set image`
              └──────────────────┘
```

Gates (NFR-4, NFR-5, NFR-9):

- `golangci-lint run` — style + bug rules from `.golangci.yml`
- `go test ./... -race -cover`
- `helm lint` × 3 (defaults + dev + prod) and `kubeconform -strict` on rendered manifests
- `gitleaks` with repo-local config at `.gitleaks.toml`
- `trivy image --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed`

Auto-deploy on merge to `main`:

1. OIDC assumes the `insider-one-devops-github-deploy` IAM role (no long-lived keys in the repo).
2. `aws ssm send-command` runs `kubectl -n default set image deployment/app app=<image>:<sha>` on the EC2 host.
3. `kubectl rollout status` blocks until the new ReplicaSet is healthy.

Deploy strategy rationale is in [`docs/adr/0003-deploy-strategy.md`](./docs/adr/0003-deploy-strategy.md). Required GitHub Actions secrets: `AWS_DEPLOY_ROLE_ARN`, `EC2_INSTANCE_ID`. The IAM role is provisioned by `terraform/iam-oidc.tf` (see [`terraform/README.md`](./terraform/README.md)).

## Conventions

- **Branching:** trunk-based. `main` is protected; work via feature branches and PRs.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`).
- **Reviews:** one approval required; CODEOWNERS auto-requests reviewers.
- **Secrets:** never committed. `.env` is gitignored. `gitleaks` runs in CI.

## License

TBD.
