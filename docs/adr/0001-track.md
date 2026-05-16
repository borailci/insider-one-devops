# 0001 — Track A: Minikube on free-tier EC2 + Elastic IP

- **Status:** Accepted
- **Date:** 2026-05-16
- **Deciders:** Bora İlci
- **Tags:** infra, cost, deploy-target
- **Traceability:** FR-23, FR-24, FR-25, NFR-10, AC-26, AC-28, AC-29

## Context

The case study brief lets candidates choose between two paths for exposing the service on a public URL:

- **Track A** — provision a real cloud host (AWS free-tier EC2), attach an Elastic IP, run minikube on it.
- **Track B** — run minikube locally and expose it through an ngrok or cloudflared tunnel.

Track A demonstrates IaC (Terraform), AWS OIDC (no long-lived keys in CI), real cloud networking (Security Groups, EIP), and remote operations (SSM). Track B is faster and free but reduces the IaC narrative to "I ran a tunnel binary."

The graded signal in this case study weights DevOps surface area, not application correctness, so the choice meaningfully changes how much of the rubric is exercised.

## Decision

Use **Track A**:

- One `t3.micro` (Amazon Linux 2023) provisioned by Terraform.
- One Elastic IP, attached.
- One Security Group (22/tcp narrowed to operator CIDR; 80/443 from 0.0.0.0/0).
- One IAM instance profile granting `AmazonSSMManagedInstanceCore` so CI can drive `kubectl set image` via `aws ssm send-command` (no inbound API server exposure, no kubeconfig in CI).
- Bootstrap installs Docker + minikube + kubectl + Helm via cloud-init user-data.

`t3.micro` was chosen because **NFR-10 caps spend at $0** within the AWS 12-month free tier. `t3.small` (~$15/mo) would give comfortable headroom for `kube-prometheus-stack`, but the budget constraint is binding. See "Consequences" for how the observability story adapts.

## Options considered

### A. Track A — minikube on free-tier EC2 (chosen)

- **Pros:** real cloud surface (VPC, SG, EIP, IAM, SSM); Terraform exercised end-to-end; OIDC trust boundary demonstrated; persistent public URL while EC2 runs; strongest resume artifact.
- **Cons:** AWS account required; ongoing cost outside the 12-month free tier (~$8–15/mo); `t3.micro` is tight on RAM for the full obs stack.

### B. Track B — local minikube + tunnel

- **Pros:** $0 unconditionally; faster setup (no AWS work); demo runs anywhere a laptop runs.
- **Cons:** public URL dies with the laptop; no IaC narrative; ADR-0003 (deploy-strategy) loses the SSM angle; weaker rubric coverage for the "cloud + DevOps surface" criterion.

### C. Track A on `t3.small` (paid)

- **Pros:** comfortable headroom for kube-prometheus-stack + ingress + app on the EC2 host; honest demo of full observability stack at the public URL.
- **Cons:** ~$15/mo. Violates the implicit budget the case study sets by mentioning "free tier."

## Consequences

### Positive

- Demonstrates Terraform, AWS OIDC, SSM, EIP, IAM least-privilege — five rubric items on one path.
- `terraform/` becomes a load-bearing deliverable rather than a stub.
- Public URL is stable across the grading window.

### Negative / accepted risk

- `t3.micro` (1 GiB RAM) is below the documented minikube minimum (2 GiB) once `kube-prometheus-stack` is included. `scripts/bootstrap-ec2.sh` reduces requests for Prometheus / Grafana / Alertmanager, but the stack may still fail to schedule under load.
- **Fallback documented in `RUNBOOK.md` § Observability fallback:** if EC2 cannot host the obs stack, run `kube-prometheus-stack` on a local minikube on the operator workstation for demo screenshots. The EC2 host then serves only the app at the public URL. The chart (`charts/app/templates/servicemonitor.yaml`, `prometheusrule.yaml`) and dashboard (`dashboards/app.json`) are environment-agnostic.
- ADR-0003 (deploy strategy) depends on this choice — switching to Track B would also remove the `kubectl set image` via SSM design and replace it with manual `helm upgrade`.

### Cost guardrails

- Terraform is checked in but **not** auto-applied — the operator runs `terraform apply` when needed and `terraform destroy` when the demo window ends.
- A single EIP attached to a running instance is free. A *detached* EIP costs ~$3.60/mo — `terraform destroy` removes both atomically.
- 20 GiB gp3 root volume sits well under the 30 GiB free-tier ceiling.
