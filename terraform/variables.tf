variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-north-1"
}

variable "github_owner" {
  description = "GitHub user or org that owns the repo trusted by AWS OIDC."
  type        = string
  default     = "borailci"
}

variable "github_repo" {
  description = "GitHub repository name trusted by AWS OIDC."
  type        = string
  default     = "insider-one-devops"
}

variable "github_ref_subjects" {
  description = "OIDC subject claims allowed to assume the deploy role."
  type        = list(string)
  default = [
    "repo:borailci/insider-one-devops:ref:refs/heads/main",
    "repo:borailci/insider-one-devops:environment:prod",
  ]
}

variable "ec2_instance_id" {
  description = "EC2 instance ID running minikube (set after Day 4 EC2 apply)."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type.
      t3.medium (2 vCPU / 4 GiB) — default; fits minikube + ingress-nginx + kube-prometheus-stack + app.
      t3.small  (2 vCPU / 2 GiB) — minimum viable; obs stack often OOMs.
      t3.micro  (2 vCPU / 1 GiB) — free-tier eligible on new accounts, but obs stack will NOT fit.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "operator_cidr" {
  description = "CIDR allowed to SSH (22/tcp) to the EC2 host. Set to your home/office IP/32. Defaults to 0.0.0.0/0 — narrow it before applying."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key" {
  description = "SSH public key material to install on the EC2 host (`ec2-user` on AL2023). Leave empty to skip key creation and rely on SSM Session Manager."
  type        = string
  default     = ""
}

variable "project_tag" {
  description = "Value for the `Project` tag applied to every resource — used by AC-26 (single tagged stack) and AC-29 (cost allocation)."
  type        = string
  default     = "insider-one-devops"
}
