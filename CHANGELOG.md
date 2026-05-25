# Changelog

All notable changes to this project documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-25

First tagged release. Covers the full case-study scope (Days 1–4) plus the bonus track.

### Added

- **App** — Go HTTP service on stdlib `net/http`: `/ping`, `/healthz`, `/version`, `/metrics`. Env-driven config (`PORT`, `LOG_LEVEL`), structured JSON logs with `request_id` propagation, graceful SIGTERM drain.
- **Container** — multi-stage Dockerfile, distroless `static-debian12:nonroot` base, CGO off, build SHA + time injected via `-ldflags`. Final image < 25 MB.
- **Helm chart** (`charts/app/`) — Deployment, Service, Ingress, ConfigMap, Secret, ServiceMonitor, PrometheusRule, HPA, NetworkPolicy, PDB, helm-test pods. `values-dev.yaml` and `values-prod.yaml` differ on replicas, resources, host.
- **CI/CD** (`.github/workflows/ci.yml`) — 7-job pipeline: lint → test → helm-validate → gitleaks → build+Trivy+cosign+SBOM+push → kind integration → deploy. OIDC to AWS, no static keys. SARIF upload to GitHub Code Scanning.
- **Infrastructure** (`terraform/`) — EC2 (t3.micro, eu-north-1) + Elastic IP + Security Group + OIDC role for GitHub Actions. Local state.
- **Bootstrap** (`scripts/bootstrap-ec2.sh`) — cloud-init: Docker, minikube, kubectl, Helm, Kyverno (policies first), kube-prometheus-stack, app chart.
- **Observability** — kube-prometheus-stack via Helm, ServiceMonitor scrapes `/metrics`, Grafana dashboard JSON (`dashboards/app.json`) with RPS / p50-p95-p99 latency / error rate / pod restart panels, PrometheusRule alerting on 5xx > 5% over 5m.
- **Supply chain** — cosign keyless signing, Syft CycloneDX SBOM attestation, multi-arch (amd64 + arm64 cross-compiled), Trivy CRITICAL/HIGH gate.
- **Policy** — Kyverno ClusterPolicies (disallow-latest-tag, require-non-root, require-resources) enforced at admission.
- **Docs** — `README.md`, `RUNBOOK.md`, `SECURITY.md`, `SPEC.md`, three ADRs (`0001-track`, `0002-language`, `0003-deploy-strategy`), C4 diagrams (context/container/deployment/pipeline) as PlantUML + SVG + PNG, `docs/WORKFLOW.md`, `docs/CHECKLIST.md`.

### Notes

- Track A (minikube on EC2 + EIP) chosen over Track B. See [`docs/adr/0001-track.md`](docs/adr/0001-track.md).
- Live EC2 stack destroyed by default; spin up with `terraform apply` for demos. AWS account has no free tier — every EC2 hour is billable.

[0.1.0]: https://github.com/borailci/insider-one-devops/releases/tag/v0.1.0
