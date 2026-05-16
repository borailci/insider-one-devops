SHELL := /bin/bash

APP        ?= app
IMAGE      ?= ghcr.io/borailci/insider-one-devops
BUILD_SHA  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
BUILD_TIME ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS    := -s -w -X main.buildSHA=$(BUILD_SHA) -X main.buildTime=$(BUILD_TIME)

.PHONY: help
help: ## List targets
	@awk 'BEGIN{FS=":.*?## "} /^[a-zA-Z_-]+:.*## /{printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: build
build: ## Build local binary into ./app
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" -o $(APP) .

.PHONY: run
run: ## Run service (PORT=8080 by default)
	go run .

.PHONY: test
test: ## Run tests with race + coverage
	go test ./... -race -cover

.PHONY: cover
cover: ## Generate HTML coverage report
	go test ./... -race -coverprofile=coverage.out
	go tool cover -html=coverage.out -o coverage.html

.PHONY: lint
lint: ## Run golangci-lint (requires local install)
	golangci-lint run ./...

.PHONY: tidy
tidy: ## go mod tidy
	go mod tidy

.PHONY: docker-build
docker-build: ## Build container image
	docker build \
		--build-arg BUILD_SHA=$(BUILD_SHA) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(IMAGE):$(BUILD_SHA) \
		-t $(IMAGE):latest \
		.

.PHONY: docker-run
docker-run: docker-build ## Build and run container locally on :8080
	docker run --rm -p 8080:8080 $(IMAGE):$(BUILD_SHA)

.PHONY: docker-size
docker-size: ## Print image size for the current tag
	@docker image inspect $(IMAGE):$(BUILD_SHA) --format '{{.Size}} bytes ({{div .Size 1048576}} MiB)'

.PHONY: clean
clean: ## Remove build artifacts
	rm -f $(APP) coverage.out coverage.html
