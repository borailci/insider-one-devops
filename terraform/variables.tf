variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-central-1"
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
