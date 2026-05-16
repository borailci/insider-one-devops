# syntax=docker/dockerfile:1.7
# Multi-stage: static Go build → distroless non-root final image.
# Final image target: < 25 MB, no shell, no package manager.

ARG GO_VERSION=1.23
ARG DISTROLESS_TAG=nonroot

# --- Builder ---------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine AS builder
WORKDIR /src

# Cache deps separately from source.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG BUILD_SHA=unknown
ARG BUILD_TIME=unknown
ENV CGO_ENABLED=0 GOOS=linux

RUN go build \
    -trimpath \
    -ldflags "-s -w -X main.buildSHA=${BUILD_SHA} -X main.buildTime=${BUILD_TIME}" \
    -o /out/app \
    ./

# --- Runtime ---------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:${DISTROLESS_TAG}

COPY --from=builder /out/app /app

USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
