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
2. `aws ssm send-command` runs `sudo -iu ec2-user kubectl -n default set image deployment/app-app app=<image>:<sha>` on the EC2 host.
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

> **TL;DR — 12 bonuses delivered, grouped below by theme.** Every row links to the implementing file.

### Supply chain & provenance

> Goal: anyone can prove the image came from this repo, this commit, this workflow — and inspect what's inside.

| # | Bonus | Where | What it gets you |
|---|---|---|---|
| 1 | **Cosign keyless signing** (GitHub OIDC) | [`ci.yml`](./.github/workflows/ci.yml) · [`make sign-verify`](./Makefile) | Tamper-evidence bound to repo + workflow + commit. Zero key management. |
| 2 | **Syft SBOM** (CycloneDX, attached via `cosign attest`) | [`ci.yml`](./.github/workflows/ci.yml) | Full dependency manifest, verifiable & queryable: `cosign download sbom …` |
| 3 | **Multi-arch image** (linux/amd64 + linux/arm64) | [`ci.yml`](./.github/workflows/ci.yml) `build-scan-push` | Native pull on Apple Silicon and x86. One GHCR tag, two manifests. |
| 4 | **Trivy SARIF → GitHub Security tab** | [`ci.yml`](./.github/workflows/ci.yml) | CVEs become first-class findings with severity + dismissals, not buried in CI logs. |
| 5 | **Custom gitleaks rule** `lone-token-in-env-file` | [`.gitleaks.toml`](./.gitleaks.toml) | Catches bare secrets pasted into `.env.example` without a `KEY=` prefix — the failure mode default rules miss. |

### Kubernetes production posture

> Goal: the chart isn't a toy — it includes the controls a real workload needs.

| # | Bonus | Where | What it gets you |
|---|---|---|---|
| 6 | **HorizontalPodAutoscaler** (2–5 @ 60% CPU) | [`hpa.yaml`](./charts/app/templates/hpa.yaml) | Elasticity. Pairs with PDB. |
| 7 | **NetworkPolicy** (default-deny ingress) | [`networkpolicy.yaml`](./charts/app/templates/networkpolicy.yaml) | Microsegmentation. Only ingress-nginx + monitoring can reach pods. |
| 8 | **PodDisruptionBudget** (minAvailable: 1) | [`poddisruptionbudget.yaml`](./charts/app/templates/poddisruptionbudget.yaml) | Survives `kubectl drain` / node upgrades without dropping all replicas. |
| 9 | **Kyverno ClusterPolicies** — require non-root, disallow `:latest`, require resources | [`charts/policies/`](./charts/policies/templates/) | Admission-time enforcement. Demo: `kubectl run nginx-bad --image=nginx:latest` is **rejected** with policy reasons. |

### Testing & developer experience

> Goal: any reviewer can run the whole loop in one command.

| # | Bonus | Where | What it gets you |
|---|---|---|---|
| 10 | **kind integration test in CI** | [`ci.yml`](./.github/workflows/ci.yml) `integration-test` | Spins kind cluster, loads image, installs chart, smoke-tests `/ping` `/healthz` `/version`, runs `helm test`. |
| 11 | **Helm chart tests** (`helm test app`) | [`charts/app/templates/tests/`](./charts/app/templates/tests/) | One command verifies the deployed chart actually answers on all three endpoints. |
| 12 | **`make demo` one-shot** | [`Makefile`](./Makefile) | Reviewer runs `make demo` → minikube + chart + tests + smoke curl. |

### Docs & threat modeling

| # | Bonus | Where | What it gets you |
|---|---|---|---|
| 13 | **C4 architecture diagrams** (PlantUML) | [`docs/diagrams/`](./docs/diagrams/) · `make diagrams` | Version-controlled `.puml` sources + checked-in SVGs. Freshness gated by `make diagrams-check` in CI. |
| 14 | **STRIDE threat model** | [`SECURITY.md` §8](./SECURITY.md) | Six threat categories; each row links to the implementing file. |
| 15 | **`docs/WORKFLOW.md` + `docs/CHECKLIST.md`** | [`docs/WORKFLOW.md`](./docs/WORKFLOW.md) · [`docs/CHECKLIST.md`](./docs/CHECKLIST.md) | End-to-end dev → ship loop + copy-paste demo commands. |

### Verify it yourself

```bash
# 1. Pick a tag (any short SHA from GHCR)
TAG=<short-sha>

# 2. Verify signature (bound to this workflow file on this repo)
make sign-verify
# or manually:
cosign verify ghcr.io/borailci/insider-one-devops:$TAG \
  --certificate-identity-regexp 'https://github.com/borailci/insider-one-devops/.github/workflows/ci.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# 3. Pull the SBOM
cosign download sbom ghcr.io/borailci/insider-one-devops:$TAG | jq '.components | length'
```

> Full step-by-step (Grafana login, Kyverno denial demo, screenshot order, teardown) lives in [**`docs/CHECKLIST.md`**](./docs/CHECKLIST.md).

## Docs map

| Doc | Purpose |
|---|---|
| [`SPEC.md`](./SPEC.md) | Contract — every FR/NFR/AC/EC/OS lives here |
| [`docs/architecture.md`](./docs/architecture.md) | Topology diagram + trust boundaries + data flow |
| [`RUNBOOK.md`](./RUNBOOK.md) | Operator guide — restart, logs, rollback, EC2 access, alerts |
| [`SECURITY.md`](./SECURITY.md) | Threat model, secret handling, image-scan policy, OIDC trust |
| [`docs/WORKFLOW.md`](./docs/WORKFLOW.md) | End-to-end dev → ship loop, gate-by-gate, failure modes |
| [`docs/CHECKLIST.md`](./docs/CHECKLIST.md) | Copy-paste commands used in the live demo |
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
