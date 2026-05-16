# 0002 — Language: Go (stdlib net/http)

- **Status:** Accepted
- **Date:** 2026-05-16
- **Deciders:** Bora İlci
- **Tags:** language, runtime, image-size
- **Traceability:** FR-4, FR-9, FR-10, FR-11, NFR-2, NFR-3, AC-10, AC-11, AC-12

## Context

The brief offers Node, Go, or Python for the three-endpoint service. The choice is graded indirectly through three downstream constraints:

- **NFR-2:** Final image MUST be < 25 MB.
- **NFR-3:** Cold start from `docker run` to first `/healthz` 200 MUST be < 2 s.
- **FR-9 to FR-11:** Multi-stage build, distroless or scratch final stage, no shell, no package manager.

Any of the three runtimes can satisfy the functional requirements; the differentiator is the runtime delivery model and how cleanly it fits a distroless final stage.

## Decision

Use **Go (stdlib `net/http`)** for the service. No web framework — three endpoints do not justify a router dependency.

## Options considered

### A. Go + stdlib `net/http` (chosen)

- **Pros:**
  - Single static binary (`CGO_ENABLED=0`) drops straight into `gcr.io/distroless/static-debian12:nonroot`. No interpreter, no node_modules, no site-packages. Final image lands around 15 MB.
  - Cold start in tens of milliseconds — comfortably under NFR-3.
  - First-class Prometheus client (`prometheus/client_golang`) ships in the `client_golang/prometheus/promhttp` package; `/metrics` is a 5-line handler.
  - Trivy `gobinary` analyzer reads the stdlib version embedded in the binary, so stdlib CVEs are caught at build time (this drove the bump to Go 1.25 on Day 3).
  - Static typing + `errcheck` + `staticcheck` give CI lint signal without a framework opinion.
- **Cons:**
  - Slightly more boilerplate than Node/Python for trivial HTTP.
  - Build needs the Go toolchain in CI (cheap on GitHub-hosted runners).

### B. Node.js + Express / Fastify

- **Pros:** Idiomatic for tiny services; vast ecosystem; cold start ~100–300 ms.
- **Cons:**
  - Distroless `nodejs` images are ~50 MB before the app — would blow NFR-2.
  - `node_modules` ships transitive dependencies → larger Trivy attack surface.
  - To meet NFR-2 the path would be `node:alpine` (not distroless) plus aggressive pruning, weakening the "no shell" hardening narrative.

### C. Python + Flask / FastAPI + Gunicorn

- **Pros:** Concise code; FastAPI ships an OpenAPI doc for free.
- **Cons:**
  - Distroless Python base ~50 MB + `site-packages` → > 60 MB image; misses NFR-2.
  - Cold start with Gunicorn workers ~1–2 s; NFR-3 becomes a fight.
  - Static-binary equivalent doesn't exist; the final stage cannot be `scratch`.

## Consequences

### Positive

- One Dockerfile, ~30 lines, multi-stage with `golang:1.25-alpine` builder and `gcr.io/distroless/static-debian12:nonroot` runtime. The final stage contains exactly one file: the app binary.
- Image size, cold-start, and distroless requirements (NFR-2, NFR-3, FR-9..11) all fall out of the language choice; the build doesn't have to fight the runtime.
- Adding `prometheus/client_golang` to satisfy FR-4 cost two lines: register the default collectors and mount `promhttp.Handler()` at `/metrics`.
- The `-ldflags "-X main.buildSHA=… -X main.buildTime=…"` injection (FR-3) is a built-in Go idiom — no recipe hunting.

### Negative / accepted

- New contributors need a Go toolchain locally to run `go test` and to build outside of Docker. Mitigation: `Makefile` targets wrap the common flows; the Dockerfile is self-contained for anyone without Go installed.
- The stdlib router (`http.ServeMux`) doesn't do method routing — `EC-2` (POST /ping → 405) needs an explicit middleware. This is in the code; it would have been a one-liner with `chi` or `gorilla/mux` but didn't justify the dependency.
- Go upgrades touch two surfaces (`Dockerfile`'s `ARG GO_VERSION` and `ci.yml`'s `GO_VERSION`). The Day-3 stdlib CVE incident (Trivy flagged 14 CVEs in Go 1.23.12, fixed by bumping to 1.25) proved this is real but cheap to manage.
