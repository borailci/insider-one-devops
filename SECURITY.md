# SECURITY

This document covers the threat model summary, secret-handling rules, image-scan policy, the OIDC trust boundary between GitHub Actions and AWS, and how to report a vulnerability. It is a living document — update it when controls change.

Traceability: FR-32, AC-36, NFR-4, NFR-5, NFR-6.

---

## 1. Threat model summary

The service has a small attack surface — three HTTP endpoints, no auth, no persistent storage, no user-supplied data beyond headers. The actual risk surface lives in the **delivery path**:

| Asset | Threat | Control |
|---|---|---|
| Source code on GitHub | Malicious PR introduces backdoor or secret leak | Branch protection on `main`; required CI checks (lint/test/helm/gitleaks/Trivy); CODEOWNERS; PR template |
| Container image | Known CVE in base or stdlib | Multi-stage build; `gcr.io/distroless/static-debian12:nonroot` (no shell / no package manager); Trivy scan on every build fails on `CRITICAL` or `HIGH` (NFR-4) |
| Image registry | Tampered image with same tag | GHCR uses immutable digests; `:latest` and `:<sha>` are pushed together so the SHA tag is the audit anchor |
| CI → AWS credentials | Long-lived keys leak from runner / repo | No keys exist. CI assumes `insider-one-devops-github-deploy` via OIDC. Trust policy restricts `sub` claim to `repo:borailci/insider-one-devops:ref:refs/heads/main` and `…:environment:prod` |
| EC2 host | Unauthorized inbound | Security Group: 80/443 from world (the public URL), 22 narrowed to operator CIDR. **Kubernetes API not exposed publicly.** No SSH key in CI; CI never opens an inbound port — it uses SSM |
| EC2 → AWS API | Over-privileged instance role | Instance profile holds only `AmazonSSMManagedInstanceCore` (managed AWS policy). It does not grant Kubernetes, EC2, or IAM mutations |
| Runtime pod | Privilege escalation / rootfs write | Pod and container `securityContext`: `runAsNonRoot: true`, `runAsUser: 65532`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` (NFR-6, AC-18) |
| Logs | Sensitive data leakage | The app logs only request metadata (method, path, status, duration, request_id) — never request bodies. Add an explicit redactor before logging anything user-supplied |

### Out of scope

- DDoS resilience. The case-study scope is single-instance; mitigation is "destroy the EIP and re-provision" rather than scrubbing.
- Multi-tenant isolation. There is one tenant.
- Compliance frameworks (SOC 2, PCI). N/A for the case study.

---

## 2. Secret handling

**Rule:** No secret material ever lands in the repository, the image, the Helm values files, or GitHub Actions logs.

| Secret | Where it lives | How CI reaches it |
|---|---|---|
| `AWS_DEPLOY_ROLE_ARN` (the role *name*, not a credential) | GitHub Actions repository secret | `${{ secrets.AWS_DEPLOY_ROLE_ARN }}` in `ci.yml` |
| `EC2_INSTANCE_ID` | GitHub Actions repository secret | `${{ secrets.EC2_INSTANCE_ID }}` in `ci.yml` |
| Temporary AWS credentials | Issued by AWS STS in response to OIDC token | `aws-actions/configure-aws-credentials@v4` exports env vars for the job duration only |
| `GITHUB_TOKEN` | Auto-issued by Actions | Used for GHCR push (`docker/login-action`); never persisted |
| Image-runtime secrets | `charts/app/templates/secret.yaml` (Kubernetes Secret) | Helm `secrets:` values; in production these would come from `--set-string` or an external secret store, not the values file |

**Controls:**

- `gitleaks` runs on every push and PR with default rules plus the project's `.gitleaks.toml` allowlist. Any pattern matching a private key, AWS access key, or known token format fails CI (NFR-5).
- `.gitignore` excludes `.env`, `.env.*` (except `.env.example`), `terraform/*.tfstate*`, and `terraform/*.tfvars` (except `*.tfvars.example`).
- `.env.example` documents the env-var contract with placeholder values only.

If a secret leaks anyway:

1. Rotate the credential immediately in its source system (AWS, GitHub, etc.).
2. Force-push a history rewrite is **not** sufficient — assume the secret is permanently compromised.
3. Open a private security advisory on GitHub describing the blast radius.

---

## 3. Image-scan policy

Every container image is scanned by Trivy in CI before it is pushed to GHCR.

| Setting | Value | Rationale |
|---|---|---|
| Action | `aquasecurity/trivy-action@v0.36.0` | Pinned tag, not `@main` |
| `severity` | `CRITICAL,HIGH` | NFR-4 |
| `exit-code` | `1` | Hard-fail the job |
| `ignore-unfixed` | `true` | Don't block on vulns with no upstream fix; revisit weekly |
| `vuln-type` | `os,library` | Includes the Go stdlib via the `gobinary` analyzer |
| Scope | Built image (not the source tree) | Catches transitive CVEs the source can't see |

**On a finding:**

1. Read the Trivy report attached to the failed job.
2. If the CVE is in the **stdlib**, bump the Go version in `Dockerfile`'s `ARG GO_VERSION` and `ci.yml`'s `GO_VERSION` env (see Day-3 Go 1.23 → 1.25 incident).
3. If the CVE is in **distroless**, swap to a newer digest in the Dockerfile `FROM` line.
4. If the CVE is in a **library**, bump the Go module: `go get example.com/lib@vX.Y.Z && go mod tidy`.
5. Open the PR with the CVE id in the commit message.

There is no exception process. CRITICAL/HIGH blocks merge.

---

## 4. OIDC trust boundary

The single most important security artifact in this repo is `terraform/iam-oidc.tf`. It is the only thing keeping the AWS account safe from the public GitHub repo.

```
GitHub Actions runner
   │  1. Workflow on ref refs/heads/main requests an OIDC token
   ▼
token.actions.githubusercontent.com  (signs token with `sub=repo:borailci/insider-one-devops:ref:refs/heads/main`)
   │
   ▼  2. Runner presents token to AWS STS
AWS STS / sts.amazonaws.com
   │  3. STS validates against the OIDC provider in our account
   │     and checks the role's assume_role_policy conditions
   ▼
   IAM role `insider-one-devops-github-deploy`
   │  4. Returns short-lived (~1 h) creds limited to this role
   ▼
Workflow steps run with those creds — and only those creds
```

**Pinned guarantees:**

- `aud == sts.amazonaws.com` (locks the audience claim).
- `sub IN ("repo:borailci/insider-one-devops:ref:refs/heads/main", "repo:borailci/insider-one-devops:environment:prod")` — a workflow on a feature branch **cannot** assume this role.
- The role's inline policy grants exactly `ec2:DescribeInstances`, `ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`, `ssm:DescribeInstanceInformation`. Nothing else.
- Resources are `*` for SSM (the API doesn't support narrowing `SendCommand` to a single instance ARN reliably) — accepted risk: this account holds only the case-study workload.

**If the repo gets forked:**

The `sub` claim is owner-scoped (`repo:borailci/...`). A fork at `repo:someone-else/insider-one-devops` cannot assume the role.

**If the role gets stolen via misconfig:**

The maximum blast radius is `ssm:SendCommand` on EC2 instances in the AWS account. An attacker can run arbitrary shell on the one EC2 instance. Mitigation: terminate the instance, rotate `assume_role_policy` to lock the trust temporarily, then re-provision.

---

## 5. Runtime hardening

Pod / container `securityContext` (rendered in every deployment):

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65532
  capabilities:
    drop: [ALL]
```

The distroless `nonroot` base ships UID 65532 with no shell, no package manager, no setuid binaries. Combined with `readOnlyRootFilesystem`, an attacker who lands code execution inside the container can write only to the pod's emptyDir (none mounted) — they cannot install tools, persist artifacts, or escalate.

---

## 6. Reporting a vulnerability

If you find a security issue in this repository:

1. **Do not open a public issue.**
2. Open a **GitHub Security Advisory** at <https://github.com/borailci/insider-one-devops/security/advisories/new> with reproduction steps and the affected commit SHA.
3. If GitHub is unavailable, email `borailci16@gmail.com` with `[insider-one-devops SECURITY]` in the subject.

Expected response: an acknowledgement within 72 hours. As a case-study artifact this project has no SLA — the contact is best-effort.

---

## 7. Known gaps / accepted risks

| Item | Why accepted | Re-evaluate when |
|---|---|---|
| SSM `SendCommand` resource `*` (not narrowed to instance ARN) | API limitation; account isolation contains blast radius | If the account gains other workloads |
| Helm `secrets.{}` values committed (currently empty) | Placeholder only; gitleaks would fire if real | If the values gain real secret entries |
| EC2 has 22/tcp open from `var.operator_cidr` (defaults `0.0.0.0/0`) | Local-dev default | **Always** narrow to operator IP/32 in `terraform.tfvars` before `terraform apply` |
| No WAF / rate limiting | Out of scope for case study | If demo traffic risks DoS during grading |
| No image signing (cosign) / SBOM (syft) | Listed as bonus in case-study brief | If post-grading hardening is needed |
