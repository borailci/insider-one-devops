#!/usr/bin/env bash
# Bootstrap the EC2 minikube host. Used as Terraform user_data (`file()` reads
# this verbatim and EC2 executes it once on first boot via cloud-init) and
# runnable standalone for manual recovery.
#
# Target OS: Amazon Linux 2023 (x86_64). SSM agent ships pre-installed.
# Output goes to /var/log/cloud-init-output.log on first run.
#
# Default-sized run (t3.medium, 4 GiB):
#   - Installs docker + minikube + kubectl + helm.
#   - Starts minikube with --memory=3000 --cpus=2 (leaves ~1 GiB for OS + Docker).
#   - Enables the ingress addon and a socat host→cluster TCP proxy on 80/443.
#   - Installs Kyverno → policies → kube-prometheus-stack → app, in that order
#     (Kyverno first so ClusterPolicies admit everything downstream).
#
# Smaller instances (t3.small / t3.micro) skip kube-prometheus-stack — the app
# keeps serving traffic but the obs stack does not schedule. See
# RUNBOOK.md § Observability fallback for the demo-locally alternative.

set -euo pipefail

REPO_OWNER="borailci"
REPO_NAME="insider-one-devops"
REPO_ROOT="/home/ec2-user/${REPO_NAME}"
CHART_DIR="${REPO_ROOT}/charts/app"
POLICIES_CHART_DIR="${REPO_ROOT}/charts/policies"
RELEASE_NAME="app"
NAMESPACE="default"
MONITORING_NAMESPACE="monitoring"
KYVERNO_NAMESPACE="kyverno"
HELM_VERSION="v3.16.2"
MINIKUBE_VERSION="latest"
KUBECTL_VERSION="v1.30.0"
KYVERNO_CHART_VERSION="3.2.6"

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
sudo -u ec2-user git clone --depth=1 "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "${REPO_ROOT}" || true

# Derive image tag from the cloned commit. Kyverno's disallow-latest-tag policy
# rejects :latest, so we pin to the short SHA. CI publishes this tag on every
# push to main.
APP_IMAGE_TAG=$(sudo -iu ec2-user bash -c "cd ${REPO_ROOT} && git rev-parse --short HEAD")
log "app image tag = ${APP_IMAGE_TAG}"

# --- 4. Start minikube -----------------------------------------------------

log "starting minikube"
# --memory tuned for t3.medium (4 GiB total, ~3.5 GiB usable after kernel + docker).
# Drop to --memory=1500 for t3.small (obs stack will be tight) or skip kps on t3.micro.
# See RUNBOOK § Observability fallback for the smaller-instance demo path.
sudo -iu ec2-user bash -c "minikube start \
    --driver=docker \
    --memory=3000 \
    --cpus=2 \
    --kubernetes-version=${KUBECTL_VERSION}"

log "enabling ingress addon"
sudo -iu ec2-user bash -c "minikube addons enable ingress"

log "waiting for ingress-nginx controller Ready"
sudo -iu ec2-user bash -c "kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s" || log "WARN: ingress controller not Ready in 180s"

# Route host 80/443 → minikube IP via socat (userspace, no kernel forwarding).
# iptables DNAT to docker-bridge IP is fragile on AL2023; socat avoids ip_forward,
# FORWARD chain, nftables/iptables-services conflicts, and reboot persistence quirks.
MINIKUBE_IP=$(sudo -iu ec2-user bash -c "minikube ip")
log "installing socat for host→minikube TCP proxy (target ${MINIKUBE_IP})"
dnf -y install socat

cat >/etc/systemd/system/minikube-ingress-80.service <<EOF
[Unit]
Description=socat proxy 0.0.0.0:80 -> minikube ingress
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:80,reuseaddr,fork TCP:${MINIKUBE_IP}:80
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/minikube-ingress-443.service <<EOF
[Unit]
Description=socat proxy 0.0.0.0:443 -> minikube ingress
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:443,reuseaddr,fork TCP:${MINIKUBE_IP}:443
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minikube-ingress-80.service
systemctl enable --now minikube-ingress-443.service

# --- 5. Kyverno + cluster policies ----------------------------------------
# Kyverno must be Ready before any other workload is admitted, so that the
# cluster policies (no :latest, must run as non-root, must have resources)
# apply to everything from the start. System namespaces are excluded in the
# policies chart so the platform itself isn't blocked.

log "adding kyverno helm repo"
sudo -iu ec2-user bash -c "helm repo add kyverno https://kyverno.github.io/kyverno/ && helm repo update"

log "installing kyverno chart version ${KYVERNO_CHART_VERSION}"
sudo -iu ec2-user bash -c "helm upgrade --install kyverno kyverno/kyverno \
    --namespace ${KYVERNO_NAMESPACE} \
    --create-namespace \
    --version ${KYVERNO_CHART_VERSION} \
    --wait --timeout 5m" \
  || log "WARN: kyverno install did not finish in 5m"

log "waiting for kyverno admission webhook"
sudo -iu ec2-user bash -c "kubectl -n ${KYVERNO_NAMESPACE} wait --for=condition=available deploy --all --timeout=120s" \
  || log "WARN: not all kyverno deployments became Available"

log "applying cluster policies"
sudo -iu ec2-user bash -c "helm upgrade --install policies ${POLICIES_CHART_DIR} \
    --namespace ${KYVERNO_NAMESPACE} \
    --wait --timeout 2m" \
  || log "WARN: policies chart install failed"

# --- 6. Observability (must precede app) ----------------------------------
# Order matters: the app chart's prod values reference ServiceMonitor and
# PrometheusRule CRDs that the kube-prometheus-stack install provides. If we
# install the app first, helm fails with "no matches for kind PrometheusRule".

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

log "waiting for ServiceMonitor + PrometheusRule CRDs to be Established"
for crd in servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com; do
  sudo -iu ec2-user bash -c "kubectl wait --for=condition=Established crd/${crd} --timeout=120s" \
    || log "WARN: CRD ${crd} not Established — app install may fail on prod values"
done

# --- 7. App chart ----------------------------------------------------------

log "installing app via helm (image tag ${APP_IMAGE_TAG})"
sudo -iu ec2-user bash -c "helm upgrade --install ${RELEASE_NAME} ${CHART_DIR} \
    --namespace ${NAMESPACE} \
    --create-namespace \
    -f ${CHART_DIR}/values-prod.yaml \
    --set image.tag=${APP_IMAGE_TAG} \
    --wait --timeout 3m" || log "WARN: initial helm install failed; CI deploy job will retry"

log "verifying app reachable via socat proxy on localhost:80"
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/ping | grep -qE '^(200|404)$'; then
    log "ingress reachable on localhost:80"
    break
  fi
  sleep 5
done

touch /var/log/bootstrap-done
log "bootstrap complete"
