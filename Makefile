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
clean: ## Remove build artifacts and stray IaC state at the repo root
	rm -f $(APP) coverage.out coverage.html
	rm -f ./terraform.tfstate ./terraform.tfstate.backup
	find . -maxdepth 3 -name tfplan -type f -delete

# ---------------------------------------------------------------------------
# Bonus tracks: diagrams · supply-chain verify · one-command demo
# ---------------------------------------------------------------------------

PLANTUML_IMAGE ?= plantuml/plantuml:1.2024.7
DIAGRAMS_DIR   := docs/diagrams

.PHONY: diagrams
diagrams: ## Render docs/diagrams/*.puml -> .svg via PlantUML in Docker
	@command -v docker >/dev/null || { echo "docker is required for 'make diagrams'"; exit 1; }
	@docker run --rm -v "$$(pwd)/$(DIAGRAMS_DIR):/work" -w /work $(PLANTUML_IMAGE) \
		-tsvg -o /work *.puml
	@ls -1 $(DIAGRAMS_DIR)/*.svg

.PHONY: diagrams-check
diagrams-check: ## CI: fail if committed SVGs are stale vs .puml sources
	@$(MAKE) diagrams >/dev/null
	@git diff --quiet -- $(DIAGRAMS_DIR) || { \
		echo "Committed SVGs are out of date. Run 'make diagrams' and commit the result."; \
		git --no-pager diff --stat -- $(DIAGRAMS_DIR); \
		exit 1; \
	}

.PHONY: sign-verify
sign-verify: ## Verify the latest signed image with cosign (keyless, GH OIDC issuer)
	@command -v cosign >/dev/null || { echo "cosign not installed. brew install cosign"; exit 1; }
	@digest=$$(docker buildx imagetools inspect $(IMAGE):latest --format '{{json .Manifest}}' | sed -n 's/.*"digest":"\(sha256:[a-f0-9]*\)".*/\1/p' | head -n1); \
	test -n "$$digest" || { echo "could not resolve digest for $(IMAGE):latest"; exit 1; }; \
	echo "Verifying $(IMAGE)@$$digest"; \
	cosign verify $(IMAGE)@$$digest \
		--certificate-identity-regexp "^https://github.com/borailci/insider-one-devops/.github/workflows/.*$$" \
		--certificate-oidc-issuer https://token.actions.githubusercontent.com

.PHONY: demo
demo: ## End-to-end local demo: minikube + chart + chart tests + smoke curl
	@command -v minikube >/dev/null || { echo "minikube not installed"; exit 1; }
	@command -v helm >/dev/null || { echo "helm not installed"; exit 1; }
	@command -v kubectl >/dev/null || { echo "kubectl not installed"; exit 1; }
	@minikube status >/dev/null 2>&1 || minikube start --driver=docker --memory=3000 --cpus=2
	@minikube addons enable ingress
	helm upgrade --install $(APP) charts/app -f charts/app/values-dev.yaml --wait --timeout 3m
	kubectl rollout status deployment/$(APP)-app --timeout=60s
	helm test $(APP)
	@echo "---"
	@echo "Service reachable via port-forward:"
	@echo "  kubectl port-forward svc/$(APP)-app 8080:80 &"
	@echo "  curl http://localhost:8080/ping"
	@echo "If kube-prometheus-stack is installed, Grafana via:"
	@echo "  kubectl -n monitoring port-forward svc/kps-grafana 3000:80"
