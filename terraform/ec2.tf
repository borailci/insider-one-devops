# Day 4 — EC2 minikube host + Elastic IP + Security Group.
# Free-tier target: t3.micro on Amazon Linux 2023. SSM agent ships pre-installed.
# Resources are tagged `Project = var.project_tag` for AC-26 and AC-29.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# --- Security Group --------------------------------------------------------

resource "aws_security_group" "minikube_host" {
  name        = "${var.project_tag}-minikube"
  description = "Minikube host: inbound HTTP/HTTPS public, SSH narrowed to operator CIDR."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP (public URL via ingress)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (reserved for cert-manager bonus)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH (operator only)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_tag
    Name    = "${var.project_tag}-minikube"
  }
}

# --- IAM: SSM agent role + instance profile --------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_managed" {
  name               = "${var.project_tag}-ec2-ssm"
  description        = "Lets the EC2 instance register with SSM so CI can run kubectl set image."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Project = var.project_tag
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_managed.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "minikube_host" {
  name = "${var.project_tag}-ec2-ssm"
  role = aws_iam_role.ssm_managed.name
}

# --- Optional SSH key pair -------------------------------------------------

resource "aws_key_pair" "operator" {
  count      = var.ssh_public_key == "" ? 0 : 1
  key_name   = "${var.project_tag}-operator"
  public_key = var.ssh_public_key

  tags = {
    Project = var.project_tag
  }
}

# --- EC2 instance + Elastic IP --------------------------------------------

resource "aws_instance" "minikube" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.minikube_host.id]
  iam_instance_profile   = aws_iam_instance_profile.minikube_host.name
  key_name               = var.ssh_public_key == "" ? null : aws_key_pair.operator[0].key_name

  user_data = file("${path.module}/../scripts/bootstrap-ec2.sh")

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20 # within 30 GiB free-tier allowance
    encrypted   = true
  }

  tags = {
    Project = var.project_tag
    Name    = "${var.project_tag}-minikube"
    Role    = "minikube-host"
  }
}

resource "aws_eip" "minikube" {
  instance = aws_instance.minikube.id
  domain   = "vpc"

  tags = {
    Project = var.project_tag
    Name    = "${var.project_tag}-eip"
  }
}

# --- Outputs ---------------------------------------------------------------

output "ec2_instance_id" {
  description = "Set as GitHub Actions secret EC2_INSTANCE_ID."
  value       = aws_instance.minikube.id
}

output "public_ip" {
  description = "Elastic IP — the public URL points here once ingress is up."
  value       = aws_eip.minikube.public_ip
}

output "public_url" {
  description = "Demo URL (Host header required to match ingress host)."
  value       = "http://${aws_eip.minikube.public_ip}"
}
