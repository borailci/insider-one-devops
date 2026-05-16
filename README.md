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

Subsequent days will add `charts/`, `.github/workflows/`, `terraform/`, `dashboards/`, `docs/adr/`, `RUNBOOK.md`, `SECURITY.md`.

## Conventions

- **Branching:** trunk-based. `main` is protected; work via feature branches and PRs.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`).
- **Reviews:** one approval required; CODEOWNERS auto-requests reviewers.
- **Secrets:** never committed. `.env` is gitignored. `gitleaks` runs in CI.

## License

TBD.
