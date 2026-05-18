# insider-one-devops

[![CI](https://github.com/borailci/insider-one-devops/actions/workflows/ci.yml/badge.svg)](https://github.com/borailci/insider-one-devops/actions/workflows/ci.yml)
[![Image](https://img.shields.io/badge/image-ghcr.io%2Fborailci%2Finsider--one--devops-blue?logo=github)](https://github.com/borailci/insider-one-devops/pkgs/container/insider-one-devops)
[![Signed with cosign](https://img.shields.io/badge/cosign-keyless%20(GitHub%20OIDC)-7C3AED?logo=sigstore)](https://docs.sigstore.dev/cosign/)
[![SBOM CycloneDX](https://img.shields.io/badge/SBOM-CycloneDX%20%2B%20Syft-1C7C54)](https://anchore.com/sbom/)
[![Trivy](https://img.shields.io/badge/trivy-CRITICAL%2FHIGH%20gate-DC2626)](https://aquasecurity.github.io/trivy)

> InsiderOne DevOps Internship Case Study 2026 — Track A (Minikube on EC2 + Elastic IP).

A tiny Go HTTP service shipped through the full DevOps loop: container → Helm on minikube → GitHub Actions CI/CD with Trivy/gitleaks/cosign/Syft → Prometheus + Grafana observability → public URL.

The contract is in [`SPEC.md`](./SPEC.md). Every change in this repo traces to a numbered requirement (FR/NFR/AC/EC/OS) in that spec. The set of bonus features that go beyond the contract is summarized under [Bonus features](#bonus-features) below.

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

One-command end-to-end on a fresh laptop (minikube + chart + helm tests + smoke curl):

```bash
make demo
```

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

### Verifying the supply chain

Every image pushed by `main` is built multi-arch (linux/amd64 + linux/arm64), Trivy-scanned (fail on CRITICAL/HIGH), Syft-SBOM'd, and signed by cosign in keyless mode (GitHub OIDC). Any reviewer can confirm an image came from this workflow:

```bash
# 1. Resolve the digest (or use the :latest tag).
docker buildx imagetools inspect ghcr.io/borailci/insider-one-devops:latest

# 2. Verify the signature (no key material; identity is bound to the OIDC issuer).
cosign verify ghcr.io/borailci/insider-one-devops@<digest> \
  --certificate-identity-regexp '^https://github.com/borailci/insider-one-devops/.github/workflows/.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# 3. Pull the SBOM published alongside the image.
cosign download sbom ghcr.io/borailci/insider-one-devops@<digest> > sbom.cdx.json
```

`make sign-verify` wraps steps 1 + 2 for the `:latest` tag.

## Infrastructure & observability (Day 4)

A diagram with full data flow is in [`docs/architecture.md`](./docs/architecture.md).

**Public URL.** One EC2 instance (default `t3.medium` AL2023 — sized for kube-prometheus-stack; `t3.micro` is documented but does not fit the full obs stack) provisioned by Terraform under `terraform/ec2.tf`, with an Elastic IP, a Security Group (80/443 public, 22 narrowed), and an SSM instance profile so CI can drive `kubectl set image` without exposing the Kubernetes API. The cloud-init user-data is `scripts/bootstrap-ec2.sh` — it installs Docker, minikube, kubectl, Helm, then `helm upgrade --install`s the app chart with `values-prod.yaml`.

> **Live demo status (2026-05-18):** The AWS path has been re-provisioned and validated end-to-end. Two failure modes from earlier apply attempts were root-caused and fixed in this iteration: (1) `terraform.tfvars` was at the repo root so the `terraform/` apply auto-loaded `t3.micro` defaults instead of the intended `t3.medium`, causing minikube to fail with `RSRC_INSUFFICIENT_CONTAINER_MEMORY`; (2) the cloud-init bootstrap installed the app chart before kube-prometheus-stack, so the `ServiceMonitor` and `PrometheusRule` CRDs did not yet exist at install time. Both are fixed: tfvars moved into `terraform/`, the bootstrap installs CRDs first, and host port 80/443 routing is now done with `socat` systemd units instead of fragile iptables DNAT. Reviewers can `terraform apply` themselves; the live URL pattern is `http://<EIP>/{ping,healthz,version}` (catch-all ingress — no Host header needed in prod).

```sh
# From the repo root:
cd terraform/
terraform init
terraform apply
terraform output public_url
```

> **Cost guardrails.** `t3.micro` is free-tier eligible for 12 months on new AWS accounts. NFR-10 caps spend at $0. A detached EIP costs ~$3.60/mo, so `terraform destroy` removes both the instance and the EIP atomically. See [ADR-0001](./docs/adr/0001-track.md) for the trade-offs.

**Observability stack.** `kube-prometheus-stack` is installed via Helm into the `monitoring` namespace. The chart now ships a `ServiceMonitor` (`charts/app/templates/servicemonitor.yaml`) and a `PrometheusRule` (`charts/app/templates/prometheusrule.yaml`) that fires `AppDown` and `HighErrorRate` (> 5% 5xx for 2 m). The Grafana dashboard `dashboards/app.json` covers RPS, p50/p95/p99 latency, error rate, pod restarts, and a service-health stat.

> **t3.micro reality.** 1 GiB of RAM is tight for minikube + the full obs stack. The bootstrap reduces resource requests aggressively; if the stack still does not schedule, [`RUNBOOK.md` § Observability fallback](./RUNBOOK.md#observability-fallback-t3micro-oom-path) documents three options (demo obs locally, upgrade to `t3.small`, or uninstall the obs stack on EC2). The chart and dashboard are environment-agnostic — they render and grade identically against any minikube.

## Bonus features

Each item below goes beyond the spec contract. Lower-effort first, higher-impact later.

| Bonus | Where | Why it matters |
|---|---|---|
| **Multi-arch image** (linux/amd64 + linux/arm64) | `.github/workflows/ci.yml` (`build-scan-push`) | Reviewers on Apple Silicon and x86 both pull a native image. |
| **Syft SBOM** (CycloneDX, indexed by digest in GHCR) | `.github/workflows/ci.yml`; reviewer download via `cosign download sbom` | Full dependency manifest published alongside the image. |
| **Cosign keyless signing** (GitHub OIDC issuer) | `.github/workflows/ci.yml`; verified by `make sign-verify` | Tamper-evidence anchored to this repo + workflow, no key management. |
| **Trivy SARIF → GitHub Security tab** | `.github/workflows/ci.yml` | Vulnerabilities become first-class GitHub issues with severity, not buried in CI logs. |
| **kind smoke test in CI** (`integration-test` job) | `.github/workflows/ci.yml` | Runs the chart end-to-end on every push — catches integration bugs the unit tests can't. |
| **HPA, NetworkPolicy, PodDisruptionBudget** in chart | `charts/app/templates/{hpa,networkpolicy,poddisruptionbudget}.yaml` | Production-posture trifecta: elasticity, segmentation, voluntary-disruption tolerance. |
| **Helm chart tests** (`helm test app`) | `charts/app/templates/tests/` | One command verifies the deployed chart actually answers on `/ping`, `/healthz`, `/version`. |
| **Kyverno cluster policies** | `charts/policies/templates/*.yaml` | Admission-time enforcement: ban `:latest`, require non-root, require resources. Live demo: `kubectl run nginx --image=nginx:latest` is rejected. |
| **C4 architecture diagrams** (PlantUML) | [`docs/diagrams/`](./docs/diagrams/) — `make diagrams` to regenerate | Version-controlled diagrams (`.puml` source + checked-in SVGs); freshness gated by `make diagrams-check` in CI. |
| **STRIDE threat model** | [`SECURITY.md` §8](./SECURITY.md) | Six threat categories, each row points at the implementing file. |
| **Custom gitleaks rule** (`lone-token-in-env-file`) | `.gitleaks.toml` | Catches the class of mistake where a bare secret is pasted into `.env.example` without a `KEY=` prefix. |
| **`make demo`** | `Makefile` | Reviewer runs one target, gets a working cluster + smoke test. |

## Docs map

| Doc | Purpose |
|---|---|
| [`SPEC.md`](./SPEC.md) | Contract — every FR/NFR/AC/EC/OS lives here |
| [`docs/architecture.md`](./docs/architecture.md) | Topology diagram + trust boundaries + data flow |
| [`RUNBOOK.md`](./RUNBOOK.md) | Operator guide — restart, logs, rollback, EC2 access, alerts |
| [`SECURITY.md`](./SECURITY.md) | Threat model, secret handling, image-scan policy, OIDC trust |
| [`docs/adr/0001-track.md`](./docs/adr/0001-track.md) | Why Track A on free-tier EC2 |
| [`docs/adr/0002-language.md`](./docs/adr/0002-language.md) | Why Go + stdlib `net/http` |
| [`docs/adr/0003-deploy-strategy.md`](./docs/adr/0003-deploy-strategy.md) | Why `kubectl set image` over ArgoCD/Flux |

## Conventions

- **Branching:** trunk-based. `main` is protected; work via feature branches and PRs.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`).
- **Reviews:** one approval required; CODEOWNERS auto-requests reviewers.
- **Secrets:** never committed. `.env` is gitignored. `gitleaks` runs in CI.

## License

TBD.
