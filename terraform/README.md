# terraform/

Local-state Terraform for the case study infra. Day 3 ships only IAM. EC2 + EIP + SG land Day 4.

## What's here (Day 3)

| File | Purpose |
|------|---------|
| `versions.tf` | provider pins (aws ~> 5.60, tls ~> 4.0); region from `var.aws_region` |
| `variables.tf` | inputs: region, github owner/repo, allowed OIDC subjects, EC2 id (Day 4) |
| `iam-oidc.tf` | GitHub OIDC provider + IAM role + inline SSM policy for the CI deploy job |

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
| `EC2_INSTANCE_ID`     | EC2 console / Day 4 output | SSM target instance |

No long-lived AWS access keys go in the repo or in GitHub Actions secrets. The role is reachable only from the configured OIDC subjects (main branch + prod environment).
