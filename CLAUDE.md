# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project context

This repo is the deliverable for the **InsiderOne DevOps Internship Case Study 2026**. The brief lives in `InsiderOne_DevOps_Internship_Case_Study_2026_v2[43].pdf` and a condensed plan in `goals.md`. At the time of writing, no application code exists yet — the repo is bootstrapped from scratch following the 4-day mission described in `goals.md`.

The end state is a tiny HTTP service (Node, Go, or Python — not yet chosen) shipped through a full DevOps loop: container → Helm on minikube → GitHub Actions CI/CD with Trivy/gitleaks → Prometheus/Grafana observability → public URL via EC2+EIP (Track A) or ngrok/cloudflared tunnel (Track B).

## Mission constraints (from `goals.md`)

These shape what "done" looks like and override generic best-practice instincts:

- **Single-node Kubernetes is the target.** Minikube only — do not introduce production-grade cluster patterns (multi-master, cloud-managed control plane). A Deployment + Service + Ingress is the expected shape.
- **Build a Helm chart from `helm create`**, not raw manifests. Two values files (`values-dev.yaml`, `values-prod.yaml`) must differ meaningfully (replicas, resources, host).
- **Three required endpoints:** `GET /ping` → `pong`, `GET /healthz` for probes, `GET /version` returning the build SHA. Config is env-driven.
- **Container must be multi-stage and run non-root.**
- **CI gate is non-negotiable:** lint → test → docker build → Trivy scan (fail on CRITICAL/HIGH) → push to GHCR. Auto-deploy to minikube on merge to `main` (either `kubectl set image` or ArgoCD/Flux — the choice goes in an ADR).
- **Secrets stay out of the repo.** Track A uses AWS OIDC, not long-lived keys. `gitleaks` is expected in CI.
- **Observability bar:** JSON structured logs (timestamp, level, msg, request_id), `/metrics` in Prometheus format, kube-prometheus-stack installed via Helm, ≥1 Grafana dashboard, ≥1 alert rule.
- **Docs are deliverables**, not afterthoughts: `README.md`, `RUNBOOK.md`, `SECURITY.md`, ~3 ADRs, an architecture diagram. ADRs answer "why Helm", "why this base image", "why this tunnel".

## Locked decisions

- **Track: A — Minikube on AWS free-tier EC2** with Elastic IP for the public URL. Terraform (local state) provisions EC2 + EIP + Security Group. CI authenticates to AWS via OIDC; no long-lived access keys in the repo.
- **Language: Go.** Chosen for small static binary, fast cold start, smallest non-root container (distroless or scratch base), and a first-class Prometheus client. Stdlib `net/http` is sufficient — no framework needed for three endpoints.

Both choices must be justified in their own ADR (`docs/adr/0001-track.md`, `docs/adr/0002-language.md`).

## Repo hygiene expectations

- Conventional Commits (the existing `git log` already follows `feat(...):` / `refactor(docs):` style).
- `main` + feature branches; PR template; CODEOWNERS; branch protection on `main`.
- A `.env.example` (never a real `.env`) and `.gitignore` from day one.

## Git layout

This directory is its own git repository (initialized 2026-05-16, branch `main`). Future remote: `github.com/borailci/insider-one-devops`. A parent `/Users/borailci/Code/.git` still exists one level up but is ignored — operate only inside this repo. The parent repo's history is unrelated and must not be referenced.

## Working directory layout (current)

```
insider-one/
├── .claude/                 # Claude Code settings (local)
├── CLAUDE.md                # this file
├── goals.md                 # condensed 4-day plan extracted from the PDF
└── InsiderOne_DevOps_Internship_Case_Study_2026_v2[43].pdf
```

Everything else (app code, Dockerfile, `charts/`, `.github/workflows/`, `terraform/` or `Makefile`, `docs/`) is yet to be created and should be scaffolded as the mission days are tackled.

## Day-by-day deliverables (reference)

| Day | Focus | Key artifacts |
|-----|-------|---------------|
| 1 | Foundation | App with 3 endpoints, multi-stage non-root Dockerfile, unit tests, repo hygiene |
| 2 | Kubernetes & Helm | Helm chart, dev/prod values, probes pointing at `/healthz`, resource requests/limits |
| 3 | CI/CD & supply chain | Actions workflow, Trivy + gitleaks, GHCR push, auto-deploy on merge |
| 4 | Observability & docs | JSON logs, `/metrics`, kube-prometheus-stack, Grafana dashboard + alert, IaC, RUNBOOK, ADRs, diagram |

Day-2 checkpoint (from `goals.md`): `helm upgrade --install app -f values-dev.yaml` → pods Running, probes Healthy; same command with `values-prod.yaml` produces different replica count and host.

## Bonuses (only if time permits)

HPA, NetworkPolicy, PodDisruptionBudget, cosign signing, Syft SBOM, multi-arch builds, Kyverno/OPA policies, ArgoCD ApplicationSet, custom domain + cert-manager TLS. Each bonus should be justified in the README in one or two sentences.
