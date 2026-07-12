# Architecture diagrams

Rendered natively on GitHub/Forgejo (Mermaid). Five views: provisioning (IaC),
CI/CD (with per-environment differences), observability, security, and the
request/data path. Operations detail lives in [RUNBOOK.md](RUNBOOK.md).

---

## 1. Provisioning — IaC → GitOps (Terraform + Terragrunt + ArgoCD)

Terraform provisions the cluster and installs ArgoCD; ArgoCD deploys everything
else from git. Three composed layers, wired by Terragrunt `dependency` rather than
`terraform_remote_state`, over five reusable modules.

```mermaid
flowchart TB
  subgraph stage["Terragrunt stage — one per env (dev / staging / prod)"]
    direction TB
    cl["terraform/cluster<br/><i>k3d cluster + shared registry<br/>build & push app/CI images</i>"]
    bo["terraform/bootstrap<br/><i>app ns + PSA, Forgejo (seeded),<br/>ArgoCD + root app, wait-for-Vault</i>"]
    sv["terraform/services<br/><i>Vault KV + per-service creds<br/>+ scoped ESO token</i>"]
    cl -->|"outputs: kube_context, cluster_id"| bo
    bo -->|"outputs: vault_ns, app_ns"| sv
  end

  mods["modules/<br/>k3d-cluster · registry-images · argocd · forgejo · vault-config"]
  mods -.reused by.-> stage

  bo --> root(["ArgoCD root Application<br/>(app-of-apps)"])
  root --> w0["wave 0 — operators/CRDs<br/>ESO · CNPG-op · Vault · Kyverno · argo-rollouts<br/>cert-manager · prometheus-CRDs · forgejo-runner"]
  root --> w1["wave 1 — cluster resources<br/>secret-store (ESO CRs) · cnpg-cluster · network-policies · cert-manager-issuers"]
  root --> w2["wave 2 — workloads + policy<br/>api-service · inventory-service · kyverno-policies"]
  root --> w3["wave 3 — observability<br/>kube-prometheus-stack · loki · alloy · blackbox · trivy-operator · monitoring-config"]
  root --> w4["wave 4 — portal (gethomepage)"]
  w0 --> w1 --> w2 --> w3 --> w4
```

The cluster module is swappable: replace `k3d-cluster` with an `eks`/`gke`
module exposing the same outputs and bootstrap/services are unchanged.

---

## 2. CI/CD — build, publish, deploy (per environment)

Change → git → CI builds/scans/publishes the image → a tag bump on `main` (by hand,
or via the manual `image-bump` PR workflow) → ArgoCD → Argo Rollouts blue-green. CI
never `kubectl apply`s; ArgoCD is the only thing that touches the cluster.

```mermaid
flowchart LR
  dev["developer"] -->|"push apps/**"| fj[("Forgejo<br/>(in-cluster git)")]
  fj --> ci["Forgejo Actions · ci-apps<br/>clippy · cargo test<br/>trivy fs · docker build · trivy · gitleaks"]
  ci -->|"push image :&lt;sha&gt;"| reg[("k3d registry")]
  ci -.->|"then, manually"| bump["tag bump in overlay<br/>by hand, or the manual<br/>image-bump PR workflow"]
  bump -->|"merge to main = deploy"| fj
  fj --> argo["ArgoCD reconciles"]
  argo --> ro{"Argo Rollouts<br/>blue-green"}
  ro -->|"green Available (readiness)"| prom["promotion"]
  prom -->|"dev / staging:<br/>AUTO-promote"| liveA["new version live<br/>(zero downtime)"]
  prom -->|"prod:<br/>PAUSE → human promotes"| liveB["new version live<br/>(zero downtime)"]

  infra["push terraform/** gitops/** charts/**"] --> ciinf["Forgejo Actions · ci-infra<br/>tofu fmt/validate/tflint · tofu test<br/>terragrunt hclfmt · helm lint/unittest<br/>kubeconform · trivy config · shellcheck"]
```

Per-environment differences (same code, config-only):

```mermaid
flowchart TB
  subgraph d["dev"]
    d1["ArgoCD tracks: main"]
    d2["promotion: auto"]
    d3["Kyverno: Audit"]
    d4["HPA 2→6, no PDB, 1 agent"]
  end
  subgraph s["staging"]
    s1["ArgoCD tracks: main"]
    s2["promotion: auto"]
    s3["Kyverno: Enforce"]
    s4["HPA 2→6, PDB (min 1), 1 agent"]
  end
  subgraph p["prod"]
    p1["ArgoCD tracks: main"]
    p2["promotion: MANUAL gate<br/>(autoPromotionEnabled=false)<br/>— new version waits in preview<br/>until a human promotes"]
    p3["Kyverno: Enforce"]
    p4["HPA 3→6, PDB (min 2), anti-affinity, 2 agents"]
  end
```

Prod's safety is the manual promotion gate: a merged change syncs the manifests,
but the new version health-checks in preview and only takes traffic when a human
runs `kubectl argo rollouts promote`. `scripts/demo-deploy.sh <env>`
drives the whole loop live; `--break` proves a bad image never promotes.

---

## 3. Observability (RED + USE → Prometheus/Loki → Grafana/Alertmanager)

```mermaid
flowchart LR
  apps["api / inventory<br/>/metrics (RED) · /healthz · /readyz<br/>structured JSON logs"]
  apps -->|"ServiceMonitor scrape"| prom["Prometheus"]
  apps -->|"stdout"| alloy["Alloy (DaemonSet)"] -->|"push"| loki["Loki"]
  node["node-exporter<br/>kube-state-metrics"] --> prom
  cnpg["CNPG PodMonitor (cnpg_*)"] --> prom
  bb["blackbox synthetic probes"] --> prom
  trivy["trivy-operator (vuln metrics)"] --> prom
  prom --> rules["PrometheusRules<br/>ServiceDown · HighErrorRate · HighLatencyP95<br/>Postgres* · BlackboxProbeFailed"]
  rules --> am["Alertmanager<br/>null + critical routes, Watchdog, inhibit"]
  prom --> graf["Grafana<br/>Service-RED + Security dashboards"]
  loki --> graf
```

Alertmanager routes to a `null` receiver in the sandbox; the `critical` route is
wired to Slack/PagerDuty from a Secret in prod (shown, not enabled).

---

## 4. Security — defense in depth

```mermaid
flowchart TB
  client["client"] -->|"HTTP/TLS"| tr["Traefik ingress<br/>cert-manager TLS"]
  tr --> adm

  subgraph adm["Admission (every workload in app)"]
    psa["Pod Security Admission: restricted"]
    kyv["Kyverno: no :latest · probes+resources required<br/>runAsNonRoot · readOnlyRootFS · drop ALL caps"]
  end

  adm --> net
  subgraph net["Network (zero-trust)"]
    ndeny["default-deny ingress+egress (app ns)"]
    vdeny["default-deny ingress (vault ns) — ESO + Traefik only"]
  end

  net --> pod["app pod<br/>distroless cc-nonroot base<br/>no SA token, sanitized errors"]
  pod -->|"TLS, least-priv role"| db[("CNPG Postgres<br/>per-service role, owns 1 DB")]

  subgraph sec["Secrets — no plaintext anywhere"]
    tf["TF random_password"] --> vault["Vault KV"] --> eso["External Secrets"] --> k8s["k8s Secret"] --> pod
    k8s --> db
  end

  subgraph sup["Supply chain"]
    cigate["CI gates: trivy fs · trivy image · gitleaks"]
    top["trivy-operator: continuous runtime scan"]
  end
  cigate -.->|"only scanned images ship"| pod
```

Scope is honest: default-deny + PSA + Kyverno cover the app namespace (and the
vault namespace for network); other platform namespaces run upstream charts and
are left open in the sandbox. Roadmap: cosign/verifyImages, Falco, DefectDojo,
cluster-wide default-deny.

---

## 5. Request & secret path (runtime)

```mermaid
sequenceDiagram
  participant U as client
  participant T as Traefik
  participant A as api-service
  participant DB as CNPG Postgres
  participant E as ESO
  participant V as Vault
  Note over E,V: at bootstrap — ESO reads creds, materialises k8s Secret
  E->>V: read platform/db/api-service (scoped token)
  V-->>E: username/password
  E->>A: k8s Secret (envFrom DB_USER/DB_PASSWORD)
  E->>DB: same Secret sets the managed-role password (CNPG)
  U->>T: GET /orders
  T->>A: route (sslip.io host)
  A->>DB: SQL over TLS, least-priv role
  DB-->>A: rows
  A-->>U: JSON (sanitized errors)
```
