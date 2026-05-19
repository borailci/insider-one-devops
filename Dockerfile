# syntax=docker/dockerfile:1.7
#
# Multi-stage container for the InsiderOne case-study service.
#
# Why this shape:
#   - Two stages: heavyweight Go toolchain stays out of the runtime image.
#   - Final base = distroless static-debian12:nonroot — no shell, no apt,
#     no glibc. Trivy scan stays clean; attacker has no busybox to pivot from.
#   - USER nonroot (UID 65532) at build time so the chart's runAsNonRoot=true
#     + Kyverno require-non-root policy both admit the pod.
#   - CGO_ENABLED=0 + static base = single binary, no dynamic linker. The
#     final image is ~15 MB.
#   - -ldflags -s -w strips debug symbols (smaller). -X injects the build
#     SHA + time the /version endpoint serves.
#   - go.mod/go.sum copied separately so dep-only changes don't bust the
#     `go build` cache layer.
#
# Build args set by CI (.github/workflows/ci.yml):
#   - GO_VERSION       — pinned to clear stdlib CVEs (see commit 649b1a8)
#   - BUILD_SHA        — short git SHA, surfaces in /version
#   - BUILD_TIME       — RFC3339 timestamp, surfaces in /version
#   - DISTROLESS_TAG   — `nonroot` (UID 65532) by default

ARG GO_VERSION=1.25
ARG DISTROLESS_TAG=nonroot

# --- Builder ---------------------------------------------------------------
# Alpine variant of the Go image: small, has git/ca-certs needed for go mod.
# --platform=$BUILDPLATFORM pins the builder to the *runner's* native arch
# (amd64 on GH-hosted runners) even when building an arm64 image. Combined
# with GOARCH=$TARGETARCH below, this cross-compiles instead of running the
# Go toolchain under QEMU translation — cuts multi-arch CI build from ~5 min
# to ~1 min. CGO_ENABLED=0 makes this safe (no platform-specific linker).
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS builder
WORKDIR /src

# Cache deps separately from source — only invalidated when go.{mod,sum} change.
COPY go.mod go.sum ./
RUN go mod download

# Now copy the source — this is the layer that changes most often.
COPY . .

ARG BUILD_SHA=unknown
ARG BUILD_TIME=unknown
# TARGETOS / TARGETARCH are injected by buildx per --platform entry.
# Single-arch local builds get sensible defaults via the := fallback.
ARG TARGETOS=linux
ARG TARGETARCH=amd64
# CGO off → fully static binary (works in distroless static).
ENV CGO_ENABLED=0

# -trimpath  : strip workspace paths from the binary (reproducible builds).
# -s -w      : strip symbol + debug tables (smaller image).
# -X main.X=Y: inject build-time vars consumed by /version.
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build \
    -trimpath \
    -ldflags "-s -w -X main.buildSHA=${BUILD_SHA} -X main.buildTime=${BUILD_TIME}" \
    -o /out/app \
    ./

# --- Runtime ---------------------------------------------------------------
# distroless/static : has ca-certs + tzdata + nothing else. No shell.
# :nonroot tag      : default UID/GID = 65532, matches chart runAsUser.
FROM gcr.io/distroless/static-debian12:${DISTROLESS_TAG}

COPY --from=builder /out/app /app

USER nonroot:nonroot
EXPOSE 8080
# ENTRYPOINT (not CMD) so `docker run image --flag` would forward to the binary.
# The binary takes no flags today; ENTRYPOINT just keeps the door open.
ENTRYPOINT ["/app"]
