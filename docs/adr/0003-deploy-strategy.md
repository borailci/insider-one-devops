# ADR-0003: Deploy strategy — `kubectl set image` over ArgoCD

**Status:** Accepted
**Date:** 2026-05-16
**Deciders:** @borailci

## Context

Day 3 of the case study requires auto-deploy on merge to `main`. Spec allows either
imperative (`kubectl set image`) or GitOps (ArgoCD/Flux). Target cluster is a
single-node minikube on one EC2 instance. CI lives in GitHub Actions and authenticates
to AWS via OIDC; no long-lived credentials are stored in the repo.

Traceability: FR-19, FR-20, FR-21, FR-22, NFR-9.

## Decision

Use **`kubectl set image`** (imperative) from the GitHub Actions deploy job. CI
assumes an AWS IAM role via OIDC, then drives `kubectl` against the EC2-hosted
minikube through AWS SSM `Session Manager` (no public Kubernetes API).

The deploy step is a single command:

```
sudo -iu ec2-user kubectl -n default set image deployment/app-app app=ghcr.io/borailci/insider-one-devops:<sha>
sudo -iu ec2-user kubectl -n default rollout status deployment/app-app --timeout=120s
```

(`app-app` is the Helm fullname — release `app` + chart `app`. `sudo -iu ec2-user` is required because AL2023's default kubeconfig lives in that user's home.)

## Alternatives considered

### A. ArgoCD (GitOps pull model)

- **Pros:** declarative, drift detection, app history UI, standard for production.
- **Cons:** Adds a stateful controller, a UI service, RBAC config, and a second
  Helm chart (`argo-cd`) to maintain. Requires a separate sync repository or
  branch convention. On a single-node minikube the added pods consume the same
  budget reserved for kube-prometheus-stack (Day 4). Demo footprint balloons.

### B. Flux (GitOps pull model)

- **Pros:** smaller than ArgoCD, CRD-driven.
- **Cons:** Same single-node cost concern. Slower to demonstrate end-to-end on
  a 4-day clock; image-update controller adds another moving piece.

### C. Helm upgrade from CI (`helm upgrade --install`)

- **Pros:** Re-uses the existing chart, picks up values changes.
- **Cons:** Tag pinning becomes awkward (`--set image.tag=<sha>` on every run
  diverges from `values-prod.yaml`). Hides the actual image rollout behind a
  Helm release transaction; harder to observe in `kubectl get events`.

## Consequences

- **+** One-line deploy. No extra cluster controller. Fits single-node budget.
- **+** Clean OIDC story — short-lived STS credentials per workflow run.
- **+** Rollback is trivial: `kubectl rollout undo deployment/app-app`.
- **−** Configuration drift between Git and cluster is not auto-detected. The
  cluster is authoritative for the running tag; the chart is authoritative for
  everything else. Acceptable because no human edits the cluster directly.
- **−** Initial chart install (`helm upgrade --install`) is still a manual step
  on first bring-up. Documented in `RUNBOOK.md`.

## Revisit when

- Cluster grows past a single node, or
- More than one service ships from this repo, or
- A second human starts deploying — GitOps pays off when human-driven `kubectl`
  becomes a drift source.
