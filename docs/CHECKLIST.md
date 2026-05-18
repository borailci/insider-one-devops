# Demo Checklist — commands used in the live session

Step-by-step commands captured against the live stack (EIP `13.63.26.120`, instance `i-0fb7f03fe17ff7758`, region `eu-north-1`). Reproducible by anyone with the deploy IAM role.

Set once per shell:

```bash
export AWS_REGION=eu-north-1
export INSTANCE_ID=i-0fb7f03fe17ff7758
export EIP=13.63.26.120
```

---

## 0. Bring stack up (cold start)

```bash
cd terraform
terraform init
terraform apply -auto-approve
# Wait ~5–10 min for cloud-init. Marker:
aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["ls -la /var/log/bootstrap-done 2>&1"]' \
  --query 'Command.CommandId' --output text
```

Verify outputs:

```bash
terraform output            # public_url, ec2_instance_id, github_deploy_role_arn
```

---

## 1. Verify endpoints (screenshot #01)

```bash
for ep in ping healthz version metrics; do
  echo "$ curl -i http://$EIP/$ep"
  curl -sS -i --max-time 5 "http://$EIP/$ep"
  echo
done
```

Expected: 200 on all four. `/version` returns `{"sha":"<short>","build_time":"..."}`.

---

## 2. SSM helpers

Run-Command wrapper (one-shot, returns stdout):

```bash
ssmrun() {
  local cmd="$1"
  local id
  id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"$cmd\"]" \
        --query 'Command.CommandId' --output text)
  sleep 4
  until aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$id" --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null | grep -qE 'Success|Failed|Cancelled|TimedOut'; do sleep 2; done
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$id" --instance-id "$INSTANCE_ID" \
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output text
}
```

Shorthand for kubectl/helm as ec2-user:

```bash
ssmkubectl() { ssmrun "sudo -iu ec2-user kubectl $*"; }
ssmhelm()    { ssmrun "sudo -iu ec2-user helm $*"; }
```

---

## 3. Cluster status (screenshots #02, #03, #05)

```bash
ssmkubectl get pods -A          # #02 — app, monitoring, kyverno, ingress all Running
ssmhelm    list -A              # #03 — app, kps, kyverno, policies all deployed
ssmkubectl rollout history deployment/app-app   # #05
ssmkubectl get hpa app-app
```

---

## 4. Chart tests (screenshot #04)

```bash
ssmkubectl delete pod -l app.kubernetes.io/component=test -n default --ignore-not-found
ssmhelm test app --logs         # both test pods Phase: Succeeded
```

Expected output ends with `Checking /ping ... All endpoints OK.` and `/version => {...}`.

---

## 5. Grafana login (screenshots #06, #07)

5a. Start kubectl port-forward on EC2 (binds 0.0.0.0:3000):

```bash
ssmrun 'pkill -f "kubectl.*port-forward.*grafana" || true; nohup sudo -iu ec2-user kubectl -n monitoring port-forward --address 0.0.0.0 svc/kps-grafana 3000:80 > /tmp/pf-grafana.log 2>&1 &'
```

5b. SSM port-forward EC2:3000 → laptop:3000:

```bash
aws ssm start-session --region "$AWS_REGION" --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

5c. Browser → `http://localhost:3000` → `admin` / `<password>`.

Reset password if unknown:

```bash
NEW_PW=$(openssl rand -base64 24); echo "GRAFANA_ADMIN: $NEW_PW"
ssmrun "POD=\$(sudo -iu ec2-user kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}'); sudo -iu ec2-user kubectl -n monitoring exec \$POD -c grafana -- grafana cli admin reset-admin-password '$NEW_PW'"
```

Read original Helm-generated password (if never reset):

```bash
ssmrun "sudo -iu ec2-user kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo"
```

---

## 6. Kyverno denial demo (screenshot #09)

```bash
ssmkubectl run nginx-bad --image=nginx:latest --restart=Never
```

Expected: `admission webhook "validate.kyverno.svc-fail" denied the request` listing three policy violations (latest tag, non-root, resources).

---

## 7. Cosign signature verify (screenshot #08)

```bash
# Pick a tag from GHCR
TOKEN=$(curl -s 'https://ghcr.io/token?scope=repository:borailci/insider-one-devops:pull' | jq -r .token)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://ghcr.io/v2/borailci/insider-one-devops/tags/list" | jq -r '.tags[]' | grep -E '^[a-f0-9]{7}$' | head -5

# Resolve the index digest for that tag
TAG=<short-sha>
DIGEST=$(curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/borailci/insider-one-devops/manifests/$TAG" \
  | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r\n')

cosign verify "ghcr.io/borailci/insider-one-devops@$DIGEST" \
  --certificate-identity-regexp 'https://github.com/borailci/insider-one-devops/.github/workflows/ci.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Expected: three green checks ("cosign claims validated", "transparency log verified", "code-signing certificate verified").

SBOM (attestation):

```bash
cosign verify-attestation "ghcr.io/borailci/insider-one-devops@$DIGEST" \
  --type cyclonedx \
  --certificate-identity-regexp 'https://github.com/borailci/insider-one-devops/.github/workflows/ci.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com | jq '.payload | @base64d | fromjson | .predicate.Data | fromjson | .components | length'
```

---

## 8. CI run + GHCR + Security tab (screenshots #10, #11, #12)

```bash
# #10 — latest run all green
gh run list --limit 1 --repo borailci/insider-one-devops
gh run view <id> --repo borailci/insider-one-devops --web

# #11 — Trivy SARIF findings
open https://github.com/borailci/insider-one-devops/security/code-scanning

# #12 — GHCR package
open https://github.com/borailci/insider-one-devops/pkgs/container/insider-one-devops
```

---

## 9. Tear down (stop the meter)

```bash
cd terraform
terraform destroy -auto-approve
aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text   # terminated
aws ec2 describe-addresses --region "$AWS_REGION" \
  --query 'Addresses[?PublicIp==`13.63.26.120`]'                    # empty list
```

---

## 10. Troubleshooting one-liners

```bash
# Check bootstrap marker
ssmrun 'ls -la /var/log/bootstrap-done /var/log/cloud-init-output.log 2>&1'

# Tail cloud-init log
ssmrun 'sudo tail -200 /var/log/cloud-init-output.log'

# Restart app rollout
ssmkubectl rollout restart deployment/app-app -n default

# Watch pods
ssmkubectl get pods -A --watch    # (will exit after RunCommand timeout; use sparingly)

# Image actually running
ssmkubectl -n default get pod -l app.kubernetes.io/name=app -o jsonpath='{.items[0].spec.containers[0].image}'
```
