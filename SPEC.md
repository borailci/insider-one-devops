# SPEC — InsiderOne DevOps Internship Case Study 2026

## Metadata

- **Author:** Bora İlci (borailci16@gmail.com)
- **Date:** 2026-05-16
- **Status:** Draft
- **Reviewers:** insider-one-devops team
- **Track:** A — Minikube on AWS free-tier EC2 + Elastic IP
- **Language:** Go (stdlib `net/http`)
- **Source brief:** [`docs/case-study-brief.pdf`](docs/case-study-brief.pdf)

## Context

The case study evaluates DevOps fundamentals by shipping a deliberately tiny HTTP service through the full path of container → Kubernetes → CI/CD → observability → public URL → docs. The graded signal is not the application; it is the discipline of the surrounding system: clean repo hygiene, a working Helm chart, a CI pipeline that protects the supply chain, structured observability, and clear documentation. The brief explicitly warns against production-grade complexity — a single-node minikube is the target.

Two production anti-patterns must be avoided. First, secrets in the repo: AWS access uses OIDC, gitleaks runs in CI, and `.env` files are gitignored. Second, opaque deployments: every choice (Helm vs. raw manifests, base image, deploy strategy) lands in an ADR that a reviewer can read in under two minutes.

Track A was chosen over Track B because IaC and OIDC are higher-signal evidence of DevOps competence than a tunnel demo, and the AWS free tier removes the cost barrier. Go was chosen because it produces the smallest non-root container (distroless or scratch base) with first-class Prometheus support, which removes friction in Days 2–4.

## Functional Requirements

Application:

- FR-1: The service MUST expose `GET /ping` returning HTTP 200 with body exactly `pong` and `Content-Type: text/plain; charset=utf-8`.
- FR-2: The service MUST expose `GET /healthz` returning HTTP 200 with JSON `{"status":"ok"}` when healthy, and HTTP 503 with `{"status":"draining"}` after SIGTERM.
- FR-3: The service MUST expose `GET /version` returning JSON `{"sha":"<git-sha>","build_time":"<ISO-8601>"}`. Both values MUST be injected at build time via `-ldflags`.
- FR-4: The service MUST expose `GET /metrics` in Prometheus exposition format v0.0.4, including `http_requests_total{method,path,status}`, `http_request_duration_seconds{method,path}` histogram, and Go runtime collectors.
- FR-5: The service MUST read configuration exclusively from environment variables: `PORT` (default `8080`), `LOG_LEVEL` (`debug|info|warn|error`, default `info`), and build-time `BUILD_SHA`, `BUILD_TIME`. No flag parsing. No config files.
- FR-6: The service MUST emit structured logs as one JSON object per line on stdout with required fields `ts`, `level`, `msg`, `request_id`. Each HTTP request MUST be access-logged once with `path`, `method`, `status`, `duration_ms`, `request_id`.
- FR-7: The service MUST honor an incoming `X-Request-ID` header, echo it back in the response and logs, and otherwise generate a UUIDv4.
- FR-8: The service MUST handle SIGTERM by closing the listener, draining in-flight requests for up to 10 seconds, then exiting with code 0.

Container:

- FR-9: The Dockerfile MUST be multi-stage: a `builder` stage compiling Go statically (`CGO_ENABLED=0`), and a final stage based on `gcr.io/distroless/static-debian12:nonroot` (or `scratch`).
- FR-10: The final image MUST run as non-root (UID 65532 for distroless, or explicit `USER` for scratch).
- FR-11: The image MUST contain only the application binary plus CA roots — no shell, no package manager, no build toolchain.
- FR-12: The image MUST be tagged with the short git SHA and pushed to `ghcr.io/<owner>/<repo>:<sha>` plus `:latest` on main-branch builds.

Helm chart:

- FR-13: The chart at `charts/app/` MUST render `Deployment`, `Service` (ClusterIP), `Ingress`, `ConfigMap`, and `Secret` resources.
- FR-14: The chart MUST provide `values-dev.yaml` and `values-prod.yaml` that differ on `replicaCount`, at least one `resources.*` field, and `ingress.hosts[0].host`.
- FR-15: The Deployment MUST configure `livenessProbe` and `readinessProbe` pointing at `/healthz`. A `startupProbe` MAY be added.
- FR-16: Every container MUST declare CPU and memory `requests` and `limits`. Defaults: `requests: {cpu: 50m, memory: 64Mi}`, `limits: {cpu: 200m, memory: 128Mi}`.
- FR-17: `helm lint charts/app` MUST exit 0.
- FR-18: `helm template charts/app -f values-prod.yaml` MUST produce manifests that pass `kubeconform -strict`.

CI/CD:

- FR-19: A GitHub Actions workflow MUST run on every push and PR with gating jobs in order: `lint` (golangci-lint), `test` (`go test ./... -race -cover`), `build` (docker buildx), `scan` (Trivy fails on CRITICAL/HIGH), `secrets` (gitleaks).
- FR-20: On push to `main`, after all gates pass, the workflow MUST push the image to GHCR and trigger the deploy job.
- FR-21: The deploy job MUST authenticate to AWS via OIDC (no long-lived keys), assume a least-privileged role, reach the EC2 host via SSM, and run `helm upgrade --install app charts/app -f values-prod.yaml --set image.tag=<sha>`.
- FR-22: The repo MUST contain `.github/PULL_REQUEST_TEMPLATE.md`, `CODEOWNERS`, and branch protection on `main` requiring CI green plus one approval.

Infrastructure:

- FR-23: A Terraform configuration under `terraform/` MUST provision one EC2 instance (`t3.micro` or regional free-tier equivalent), one Elastic IP attached to it, and one Security Group allowing inbound 22/80/443 (22 limited to operator IP).
- FR-24: A bootstrap script (`scripts/bootstrap-ec2.sh`) MUST install Docker, minikube, kubectl, Helm on the EC2 instance and run `minikube start --driver=docker`.
- FR-25: Minikube ingress MUST be enabled and routed from the Elastic IP to the ingress controller. The README MUST document the chosen forwarding approach.

Observability:

- FR-26: `kube-prometheus-stack` MUST be installed via Helm into a `monitoring` namespace.
- FR-27: A `ServiceMonitor` MUST scrape `/metrics` from the app's Service.
- FR-28: At least one Grafana dashboard (committed as JSON under `dashboards/`) MUST show requests/sec, latency percentiles, error rate, and pod restarts.
- FR-29: At least one `PrometheusRule` MUST alert when 5xx rate exceeds 5% over 5 minutes for 2 minutes sustained.

Documentation:

- FR-30: `README.md` MUST contain an overview paragraph, quickstart, architecture diagram reference, public URL, and links to RUNBOOK/SECURITY/all three ADRs.
- FR-31: `RUNBOOK.md` MUST cover restart steps, where to find logs, how to roll back (`helm rollback`), how to access the EC2 host, and how to inspect Prometheus alerts.
- FR-32: `SECURITY.md` MUST cover threat-model summary, secret handling, image-scan policy, OIDC trust boundary, and reporting contact.
- FR-33: Exactly three ADRs MUST exist under `docs/adr/`: `0001-track.md`, `0002-language.md`, `0003-deploy-strategy.md`.

## Non-Functional Requirements

- NFR-1: Performance. `GET /ping` p99 latency MUST be < 50 ms on a single t3.micro under 100 RPS for 1 minute (measured with `hey` or `vegeta`).
- NFR-2: Image size. Final container image MUST be < 25 MB.
- NFR-3: Startup time. From `docker run` to first successful `/healthz` MUST be < 2 s.
- NFR-4: Security — image. Trivy scan MUST report zero CRITICAL and zero HIGH vulnerabilities at the time of merge.
- NFR-5: Security — secrets. Zero secrets in repo history (verified by `gitleaks detect --redact`).
- NFR-6: Security — runtime. Pod security context MUST set `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`.
- NFR-7: Reliability. A rollout MUST complete with zero dropped requests under steady 10 RPS load.
- NFR-8: Observability latency. A new pod's metrics MUST appear in Prometheus within 60 s of becoming Ready.
- NFR-9: CI duration. Full pipeline (lint → push) MUST complete in < 8 minutes on GitHub-hosted runners.
- NFR-10: Cost. Monthly AWS spend MUST stay within free tier (1× t3.micro 750 h/mo, 1× attached EIP, < 15 GB egress).

## Acceptance Criteria

### AC-1: `/ping` returns pong (FR-1)

- **Given** the service is running
- **When** a client sends `GET /ping`
- **Then** the response is HTTP 200 with body exactly `pong` and `Content-Type: text/plain; charset=utf-8`

### AC-2: `/healthz` is OK when healthy (FR-2)

- **Given** the service is running and has not received SIGTERM
- **When** a client sends `GET /healthz`
- **Then** the response is HTTP 200 with body `{"status":"ok"}`

### AC-3: `/healthz` flips to 503 during drain (FR-2, FR-8)

- **Given** the service has received SIGTERM and is within the drain window
- **When** a client sends `GET /healthz`
- **Then** the response is HTTP 503 with body `{"status":"draining"}`

### AC-4: `/version` returns build metadata (FR-3)

- **Given** the binary was built with `-ldflags "-X main.buildSHA=abc123 -X main.buildTime=2026-05-16T10:00:00Z"`
- **When** a client sends `GET /version`
- **Then** the response body equals `{"sha":"abc123","build_time":"2026-05-16T10:00:00Z"}`

### AC-5: `/metrics` exposes request counters (FR-4)

- **Given** the service has handled at least one `GET /ping`
- **When** a client sends `GET /metrics`
- **Then** the response contains a line matching `http_requests_total{method="GET",path="/ping",status="200"} <N>` where N ≥ 1

### AC-6: PORT env overrides default (FR-5)

- **Given** `PORT=9090` is set in the environment
- **When** the service starts
- **Then** it listens on TCP 9090 and not 8080

### AC-7: access logs are structured JSON (FR-6)

- **Given** the service is running
- **When** it writes an access log entry
- **Then** the line parses as JSON containing all of `ts`, `level`, `msg`, `request_id`, `path`, `method`, `status`, `duration_ms`

### AC-8: request ID is echoed (FR-7)

- **Given** a client sends `GET /ping` with header `X-Request-ID: feed-face`
- **When** the response is returned
- **Then** response header `X-Request-ID` equals `feed-face` and the access log line contains `"request_id":"feed-face"`

### AC-9: graceful shutdown completes in-flight work (FR-8)

- **Given** the service is handling a 2 s request
- **When** SIGTERM is sent
- **Then** the in-flight request completes with HTTP 200 and the process exits with code 0 within 12 s

### AC-10: container is multi-stage and non-root (FR-9, FR-10, FR-11)

- **Given** the Dockerfile builds successfully
- **When** the image is inspected with `docker inspect` and `dive`
- **Then** it has ≥ 2 stages, runs as a non-zero UID, and contains no `/bin/sh`

### AC-11: image is < 25 MB (FR-9, NFR-2)

- **Given** the image is built
- **When** `docker images --format "{{.Size}}"` is read
- **Then** the size is less than 25 MB

### AC-12: startup to ready < 2 s (FR-2, NFR-3)

- **Given** the image is loaded locally
- **When** `docker run` is invoked and `/healthz` is polled at 100 ms intervals
- **Then** the first HTTP 200 arrives within 2 s

### AC-13: image is published to GHCR (FR-12)

- **Given** a merge to `main` has occurred with green CI
- **When** GHCR is queried for `ghcr.io/<owner>/<repo>`
- **Then** an image tagged with the short SHA of that merge commit exists and `:latest` points to the same digest

### AC-14: helm lint exits 0 (FR-13, FR-17)

- **Given** the chart at `charts/app/`
- **When** `helm lint charts/app` runs
- **Then** it exits with code 0

### AC-15: dev and prod values differ meaningfully (FR-14)

- **Given** both values files exist
- **When** `helm template` is rendered against each and the outputs are diffed
- **Then** `replicaCount`, at least one `resources.*` value, and `ingress.hosts[0].host` differ

### AC-16: probes target /healthz (FR-15)

- **Given** the rendered Deployment manifest
- **When** the container spec is inspected
- **Then** `livenessProbe.httpGet.path` and `readinessProbe.httpGet.path` both equal `/healthz`

### AC-17: container has explicit resource limits (FR-16)

- **Given** the rendered Deployment manifest
- **When** the container spec is inspected
- **Then** `resources.requests.cpu`, `resources.requests.memory`, `resources.limits.cpu`, `resources.limits.memory` are all present and non-empty

### AC-18: pod security context is hardened (NFR-6)

- **Given** the rendered Deployment manifest
- **When** `spec.template.spec.securityContext` and `spec.template.spec.containers[0].securityContext` are inspected
- **Then** `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`

### AC-19: rendered manifests pass kubeconform (FR-18)

- **Given** rendered manifests from `helm template -f values-prod.yaml`
- **When** `kubeconform -strict` runs
- **Then** it exits with code 0

### AC-20: Trivy blocks HIGH CVE PRs (FR-19, NFR-4)

- **Given** a PR is opened with a base image pinned to a known HIGH-CVE digest
- **When** CI runs
- **Then** the `scan` job fails and the PR cannot be merged

### AC-21: gitleaks blocks secret leaks (FR-19, NFR-5)

- **Given** a PR is opened with a fake AWS access key in a file
- **When** CI runs
- **Then** the `secrets` job fails

### AC-22: full CI pipeline completes < 8 min (FR-19, NFR-9)

- **Given** a clean PR with no cache invalidation
- **When** CI runs end-to-end
- **Then** total wall-clock time is less than 8 minutes

### AC-23: branch protection blocks direct push (FR-22)

- **Given** branch protection on `main`
- **When** an operator attempts `git push origin main` directly without a PR
- **Then** the push is rejected by GitHub

### AC-24: auto-deploy reflects new image (FR-20, FR-21)

- **Given** a commit lands on `main` with green CI
- **When** five minutes elapse
- **Then** `kubectl -n default get deploy app -o jsonpath='{.spec.template.spec.containers[0].image}'` on the EC2 host returns the new image tag

### AC-25: deploy uses OIDC, not static keys (FR-21)

- **Given** the deploy workflow has run
- **When** CloudTrail events for the role are inspected
- **Then** the caller identity shows `AssumeRoleWithWebIdentity` and no IAM user with long-lived keys appears

### AC-26: Terraform provisions exactly one stack (FR-23)

- **Given** `terraform apply` runs in a clean account
- **When** it completes
- **Then** exactly one EC2 instance, one Elastic IP, and one Security Group exist tagged for this case study

### AC-27: bootstrap brings up minikube (FR-24)

- **Given** a freshly provisioned EC2 host
- **When** `scripts/bootstrap-ec2.sh` runs to completion
- **Then** `minikube status` reports the cluster Running and `kubectl get nodes` shows one Ready node

### AC-28: public URL serves /ping (FR-25)

- **Given** the EC2 instance is provisioned and the app is deployed
- **When** an external client hits the Elastic IP on port 80 with `Host: <ingress-host>` and path `/ping`
- **Then** the response is HTTP 200 with body `pong`

### AC-29: free-tier cost stays $0 (NFR-10)

- **Given** the running infrastructure for one billing cycle
- **When** `aws ce get-cost-and-usage` is queried filtered to case-study tags
- **Then** the total is $0.00 (or only documented EIP-detached idle charges)

### AC-30: Prometheus scrapes the app (FR-26, FR-27)

- **Given** kube-prometheus-stack is installed and the app is running
- **When** `kubectl -n monitoring get servicemonitor` is queried and Prometheus `/targets` is checked
- **Then** the app's ServiceMonitor exists and Prometheus reports the pod as `up=1`

### AC-31: Grafana dashboard renders core panels (FR-28)

- **Given** Grafana is accessible
- **When** the committed dashboard is opened
- **Then** panels for RPS, p50/p95/p99 latency, error rate, and pod restarts all render with data

### AC-32: 5xx alert fires under load (FR-29)

- **Given** the alert rule is loaded into Prometheus
- **When** synthetic 5xx errors are generated at > 5% of total requests for > 2 minutes
- **Then** the alert appears in Prometheus `/alerts` in the firing state

### AC-33: new pod is scraped within 60 s (NFR-8)

- **Given** a fresh pod has just become Ready
- **When** 60 seconds pass
- **Then** Prometheus shows at least one successful scrape sample for that pod

### AC-34: README contains required links (FR-30)

- **Given** the repo at HEAD on `main`
- **When** `README.md` is read
- **Then** it contains an overview paragraph, a quickstart section, an architecture image reference, the public URL, and links to RUNBOOK.md, SECURITY.md, and the three ADRs

### AC-35: RUNBOOK covers operational scenarios (FR-31)

- **Given** `RUNBOOK.md` at HEAD
- **When** the file is read
- **Then** it contains sections for restart, log location, rollback procedure, EC2 access, and alert inspection

### AC-36: SECURITY.md documents controls (FR-32)

- **Given** `SECURITY.md` at HEAD
- **When** the file is read
- **Then** it contains sections for threat model summary, secret handling, image-scan policy, OIDC trust boundary, and reporting contact

### AC-37: ADR set is complete (FR-33)

- **Given** the repo at HEAD
- **When** `docs/adr/` is listed
- **Then** it contains exactly three markdown files matching `0001-*.md`, `0002-*.md`, `0003-*.md`

### AC-38: rollout is zero-downtime (NFR-7)

- **Given** steady 10 RPS load against the public URL
- **When** a new image rolls out via `helm upgrade`
- **Then** the load generator records zero failed requests and zero connection resets

### AC-39: p99 latency stays under 50 ms (NFR-1)

- **Given** the deployed service on the t3.micro
- **When** `hey -z 60s -c 50 http://<public-url>/ping` runs for 60 s
- **Then** reported p99 latency is below 50 ms

## Edge Cases

- EC-1: Unknown path. The service receives `GET /unknown` and MUST return HTTP 404 with body `{"error":"not found","request_id":"<id>"}`.
- EC-2: Wrong method. The service receives `POST /ping` and MUST return HTTP 405 with `Allow: GET` header.
- EC-3: Invalid PORT. The env `PORT=abc` is set. The process MUST exit with code 2 and log a single JSON error line; it MUST NOT print a Go stack trace to stderr.
- EC-4: Bound port. The configured PORT is already in use. The process MUST exit with code 1 and log the bind error.
- EC-5: Duplicate request IDs. Two clients send identical `X-Request-ID` values. Both responses MUST echo the value; logs MUST reflect both with the same ID.
- EC-6: Registry unreachable. Trivy or GHCR is unreachable in CI. The corresponding job MUST hard-fail; no image gets published.
- EC-7: Host reboot. The EC2 instance reboots unexpectedly. Minikube MUST auto-start via systemd; the app and ingress MUST come back without manual intervention. RUNBOOK MUST document the verification steps.
- EC-8: Bad rollout. `helm upgrade` rolls out a Deployment whose new pods fail the readiness probe. The previous ReplicaSet MUST continue serving traffic; the deploy job MUST exit non-zero.
- EC-9: Rollback. An operator runs `helm rollback app 1`. The previous image tag MUST serve traffic again within 60 s.
- EC-10: Disk pressure. The EC2 root volume fills. The Grafana dashboard MUST surface node disk pressure; an alert MAY fire (bonus).

## API Contracts

```ts
// GET /ping
// 200 text/plain
type PingResponse = "pong";

// GET /healthz
// 200 when healthy, 503 when draining (JSON in both cases)
interface HealthzResponse {
  status: "ok" | "draining";
}

// GET /version
// 200 application/json
interface VersionResponse {
  sha: string;        // short git SHA, length >= 7
  build_time: string; // RFC3339, UTC
}

// GET /metrics
// 200 text/plain; version=0.0.4; charset=utf-8
// Prometheus exposition format. Key series:
//   http_requests_total{method,path,status} (counter)
//   http_request_duration_seconds_bucket{method,path,le}
//   http_request_duration_seconds_sum{method,path}
//   http_request_duration_seconds_count{method,path}
//   go_goroutines, go_gc_duration_seconds, process_resident_memory_bytes

// Common error envelope for 4xx and 5xx JSON responses
interface ErrorResponse {
  error: string;
  request_id: string;
}
```

Request headers honored: `X-Request-ID` (propagated when present, generated when absent).
Response headers always set: `X-Request-ID`, `Content-Type`.

## Data Models

The service is stateless and has no persistent storage. The in-memory and config entities are:

| Entity    | Field        | Type                       | Constraints                                                  |
|-----------|--------------|----------------------------|--------------------------------------------------------------|
| Config    | port         | uint16                     | 1–65535, default 8080                                        |
| Config    | logLevel     | enum                       | one of `debug`, `info`, `warn`, `error`; default `info`      |
| BuildInfo | sha          | string                     | injected via ldflags at build time; non-empty                |
| BuildInfo | buildTime    | string (RFC3339)           | injected via ldflags; non-empty                              |
| LogEntry  | ts           | string (RFC3339Nano)       | required                                                     |
| LogEntry  | level        | enum                       | one of `debug`, `info`, `warn`, `error`                      |
| LogEntry  | msg          | string                     | required, non-empty                                          |
| LogEntry  | request_id   | string (UUIDv4 or caller-supplied) | required on access-log lines                         |
| LogEntry  | path         | string                     | access-log only                                              |
| LogEntry  | method       | string                     | access-log only                                              |
| LogEntry  | status       | int                        | access-log only, 100–599                                     |
| LogEntry  | duration_ms  | float                      | access-log only, ≥ 0                                         |

## Out of Scope

- OS-1: Authentication / authorization. No login, no JWT, no API keys. Reason: not in the brief; would expand container and CI surface for no graded signal.
- OS-2: Persistent storage. No database, PVC, or StatefulSet. Reason: brief explicitly targets a stateless service.
- OS-3: Multi-arch images. Only `linux/amd64`. Reason: bonus in the brief; the t3.micro target is amd64.
- OS-4: cosign signing, Syft SBOM, SLSA attestation. Bonus track. Reason: ship the core first.
- OS-5: Custom domain plus TLS via cert-manager. Bonus. Reason: Elastic IP plus ingress Host header demonstrates the public URL.
- OS-6: GitOps via ArgoCD or Flux. Reason: direct `helm upgrade` from CI is the chosen deploy strategy; tradeoff documented in ADR-0003.
- OS-7: Kyverno or OPA Gatekeeper policies. Bonus.
- OS-8: Horizontal Pod Autoscaler. Bonus; a single-node cluster cannot meaningfully exercise it.
- OS-9: Multi-cluster (dev/staging/prod) deployment. Only `values-dev.yaml` and `values-prod.yaml` rendered against the same minikube. Reason: brief says one cluster is enough.
- OS-10: Load testing in CI. Performance NFRs are verified locally at day-2 and day-4 checkpoints. Reason: GitHub-hosted runners cannot give stable timing.
- OS-11: Distributed tracing (OpenTelemetry, Jaeger). Bonus. Logs carry `request_id` so tracing can be bolted on later without API change.
- OS-12: Alertmanager-to-Slack or PagerDuty delivery. Bonus. Alert visibility is via Prometheus UI; the default Alertmanager null receiver is acceptable.
