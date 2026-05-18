# RUNBOOK

Operational guide for `insider-one-devops`. Audience: the on-call operator (one person — yourself or a reviewer) reading this at 02:00 with no prior context. Every section is a "do this" checklist, not narrative.

Traceability: FR-31, AC-35. Covers restart, logs, rollback, EC2 access, alerts. Each section starts with the symptom that brings you here.

---

## 0. Quick reference

| What | Where |
|---|---|
| Public URL | `http://<EIP>` with `Host: app.insider-one.example` — get EIP from `terraform output public_ip` |
| EC2 instance | `terraform output ec2_instance_id` |
| AWS region | `eu-north-1` |
| Kubernetes namespace (app) | `default` |
| Kubernetes namespace (obs) | `monitoring` |
| Helm release (app) | `app` |
| Helm release (obs) | `kps` |
| GitHub Actions workflow | `.github/workflows/ci.yml` |
| Image registry | `ghcr.io/borailci/insider-one-devops` |
| Required GH secrets | `AWS_DEPLOY_ROLE_ARN`, `EC2_INSTANCE_ID` |

---

## 1. App is returning 5xx / not responding

**Symptom:** `curl http://<EIP>/ping` returns 5xx, times out, or `AppDown` alert fired.

```sh
# Get a shell on the EC2 host. Two paths — pick one.

# Path A — SSM Session Manager (no SSH key needed):
aws ssm start-session --target $(terraform -chdir=terraform output -raw ec2_instance_id)

# Path B — SSH (if you set ssh_public_key in tfvars):
ssh -i ~/.ssh/your_key ec2-user@$(terraform -chdir=terraform output -raw public_ip)
```

Then on the host:

```sh
# 1. Is minikube up?
minikube status            # expect all components Running

# 2. Are the pods up?
kubectl -n default get pods -l app.kubernetes.io/name=app -o wide
kubectl -n default describe pod -l app.kubernetes.io/name=app | tail -40

# 3. Is the Service reachable in-cluster?
kubectl -n default run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sS http://app-app/healthz

# 4. Is the ingress controller up?
kubectl -n ingress-nginx get pods
```

**Most common causes (in order):**

1. **Pod OOM-killed.** `kubectl -n default get pods` shows `OOMKilled`. → resize `resources.limits` in `values-prod.yaml` and `helm upgrade`. Expected on smaller-than-default instances if the obs stack is also scheduled — see [§ Observability fallback](#observability-fallback).
2. **Image pull failure.** `ImagePullBackOff`. → check `kubectl describe pod` for the GHCR error. If the package is private, ensure GHCR allows public read; otherwise create an `imagePullSecret`.
3. **Ingress controller crashed.** `kubectl -n ingress-nginx logs deployment/ingress-nginx-controller` will show why. Restart with `kubectl -n ingress-nginx rollout restart deployment/ingress-nginx-controller`.

---

## 2. Where are the logs?

App logs are stdout JSON:

```sh
kubectl -n default logs -l app.kubernetes.io/name=app --tail=200 -f
```

One line per HTTP request: `ts`, `level`, `msg`, `request_id`, `path`, `method`, `status`, `duration_ms`. Filter by request id:

```sh
kubectl -n default logs -l app.kubernetes.io/name=app --tail=10000 \
  | jq 'select(.request_id == "<id>")'
```

Cluster events (helpful for crash loops, eviction, OOM):

```sh
kubectl -n default get events --sort-by=.lastTimestamp | tail -30
```

EC2 cloud-init bootstrap output:

```sh
sudo tail -100 /var/log/cloud-init-output.log
```

---

## 3. Restart the app

```sh
# Rolling restart, same image:
kubectl -n default rollout restart deployment/app-app
kubectl -n default rollout status deployment/app-app --timeout=120s

# Restart minikube itself (last resort):
minikube stop && minikube start
```

---

## 4. Roll back a bad deploy

**Symptom:** new image is in `default/app` but `/ping` fails, `/healthz` flips, or pods are crash-looping.

```sh
# 1. See history (most recent first):
helm -n default history app

# REVISION  UPDATED       STATUS      CHART      APP VERSION  DESCRIPTION
# 3         <now>         deployed    app-0.1.0  0.1.0        Upgrade complete
# 2         <30 min ago>  superseded  app-0.1.0  0.1.0        Upgrade complete
# 1         <yesterday>   superseded  app-0.1.0  0.1.0        Install complete

# 2. Roll back to the last known good revision:
helm -n default rollback app 2
helm -n default rollout status deployment/app-app --timeout=120s

# 3. Confirm:
curl -sS -H 'Host: app.insider-one.example' http://<EIP>/version
```

Rollback target SLA: previous image serving within 60 s (EC-9).

---

## 5. Force a redeploy from CI

```sh
# Re-run the latest workflow from CLI:
gh run rerun --failed   # only failed jobs
gh workflow run ci.yml  # blank slate

# Or push an empty commit:
git commit --allow-empty -m "chore: force redeploy" && git push
```

---

## 6. EC2 access

| Action | Command |
|---|---|
| Shell via SSM (no key) | `aws ssm start-session --target <id>` |
| Shell via SSH | `ssh ec2-user@<public_ip>` |
| Get instance status | `aws ec2 describe-instances --instance-ids <id> --query 'Reservations[].Instances[].State.Name'` |
| Stop instance (preserves EIP attachment) | `aws ec2 stop-instances --instance-ids <id>` — **note: stopped instance with attached EIP still costs ~$3.60/mo** |
| Start instance | `aws ec2 start-instances --instance-ids <id>` |
| Destroy everything | `terraform -chdir=terraform destroy` |

---

## 7. Observability — Prometheus / Grafana / alerts

```sh
# On the EC2 host (or wherever the kube-prometheus-stack release lives):

# Prometheus UI:
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090/alerts  — see firing / pending alerts
# → http://localhost:9090/targets — see scrape health

# Grafana UI:
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
# Default login: admin / prom-operator (override on install)
# → Dashboards → insider-one-devops — app

# Import the committed dashboard (only needed once):
kubectl -n monitoring create configmap app-dashboard \
  --from-file=dashboards/app.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label cm app-dashboard grafana_dashboard=1
```

Inspect a firing alert:

```sh
# Pull current alert state from Prometheus:
curl -sS http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {name: .labels.alertname, state, value, summary: .annotations.summary}'
```

---

## 8. Observability fallback (smaller-instance path)

The default `t3.medium` (4 GiB) comfortably fits minikube + ingress + kube-prometheus-stack + Kyverno + app. If you override `var.instance_type` to `t3.small` (2 GiB) or `t3.micro` (1 GiB) the obs stack will OOM or stay `Pending` with `Insufficient memory` — at the resource-trimmed bootstrap settings kube-prom-stack alone needs ~250 MiB requests, before you add Grafana sidecars and minikube overhead. Three recovery options:

```sh
# Verify cause:
kubectl -n monitoring get pods
kubectl -n monitoring describe pod <pending-pod> | grep -A2 Events

# Option 1 — accept and demo obs locally:
#   On your laptop, run the same chart against a local minikube where the
#   obs stack has room to schedule. The app on EC2 still serves the public URL.
helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
helm install app charts/app -f charts/app/values-prod.yaml --set serviceMonitor.enabled=true,prometheusRule.enabled=true

# Option 2 — upgrade EC2 back to the default size:
#   In terraform.tfvars: instance_type = "t3.medium"  (or t3.large for more headroom)
#   terraform apply  (resource will be replaced — ~5 min downtime, EIP keeps its address)

# Option 3 — uninstall the obs stack from EC2 to free memory:
helm -n monitoring uninstall kps
kubectl delete namespace monitoring
```

This trade-off is documented in [ADR-0001 § Status update](docs/adr/0001-track.md) — `t3.medium` is the live default; the smaller-instance path is preserved for free-tier reviewers.

---

## 9. Common errors

| Symptom | Cause | Fix |
|---|---|---|
| `connect: connection refused` on EIP | `ingress-nginx` not listening yet | `kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller` |
| `404 default backend` on EIP | Host header mismatch | use `-H 'Host: app.insider-one.example'` or whatever `values-prod.yaml` ingress host says |
| Pods stuck `ContainerCreating` | minikube docker daemon stuck | `minikube ssh -- sudo systemctl restart docker` then `kubectl -n default rollout restart deploy app` |
| CI deploy job: `command timed out` | SSM agent not registered yet | wait 60 s after EC2 first boot; check `aws ssm describe-instance-information` |
| CI deploy job: `AccessDenied: ssm:SendCommand` | OIDC role's instance ARN scope drifted | check `terraform/iam-oidc.tf` policy and `terraform apply` |
| `helm upgrade`: `cannot patch "app" with kind Deployment` | conflicting field manager | `kubectl -n default annotate deploy app meta.helm.sh/release-name=app meta.helm.sh/release-namespace=default --overwrite` then retry |

---

## 10. EC2 reboot (EC-7)

After an unexpected reboot:

```sh
# 1. Wait for cloud-init to finish (do not panic for ~3 min):
ssh ec2-user@<ip> 'cloud-init status --wait'

# 2. minikube should auto-start; if not:
ssh ec2-user@<ip> 'minikube start'

# 3. Restart the host→minikube socat proxies (enabled at boot by bootstrap):
ssh ec2-user@<ip> 'sudo systemctl restart minikube-proxy-80.service minikube-proxy-443.service'

# 4. Verify:
curl -sS http://<ip>/ping
```

The socat units are `systemctl enable`d by the bootstrap, so they come back automatically after reboot. Step 3 is only needed if `minikube` itself moved IP (rare) — `MINIKUBE_IP=$(minikube ip)` then re-edit the unit ExecStart.

---

## 11. Demoing the Kyverno policies

The cluster ships three cluster-wide Kyverno policies via the `charts/policies` chart: `require-non-root`, `disallow-latest-tag`, and `require-resources`. They run in **Enforce** mode and exclude system namespaces (`kube-system`, `kyverno`, `monitoring`, `ingress-nginx`, …) so the platform itself isn't blocked.

A reviewer can confirm policies are live and rejecting bad workloads in three commands:

```sh
# 1. Confirm the policies are installed and Ready.
kubectl get clusterpolicies
# Expected:
#   NAME                  READY   AGE
#   require-non-root      True    2m
#   disallow-latest-tag   True    2m
#   require-resources     True    2m

# 2. Try to create a pod that violates require-non-root + disallow-latest-tag
#    + require-resources, all at once. Should be REJECTED at admission.
kubectl run nginx-bad --image=nginx:latest --restart=Never
# Expected error message (truncated):
#   Error from server: admission webhook "validate.kyverno.svc-fail" denied
#   the request: policy disallow-latest-tag/image-tag-must-not-be-latest fail:
#   Container images must declare an explicit tag other than :latest.

# 3. Inspect the produced PolicyReports for the audit trail.
kubectl get policyreports -A
```

The case-study app itself passes because:

- its `securityContext` sets `runAsNonRoot: true` (`charts/app/values.yaml`),
- bootstrap installs the app with `image.tag=<short-sha>`, never `:latest`,
- `values.yaml` declares both CPU and memory `requests` + `limits`.

If a policy is unexpectedly blocking a legitimate workload, flip it to audit mode without uninstalling:

```sh
kubectl patch clusterpolicy disallow-latest-tag \
  --type=merge -p '{"spec":{"validationFailureAction":"Audit"}}'
```

To re-enforce: replace `Audit` with `Enforce`, or `helm upgrade --install policies charts/policies -n kyverno` to restore the values-file defaults.

Reference: [`charts/policies/`](./charts/policies/), [SECURITY.md §8 (STRIDE — Elevation of Privilege)](./SECURITY.md#8-stride-decomposition).
