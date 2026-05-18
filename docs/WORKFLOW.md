# WORKFLOW.md — how a change gets from your editor to the live URL

This is the operational counterpart to [`docs/architecture.md`](architecture.md). It walks one change through every gate the repo enforces, with the actual commands at each step.

---

## Quick reference (the whole loop in 6 commands)

```bash
# 1. local
make test                          # unit tests + race + cover
make docker-build                  # multi-stage image build

# 2. ship
git commit -m "feat(...): ..."     # Conventional Commits
git push origin main               # triggers CI

# 3. verify
gh run watch                       # 7 jobs go green
curl http://$EIP/version   # live URL serves the new SHA
```

Everything below is what happens between those commands.

---

## Stage 0 — bring the live stack up (one-time per session)

```bash
cd terraform
terraform init
terraform apply -auto-approve
# wait ~5–10 min for cloud-init
```

This provisions:
- AL2023 t3.medium EC2 in `eu-north-1`
- Elastic IP (the public URL — `terraform output public_ip`)
- Security Group: 80/443 open to world, 22 only to operator CIDR
- IAM OIDC role `insider-one-devops-github-deploy` trusted by GitHub Actions
- Cloud-init runs `scripts/bootstrap-ec2.sh` which installs Docker + minikube + kubectl + helm and lays down: **Kyverno → policies → kube-prometheus-stack → app** in that order.

Bootstrap finished marker: `/var/log/bootstrap-done`.

`terraform destroy -auto-approve` reverses everything (see [CHECKLIST.md](CHECKLIST.md#9-tear-down-stop-the-meter)).

---

## Stage 1 — edit & verify locally

Anything in `main.go`, `charts/`, or `.github/workflows/ci.yml`:

```bash
# Fast feedback loop
go test ./... -race -cover -count=1
go run .                  # PORT=8080 by default
curl localhost:8080/ping  # "pong"
curl localhost:8080/healthz
curl localhost:8080/version  # sha=unknown locally — only Docker injects it
```

For chart changes:

```bash
helm lint charts/app
helm lint charts/app -f charts/app/values-dev.yaml
helm lint charts/app -f charts/app/values-prod.yaml
helm template app charts/app -f charts/app/values-prod.yaml | kubeconform -strict -summary -kubernetes-version 1.30.0 -skip ServiceMonitor,PrometheusRule
```

A full end-to-end on the laptop (kind cluster):

```bash
make demo  # spins minikube + installs chart + helm test + smoke curl
```

---

## Stage 2 — commit (the Conventional Commits gate)

Format: `<type>(<scope>): <subject>`. Examples already in `git log`:

```
feat(ci+policy): supply-chain trifecta, kind integration test, Kyverno cluster policies
fix(chart): give helm-test pods resources so Kyverno admits them
fix(ci): deploy job — use ec2-user on AL2023, target helm fullname app-app
```

Why it matters: future automation (changelog generators, semver bots) reads these prefixes. `fix:` → patch bump, `feat:` → minor, `BREAKING CHANGE:` → major.

`gitleaks` runs on every push and PR. If you accidentally stage a secret, the push is rejected on the local `pre-commit` hook (when installed) or in CI.

---

## Stage 3 — CI pipeline (`.github/workflows/ci.yml`)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Triggered by:                                                        │
│   push to main         → full pipeline (incl. deploy)                │
│   pull_request → main  → all gates except deploy                     │
│   workflow_dispatch    → manual run                                  │
└──────────────────────────────────────────────────────────────────────┘

   lint            test            helm-validate         gitleaks
(golangci-lint) (race + cover)   (lint + kubeconform)   (full history)
        │             │                  │                  │
        └─────────────┴──────────────────┴──────────────────┘
                              ▼
              build-scan-push   ← parallel gates must all pass
              ─────────────────
              1. buildx multi-arch (linux/amd64, linux/arm64)
              2. Trivy scan        (fail on CRITICAL/HIGH)
              3. Push GHCR         (tags: <short-sha>, latest)
              4. cosign sign       (keyless, OIDC → Sigstore)
              5. cosign verify     (gate — fail if sign didn't take)
              6. Syft → CycloneDX SBOM
              7. cosign attest     (--type cyclonedx, .att tag in GHCR)
                              │
              ┌───────────────┴─────────────────┐
              ▼                                 ▼
     integration-test                        deploy
     ──────────────────                      ──────────────
     kind cluster                            AWS OIDC assume-role
     load image                              SSM Run-Command:
     helm upgrade --install                    kubectl set image
     wait + smoke /ping /healthz /version      kubectl rollout status
     helm test (chart-bundled tests)         (no SSH key — audited in CloudTrail)
```

### What each gate actually catches

| Gate | Catches |
|---|---|
| **lint** | unused vars, shadowed errors, gosec issues |
| **test** | race conditions, broken handlers, coverage regressions |
| **helm-validate** | malformed YAML, fields that don't exist in k8s 1.30 schema |
| **gitleaks** | accidentally committed secrets, including bare tokens in `.env` |
| **Trivy** | CVEs in base image, Go stdlib, dependencies (CRITICAL/HIGH fail) |
| **cosign sign + verify** | provenance — the image was built by *this* repo's CI on *this* commit |
| **kind integration** | chart-level regressions (bad probe, missing label, broken template) |
| **deploy preflight** | secrets configured; skip gracefully when stack is torn down |

### What each provenance artifact gives you

- `.sig` tag on GHCR — Sigstore signature; verifiable with `cosign verify`. Subject claim includes the workflow URL + commit SHA, so a fork cannot impersonate it.
- `.att` tag on GHCR — Sigstore attestation wrapping a CycloneDX SBOM. Verifiable with `cosign verify-attestation`.
- SARIF upload — Trivy findings appear on the repo's **Security → Code scanning** tab.

---

## Stage 4 — deploy (auto, on merge to `main`)

The `deploy` job runs **only on push to main** (skips on PRs). Flow:

```
GitHub Actions runner
       │
       │ 1. Configure AWS credentials via OIDC
       │    (no long-lived keys; ID-token exchanged for STS creds)
       ▼
arn:aws:iam::<account-id>:role/insider-one-devops-github-deploy
       │
       │ 2. aws ssm send-command
       │    target = $EC2_INSTANCE_ID  (from terraform output)
       │    commands = [
       │      "sudo -iu ec2-user kubectl -n default \
       │         set image deployment/app-app app=ghcr.io/.../insider-one-devops:<sha>",
       │      "sudo -iu ec2-user kubectl -n default \
       │         rollout status deployment/app-app --timeout=120s"
       │    ]
       ▼
EC2 → minikube → Deployment app-app rolling update
       │
       │ 3. Readiness probe on /healthz gates the new pod into the Service
       │ 4. ingress-nginx routes traffic only when all new pods Ready
       ▼
http://$EIP/version  →  {"sha":"<new-sha>", ...}
```

Why `kubectl set image` not GitOps (ArgoCD/Flux): single-node minikube target + small team → an extra controller is more moving parts than it saves. ADR-0003 records the trade-off.

---

## Stage 5 — observe

```bash
# Endpoint health (from anywhere)
curl http://$EIP/{ping,healthz,version}

# Pod health (via SSM, no SSH)
INSTANCE_ID=$(cd terraform && terraform output -raw ec2_instance_id)
aws ssm send-command --region eu-north-1 --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo -iu ec2-user kubectl get pods -A"]'

# Grafana dashboard (RPS / latency / error rate)
# 1. open port-forward on EC2 (one-shot SSM Run-Command from CHECKLIST §5a)
# 2. aws ssm start-session ... --document-name AWS-StartPortForwardingSession
# 3. browser → localhost:3000 → admin / <pw>
```

Alerting: `PrometheusRule` (`charts/app/templates/prometheusrule.yaml`) declares:
- `AppDown` — fires after 1m of no `up=1` pods (severity: critical)
- `HighErrorRate` — fires after 5m of 5xx ratio > threshold (severity: warning)

Alertmanager (deployed by kube-prometheus-stack) handles routing. Wire to email/Slack via the kps values file when needed.

---

## Stage 6 — verify supply chain (anyone, anytime)

```bash
# Get the image digest
TOKEN=$(curl -s 'https://ghcr.io/token?scope=repository:borailci/insider-one-devops:pull' | jq -r .token)
DIGEST=$(curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  "https://ghcr.io/v2/borailci/insider-one-devops/manifests/<short-sha>" \
  | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r\n')

# Verify the signature
cosign verify "ghcr.io/borailci/insider-one-devops@$DIGEST" \
  --certificate-identity-regexp 'https://github.com/borailci/insider-one-devops/.github/workflows/ci.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Verify the SBOM
cosign verify-attestation "ghcr.io/borailci/insider-one-devops@$DIGEST" \
  --type cyclonedx \
  --certificate-identity-regexp 'https://github.com/borailci/insider-one-devops/.github/workflows/ci.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The `--certificate-identity-regexp` clause is the key bit: it binds the signature to the exact workflow file in this exact repo. A different repo signing the same image with valid OIDC would fail verification here.

---

## Failure modes & recovery

| Symptom | Likely cause | Recovery |
|---|---|---|
| CI `deploy` red, "Status: Failed" from SSM | EC2 was destroyed but secret still points at the old instance | Re-apply terraform OR delete `EC2_INSTANCE_ID` secret (preflight skips deploy) |
| Pods stuck `ImagePullBackOff` after deploy | `image.tag` not pushed yet, or repo private without GHCR pull secret | Check `gh run view` for build-scan-push status; verify GHCR visibility = public |
| `helm test app` says "pod not found" | Kyverno policy rejected the test pod | Confirm test pod has resources block + non-root securityContext (current chart) |
| `kubectl run nginx-bad` is *allowed* | Kyverno not installed or policies not loaded | `helm list -n kyverno` should show `kyverno` and `policies` |
| `/version` shows old SHA after deploy | rollout not finished | `kubectl rollout status deployment/app-app -n default` |
| AWS costs creep | EC2 left running overnight | `cd terraform && terraform destroy -auto-approve` |

---

## Files that own each stage

| Stage | Owner files |
|---|---|
| Bring-up | `terraform/*.tf`, `scripts/bootstrap-ec2.sh` |
| Local dev | `main.go`, `main_test.go`, `Makefile`, `Dockerfile` |
| Commit format | `.github/PULL_REQUEST_TEMPLATE.md`, `CODEOWNERS` |
| CI | `.github/workflows/ci.yml`, `.golangci.yml`, `.gitleaks.toml` |
| Image content | `Dockerfile` |
| K8s desired state | `charts/app/templates/*`, `charts/app/values-{dev,prod}.yaml` |
| Policy / guardrails | `charts/policies/templates/*` (Kyverno ClusterPolicies) |
| Observability | `charts/app/templates/servicemonitor.yaml`, `prometheusrule.yaml`, `dashboards/*.json` |
| Docs | `README.md`, `RUNBOOK.md`, `SECURITY.md`, `docs/adr/*`, `docs/diagrams/*` |
| Demo evidence | `docs/CHECKLIST.md` |
