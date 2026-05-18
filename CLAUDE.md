# CLAUDE.md

Guidance for Claude Code (claude.ai/code) sessions on this repo.

## What this repo is

Deliverable for the **InsiderOne DevOps Internship Case Study 2026**. The full contract is in [`SPEC.md`](./SPEC.md); the original brief PDF is [`docs/case-study-brief.pdf`](./docs/case-study-brief.pdf).

A tiny Go HTTP service shipped through the full DevOps loop: container → Helm on minikube → GitHub Actions CI with Trivy/gitleaks/cosign/Syft → Prometheus/Grafana observability → public URL via EC2+EIP (Track A).

The case-study scope is complete and CI is green (7/7). Live stack is destroyed unless someone runs `terraform apply` again — see `docs/CHECKLIST.md`.

## Locked decisions (don't relitigate without ADR)

- **Track A — minikube on EC2 + EIP.** ADR-0001.
- **Go + stdlib net/http.** ADR-0002.
- **`kubectl set image` via SSM**, not ArgoCD/Flux. ADR-0003.
- **AWS account `057548897384` has no free tier** — every EC2 hour is billable. Always `terraform destroy` after demos.

## Hard constraints (override generic best-practice instincts)

- **Single-node target.** Minikube only. No multi-master / cloud-managed K8s patterns.
- **`helm create` lineage**, not raw manifests. Two values files differ meaningfully.
- **Three endpoints + `/metrics`.** Env-driven config.
- **Multi-stage, non-root container.** Distroless `static-debian12:nonroot`.
- **CI gate is non-negotiable:** lint → test → helm-validate → gitleaks → build+Trivy+cosign+SBOM+push → kind integration → deploy.
- **Secrets never committed.** OIDC for AWS. `gitleaks` runs every push.
- **Conventional Commits**; `main` + feature branches; PR template; CODEOWNERS.

## Where things live

```
.
├── main.go, main_test.go        # Go service (stdlib http + slog + prom client)
├── Dockerfile                   # multi-stage → distroless nonroot
├── charts/
│   ├── app/                     # case-study chart (helm create lineage)
│   └── policies/                # Kyverno ClusterPolicies (bonus)
├── .github/workflows/ci.yml     # 7-job pipeline (see docs/WORKFLOW.md)
├── terraform/                   # EC2 + EIP + SG + OIDC role (local state)
├── scripts/bootstrap-ec2.sh     # cloud-init: docker, minikube, helm,
│                                #   kyverno → policies → kps → app
├── dashboards/                  # Grafana JSON
├── docs/
│   ├── architecture.md          # C4 view + mermaid pipeline
│   ├── diagrams/                # PlantUML sources + SVG (make diagrams)
│   ├── adr/                     # 3 ADRs (track / language / deploy)
│   ├── WORKFLOW.md              # dev → ship loop
│   ├── CHECKLIST.md             # copy-paste demo commands
│   └── case-study-brief.pdf     # original requirements
├── README.md, RUNBOOK.md, SECURITY.md, SPEC.md
└── Makefile                     # build / test / docker / demo / diagrams / sign-verify
```

## Useful entry points

- **Demo locally:** `make demo` (kind cluster + chart + tests + smoke).
- **Verify supply chain:** `make sign-verify`.
- **Render diagrams:** `make diagrams` (also normalizes SVG aspect ratios).
- **Bring up live stack:** `cd terraform && terraform apply -auto-approve` then wait ~5–10 min for cloud-init. Marker: `/var/log/bootstrap-done`. Tear down: `terraform destroy -auto-approve`.
- **Operate the live cluster without SSH:** all commands go through SSM Run-Command. See `docs/CHECKLIST.md` §2 for the `ssmrun` helper.

## Things to be careful with

- `.env` is gitignored and may contain a real Grafana password during a demo session. Never `git add -A` — stage paths explicitly.
- GHCR images are private (matches repo visibility as of 2026-05-18). `cosign verify` from outside the org requires either re-publishing public or invited access.
- Bootstrap installs Kyverno **before** any workload. Adding a new chart that runs as root / pins `:latest` / omits resources will be rejected at admission — check `charts/policies/templates/*` first.
- `image.tag` in the bootstrap is pinned to the short SHA the EC2 cloned, so it satisfies the `disallow-latest-tag` ClusterPolicy. Don't pass `--set image.tag=latest` anywhere.

## Day-by-day deliverable map (for spot-checks)

| Day | Focus | Where it landed |
|-----|-------|-----------------|
| 1 | App + container + repo hygiene | `main.go`, `Dockerfile`, `.github/`, `.golangci.yml`, `.gitleaks.toml` |
| 2 | Helm + K8s | `charts/app/`, dev/prod values, probes, resources |
| 3 | CI/CD + supply chain | `.github/workflows/ci.yml` (7 jobs), GHCR push, OIDC, cosign, Syft, Trivy |
| 4 | Observability + IaC + docs | `terraform/`, `scripts/bootstrap-ec2.sh`, ServiceMonitor, PrometheusRule, dashboards, RUNBOOK, SECURITY, ADRs, C4 diagrams |
| Bonus | HPA, NetworkPolicy, PDB, Kyverno, cosign, Syft, multi-arch, helm tests, C4 PlantUML, STRIDE | see README §Bonus features |
