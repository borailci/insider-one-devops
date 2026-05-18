# Screenshots — submission evidence

This directory pins the demo evidence captured against the live AWS deployment. File-naming convention is `NN-<area>-<what>.png` so the gallery sorts in the order a reviewer should consume them.

## Capture checklist

Run these against the live stack (see [RUNBOOK](../../RUNBOOK.md)) and save each as a PNG in this directory.

| # | What | How |
|---|------|-----|
| 01 | `curl http://<EIP>/{ping,healthz,version}` returning 200 | Local terminal screenshot |
| 02 | `kubectl get pods -A` showing app + monitoring + kyverno + ingress-nginx | SSM session terminal |
| 03 | `helm list -A` (app, kps, kyverno, policies all deployed) | SSM session terminal |
| 04 | `helm test app` returning Phase: Succeeded for both test pods | SSM session terminal |
| 05 | `kubectl rollout history deployment/app-app` | SSM session terminal |
| 06 | Grafana dashboard with non-zero RPS / latency / error rate | Browser screenshot (port-forwarded) |
| 07 | Grafana alert rules page showing AppDown + HighErrorRate | Browser screenshot |
| 08 | `cosign verify ghcr.io/.../app@sha256:...` succeeding | Local terminal screenshot |
| 09 | `kubectl run nginx-bad --image=nginx:latest --restart=Never` rejected by Kyverno | SSM session terminal |
| 10 | GitHub Actions run page — all 7 jobs green | Browser screenshot |
| 11 | GitHub Security tab — Trivy SARIF findings | Browser screenshot |
| 12 | GHCR package page — multi-arch manifest + signed badge | Browser screenshot |

When ready, drop the PNGs here and update the table in [README §Bonus features](../../README.md#bonus-features) with `![desc](docs/screenshots/NN-...png)` links.
