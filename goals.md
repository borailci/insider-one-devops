WHAT MATTERS · ÖNEMLI OLAN

Clarity

Automation

Awareness

Decisions

Simple structure,
readable code, a clear
README.

A small but working CI/
CD flow instead of
manual steps.

Basic care around
secrets, ports, IAM, and
image scanning.

A few sentences
explaining each tool
choice.

MISSION · GÖREV

01

THE MISSION

DAY 1

DAY 1

DAY 2

DAY 3

DAY 4

OUTPUT

OUTPUT

Tiny HTTP
service

Container

Kubernetes

CI/CD

Observability

Public URL

Docs

Node · Go ·
Python

Docker ·
multi-stage

Helm ·
minikube

Actions ·
OIDC · Trivy

Prom · Grafana
· Logs

EIP · ngrok
·
cloudflared

README ·
RUNBOOK ·
ADR

→

HEADS UP · DIKKAT

Minikube is a single-node Kubernetes environment — it runs comfortably on a laptop or on EC2. There's no need for a
production-grade cluster; a Deployment, Service, and Ingress will be enough.

STEP 0 · PICK YOUR TRACK

02

STEP 0 — PICK YOUR TRACK

Cloud or local?

TRACK B · LOCAL

Minikube on EC2

Minikube + tunnel

Running minikube on an AWS free-tier EC2
instance.

Running minikube locally, exposed through a public
tunnel.

Setting up a free-tier EC2 instance that fits minikube,
deploying the app on it, and exposing it through an
Elastic IP.

Setting up minikube on your own machine, deploying
the app, and exposing the NodePort or Ingress through
ngrok or cloudflared.

DAY 1 · FOUNDATION

DAY

01

·

FOUNDATION

App, container, repo

DELIVERABLE

1.1

Tiny HTTP service

1.2

→ pong, GET /healthz probe'lar için, GET /version
A small service in Node.js, Go, or Python works well as a
starting point. Three endpoints to think about: GET /ping
returning pong, GET /healthz for probes, GET /version
returning the build SHA.
core

node · go · python

env-driven config

1.3

Repo hygiene

1.4

conventional commits, PR template, CODEOWNERS
A public GitHub repo with README.md, .gitignore,
and .env.example is a solid baseline. Working with main
plus feature branches, conventional commits, a PR
template, CODEOWNERS, and branch protection are
small but meaningful touches.
core

readme

codeowners

Containerize

docker

multi-stage

non-root

Minimal test

One or two unit tests are enough. The choice of test
framework is entirely up to you. These tests will be wired
into CI on Day 3; for today, running them locally is
enough.
core

unit test

pr-template

DAY 2 · KUBERNETES & HELM

DAY

02

·

KUBERNETES

&

HELM

Deploy with Helm

DELIVERABLE

2.1

Helm chart

2.2

Environments

Building your own Helm chart instead of raw manifests is
a nice step: Deployment, Service, Ingress, ConfigMap,
Secret. Starting from helm create and building on it is
perfectly fine.

values-dev.yaml and values-prod.yaml become
meaningful when the differences are clear: replica count,
resources, host, and so on. A short note in the README
about which value goes with which environment is
helpful too.

core

helm

ingress

core

2.3

Probes & resources

2.4

Her container için requests ve limits belirlemek de iyi
README'de yeterli.
Pointing the liveness and readiness probes (optionally a
startup probe too) at /healthz works nicely. Setting
requests and limits per container is a good habit as well;
a short note in the README on how the values were
chosen is enough.
core

2.5

probes

values-dev

values-prod

Rollout & rollback

rollout

rollback

limits

Bonus (opsiyonel)

If you'd like, adding an HPA (a simple CPU-based target), a NetworkPolicy (allowing traffic only from the ingress controller), or
a PodDisruptionBudget is a nice touch. A short note in the README about why you picked it is plenty.
bonus

hpa

networkpolicy

pdb

Day-end checkpoint. helm upgrade --install app -f values-dev.yaml komutundan sonra pod'lar Running ve
After helm upgrade --install app -f values-dev.yaml, the pods are Running and the probes are Healthy. The same
command with values-prod.yaml produces different replica and host values.

DAY 3 · CI/CD & SUPPLY CHAIN

DAY

03

·

CI/CD

&

SUPPLY

CHAIN

SECURITY

Pipeline that protects
you

DELIVERABLE

3.1

CI pipeline

3.2

Secrets & auth

A nice GitHub Actions flow: lint, test, docker build, a
Trivy image scan (failing on CRITICAL or HIGH), and a
push to GHCR. Workflow files under .github/workflows/,
free tier is plenty for public repos.

For Track A, connecting to AWS via OIDC is a nice
approach; no need for long-lived access keys. Adding
gitleaks is a good extra. The goal: no real credentials
inside the repo.

core

3.3

actions

trivy

ghcr

Release hygiene

3.4

semver

core

changelog

gitleaks

Auto-deploy on merge

main'e merge sonrası minikube'a otomatik deploy iki
README'de güzel oluyor.
After merge to main, auto-deploying to minikube can go
two ways: kubectl set image from the pipeline, or
GitOps via ArgoCD/Flux. The choice and tradeoff fit
nicely in the README.
core

3.5

oidc

argocd · flux

gitops

Bonus (opsiyonel)

If you'd like, adding cosign image signing, a Syft SBOM, a multi-arch build (amd64 + arm64), or a simple release-please
automation is nice. All optional.
bonus

cosign

sbom

multi-arch

DAY 4 · OBSERVABILITY & DOCS

DAY

04

·

OBSERVABILITY,

IAC

&

DOCUMENTATION

Make it operable

DELIVERABLE

4.1

Logs & metrics

4.2

varsayılan metrikle yetiyor.
Structured JSON logs from the app (timestamp, level,
msg, request_id) make a nice start. A /metrics endpoint
in Prometheus format with a few default counters is
enough.
core

json logs

/metrics

minikube üzerine kube-prometheus-stack Helm
dashboard (RPS, latency, hata oranı, pod restart gibi)
5%) yeterli.
Installing kube-prometheus-stack via Helm on minikube
works nicely. At least one Grafana dashboard (RPS,
latency, error rate, pod restarts) and at least one alert
rule (for example rate(errors) > 5%) is enough.
core

4.3

Infrastructure as Code

Prometheus + Grafana

4.4

prometheus

grafana

alert

Architecture & docs

For Track A, defining the EC2, EIP, and security group
with Terraform or OpenTofu is nice (local state is fine).
For Track B, making the minikube setup and the needed
commands reproducible through a Makefile or a small
shell script serves the same purpose.

An architecture diagram in Excalidraw or draw.io (app,
container, Kubernetes, ingress, the Public URL, with an
observability overlay) works nicely. A RUNBOOK.md
(restart steps, where to find logs, how to roll back), a
SECURITY.md, and about three ADRs round out the rest.

core

terraform · opentofu

makefile

core

diagram

runbook

adr

The Grafana dashboard opens and at least one alert is defined. The RUNBOOK reads like a short incident response guide (a single page is
enough) and the ADRs answer questions like "why Helm", "why this base image", "why this tunnel".

BONUS TRACK · SADECE ZAMAN KALIRSA

-

OPTIONAL BONUS

Going further

-

Policy-as-Code

-

Supply chain

A cluster policy via Kyverno or OPA Gatekeeper: for example,
"no root containers" or "no :latest image tag".

Integrating cosign attestation and a Syft SBOM into CI;
attaching SLSA-style metadata to the image.

-

GitOps proper

An ArgoCD ApplicationSet for dev and prod environments,
with auto-sync and prune enabled.

-

Custom metric → alert → Slack

-

Chaos test

-

Custom domain + TLS

Adding a domain-specific counter to the app and wiring a flow
through Prometheus and Alertmanager to a Slack webhook.

Pointing a custom domain through Cloudflare or Route53 and
obtaining a Let's Encrypt certificate via cert-manager.

DELIVERABLES · TESLIMAT

03

DELIVERABLES

get pods, helm list, helm history ve rollout status ekran
görüntüleri.

A public repo, or a private one you invite us to.

Architecture diagram
rahatsa.
Excalidraw, draw.io, or a photo of a paper sketch —
whichever feels comfortable.

Screenshots of get pods, helm list, helm history, and rollout
status.

SUBMISSION FORMAT

Public URL. Repo private ise insider-one-devops ekibini davet etmek pratik bir yöntem.
A single email or Slack message works fine: the repo link, a short demo video or screenshot, and the Public URL if available. If
the repo is private, inviting the insider-one-devops team is a handy way to share it.

SAFETY NOTES · GÜVENLIK NOTLARI

04

SAFETY NOTES

A few things to watch out for

Leaking a credential or token through a public repo

When in doubt, asking is a good move. Pausing to think "would this be risky?" is already a healthy instinct. If you're unsure about
something, a short note in the README or a quick message to us works just as well.

TIPS & RESOURCES · HIZLI BAŞLANGIÇ

05

HELPFUL POINTERS

Tools we'd reach for

WHY

WHERE

minikube

minikube.sigs.k8s.io

Helm

helm.sh/docs

GitHub Actions

docs.github.com/actions

Trivy

aquasecurity.github.io/trivy

gitleaks

github.com/gitleaks/gitleaks

kubeprometheus-stack

prometheus-community.github.io

ArgoCD / Flux

argo-cd.readthedocs.io ·
fluxcd.io

Terraform /
OpenTofu

developer.hashicorp.com ·
opentofu.org

ngrok /
cloudflared

ngrok.com ·
developers.cloudflare.com

AWS EC2 free tier

aws.amazon.com/pm/ec2

WHEN IN DOUBT · ŞÜPHEYE DÜŞERSEN

If a tool is new to you, running a short tutorial and writing the choice and reasoning into an ADR note is a practical path. The
right answer is the one you can explain.
