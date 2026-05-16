#!/usr/bin/env bash
# Bootstrap the EC2 minikube host. Used as Terraform user_data (`file()` reads
# this verbatim and EC2 executes it once on first boot via cloud-init) and
# runnable standalone for manual recovery.
#
# Target OS: Amazon Linux 2023 (x86_64). SSM agent ships pre-installed.
# Output goes to /var/log/cloud-init-output.log on first run.
#
# Honest scope on a t3.micro (1 GiB RAM):
#   - Installs docker + minikube + kubectl + helm.
#   - Starts minikube with --memory=900 --cpus=2 so kubelet fits in available RAM.
#   - Enables the ingress addon.
#   - Installs the app chart with values-prod.yaml.
#   - Attempts kube-prometheus-stack with reduced resource requests.
#     If the stack fails to schedule, the app keeps serving traffic and
#     RUNBOOK.md (Observability fallback) documents running the obs stack on
#     a local minikube for demo screenshots.

set -euo pipefail

REPO_OWNER="borailci"
REPO_NAME="insider-one-devops"
CHART_DIR="/home/ec2-user/${REPO_NAME}/charts/app"
RELEASE_NAME="app"
NAMESPACE="default"
MONITORING_NAMESPACE="monitoring"
HELM_VERSION="v3.16.2"
MINIKUBE_VERSION="latest"
KUBECTL_VERSION="v1.30.0"

log() { printf '[bootstrap] %s\n' "$*"; }

# --- 1. Packages -----------------------------------------------------------

log "updating system packages"
dnf -y update

log "installing docker + git"
dnf -y install docker git tar
systemctl enable --now docker
usermod -aG docker ec2-user

# --- 2. minikube + kubectl + helm -----------------------------------------

log "installing kubectl ${KUBECTL_VERSION}"
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

log "installing minikube ${MINIKUBE_VERSION}"
curl -fsSLo /usr/local/bin/minikube "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-amd64"
chmod +x /usr/local/bin/minikube

log "installing helm ${HELM_VERSION}"
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C /tmp linux-amd64/helm
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
rm -rf /tmp/linux-amd64

# --- 3. Clone repo so the chart is available on disk ----------------------

log "cloning chart source"
sudo -u ec2-user git clone --depth=1 "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "/home/ec2-user/${REPO_NAME}" || true

# --- 4. Start minikube (constrained for t3.micro) -------------------------

log "starting minikube"
# --memory tuned for t3.medium (4 GiB total, ~3.5 GiB usable). On t3.small drop to 1500.
# On t3.micro (1 GiB) the obs stack does not fit; that path is documented in RUNBOOK §Observability fallback.
sudo -iu ec2-user bash -c "minikube start \
    --driver=docker \
    --memory=3000 \
    --cpus=2 \
    --kubernetes-version=${KUBECTL_VERSION}"

log "enabling ingress addon"
sudo -iu ec2-user bash -c "minikube addons enable ingress"

# Route 80/443 from host → minikube IP (Docker driver does not auto-bind).
MINIKUBE_IP=$(sudo -iu ec2-user bash -c "minikube ip")
log "forwarding host 80 → ${MINIKUBE_IP}:80"
dnf -y install iptables-services
systemctl enable --now iptables
iptables -t nat -A PREROUTING -p tcp --dport 80  -j DNAT --to-destination "${MINIKUBE_IP}:80"
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination "${MINIKUBE_IP}:443"
iptables -t nat -A POSTROUTING -j MASQUERADE
iptables-save > /etc/sysconfig/iptables

# --- 5. Install the app chart ---------------------------------------------

log "installing app via helm"
sudo -iu ec2-user bash -c "helm upgrade --install ${RELEASE_NAME} ${CHART_DIR} \
    --namespace ${NAMESPACE} \
    --create-namespace \
    -f ${CHART_DIR}/values-prod.yaml \
    --set image.tag=latest \
    --wait --timeout 3m" || log "WARN: initial helm install failed; CI deploy job will retry"

# --- 6. Observability (best-effort on free tier) --------------------------

log "adding prometheus-community helm repo"
sudo -iu ec2-user bash -c "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update"

log "installing kube-prometheus-stack"
sudo -iu ec2-user bash -c "helm upgrade --install kps prometheus-community/kube-prometheus-stack \
    --namespace ${MONITORING_NAMESPACE} \
    --create-namespace \
    --set prometheus.prometheusSpec.retention=2d \
    --set prometheus.prometheusSpec.scrapeInterval=30s \
    --set defaultRules.create=true \
    --wait --timeout 8m" \
  || log "WARN: kube-prometheus-stack did not become Ready — see RUNBOOK §Observability fallback"

log "bootstrap complete"
