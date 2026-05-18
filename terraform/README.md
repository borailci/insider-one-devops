# terraform/

Local-state Terraform for the case study infra. Day 3 ships IAM; Day 4 adds EC2 + EIP + SG.

## What's here

| File | Purpose |
|------|---------|
| `versions.tf` | provider pins (aws ~> 5.60, tls ~> 4.0); region from `var.aws_region` |
| `variables.tf` | inputs: region, github owner/repo, allowed OIDC subjects, instance type, operator CIDR, SSH key, project tag |
| `iam-oidc.tf` | GitHub OIDC provider + IAM role + inline SSM policy for the CI deploy job |
| `ec2.tf` | one EC2 (`t3.medium` AL2023 — sized for kube-prom-stack) + Elastic IP + Security Group + SSM instance profile |
| `../scripts/bootstrap-ec2.sh` | cloud-init user-data — installs docker / minikube / kubectl / helm and installs the app chart |

## Before you apply

Always narrow SSH. Create `terraform.tfvars` (gitignored):

```hcl
operator_cidr  = "203.0.113.42/32"          # your IP/32
ssh_public_key = "ssh-ed25519 AAAA... user"  # optional; omit to rely on SSM-only access
# instance_type = "t3.medium"                # default; bump to "t3.large" if obs stack OOMs
```

## Apply

```sh
cd terraform/
terraform init
terraform plan
terraform apply
# Copy github_deploy_role_arn output into GitHub repo secret AWS_DEPLOY_ROLE_ARN.
```

State is local (`terraform.tfstate`) and gitignored. Do not commit `*.tfstate` or `*.tfvars` — only `*.tfvars.example`.

## GitHub Actions secrets required

| Secret | Source | Notes |
|--------|--------|-------|
| `AWS_DEPLOY_ROLE_ARN` | `terraform output github_deploy_role_arn` | Role assumed by CI via OIDC |
| `EC2_INSTANCE_ID`     | `terraform output ec2_instance_id`        | SSM target instance |

No long-lived AWS access keys go in the repo or in GitHub Actions secrets. The role is reachable only from the configured OIDC subjects (main branch + prod environment).

## Tear-down

```sh
terraform destroy
```

Destroys EC2 + EIP + SG + instance profile + OIDC provider + role in one go. Run this whenever the demo is not active — a stopped EC2 with an attached EIP still incurs the EIP detached-from-running-instance charge (~$3.60/mo).
