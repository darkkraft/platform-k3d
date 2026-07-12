# Runbook — install, bring up, access, tear down

The platform is built on Terragrunt and OpenTofu. `scripts/lazy.sh` is an optional
convenience wrapper that installs prereqs and runs Terragrunt for you. It does
nothing you can't do by hand; the manual path is below it.

## Prerequisites
- Docker (Docker Desktop or colima on macOS; Docker Engine on Linux)
- Tools pinned in `.tool-versions`: `opentofu terragrunt k3d kubectl helm rust kubeconform trivy gitleaks pre-commit yq jq`
  - With [mise](https://mise.jdx.dev) or asdf: `mise install` (or `asdf install`) installs them all.
  - Prod promotion (`kubectl argo rollouts promote`, and `scripts/demo-deploy.sh prod`) also needs the `kubectl-argo-rollouts` kubectl plugin (not in `.tool-versions`).
  - Or Homebrew: `brew install colima docker kubectl helm k3d opentofu terragrunt git jq`

## Lazy path (one command)
```bash
./scripts/lazy.sh              # dev — one k3d cluster, full platform
./scripts/lazy.sh --tiny dev   # dev, minus the heavy add-ons (fits ~8 GB)
./scripts/lazy.sh dev staging  # two clusters
./scripts/lazy.sh all          # dev + staging + prod (three clusters)
```
macOS: installs colima + tools via brew and starts colima automatically.
Linux: expects Docker running; installs k3d/terragrunt if missing.
Base host ports come from each env's `stages/<env>/env.hcl` (dev 80/443, staging
8080/8443, prod 9080/9443); if a base port is busy, `lazy.sh` picks the next free
one and prints the actual URLs (`scripts/endpoints.sh <env>` re-prints them).

## Resource requirements (read this before you run)

One full environment runs ~22 workloads (ArgoCD, Vault, ESO, CNPG, Kyverno's
4 controllers, kube-prometheus-stack, Loki, Alloy, trivy-operator, Forgejo plus a
DinD runner, the apps). Give the Docker VM headroom:

| Target | RAM | CPU | Notes |
|---|---|---|---|
| **full** (default) | **12 GB** | 6 | comfortable; `lazy.sh` starts colima at 6 CPU / 12 GB on macOS |
| **tiny** (`--tiny`) | **~8 GB** | 4 | skips Loki, Alloy, blackbox, trivy-operator — keeps ArgoCD, Vault/ESO, CNPG, Kyverno, Prometheus/Grafana, the apps, portal |
| three clusters (`all`) | 24 GB+ | 8+ | prefer separate hosts; `lazy.sh` caps prod to 1 agent on a shared host |

The 8 GB in the original brief fits the `--tiny` profile, not the full stack.
The trade-off with `--tiny`: the Loki/Grafana logs panel and the blackbox
probe/trivy dashboards are absent, while Prometheus RED metrics, alerts, and the
security posture controls all remain. Nothing is removed from any environment's
definition; it is a render-time skip driven by `PROFILE`/`--tiny`.

Verified on macOS/colima: a full `terragrunt run-all apply` on an Apple/colima
host (cluster → bootstrap → services, 3 units, ~11 min, all succeeded). The CI
runner image builds for the host arch (BuildKit `TARGETARCH`), so it works on both
Apple Silicon and Intel/Linux.

## Manual path — deploy by hand (no lazy.sh)
`lazy.sh` only (1) installs prereqs and (2) runs Terragrunt in the right order.
To do it yourself:

```bash
export TF_VAR_vault_token=root     # dev-mode Vault root token (never commit; prod uses k8s auth)

# ── whole environment at once — cluster → bootstrap → services, dependency-ordered ──
# new terragrunt CLI (>= 0.73 / 1.x):
terragrunt run --all --working-dir stages/dev -- apply
# legacy terragrunt CLI (<= 0.72):
terragrunt run-all apply --terragrunt-working-dir stages/dev

# ── or layer by layer (same order; each reads the previous layer's outputs) ──
#   legacy CLI shown; on the new CLI use `terragrunt apply --working-dir <dir>`
terragrunt apply --terragrunt-working-dir stages/dev/cluster     # 1. k3d cluster + registry + build/push images
terragrunt apply --terragrunt-working-dir stages/dev/bootstrap   # 2. ArgoCD + Forgejo + seed repo + wait for Vault
terragrunt apply --terragrunt-working-dir stages/dev/services    # 3. Vault KV + ESO token + reconcile CNPG roles

# ── override the loadbalancer ports for a run (if the env.hcl bases are busy) ──
K3D_HTTP_PORT=8081 K3D_HTTPS_PORT=8444 terragrunt run-all apply --terragrunt-working-dir stages/dev

# ── drop to raw OpenTofu for a single layer (terragrunt just wraps tofu) ──
cd stages/dev/cluster && terragrunt init && tofu plan     # inspect a layer's plan
```

Swap `dev` → `staging` / `prod` for the other environments. Each env is its own
k3d cluster (distinct host ports), so all three can coexist on one machine.
After `apply`, ArgoCD reconciles everything else from Git; watch with
`kubectl --context k3d-platform-<env> -n argocd get applications -w`.

## Changing code & shipping it (the deploy lifecycle)

`terragrunt apply` above builds the platform. Day-to-day you don't re-apply
Terraform; you change code/config in git and ArgoCD reconciles. The flow, and how
it differs per environment:

```
  you edit …
  ├─ app code (apps/**)                      ├─ platform config (gitops/**, charts/**)
  │                                          │
  ▼                                          ▼
  git push  ─►  Forgejo (in-cluster git)  ─►  CI: Forgejo Actions
  │                                            lint · test · scan · docker build
  │                                            push image → k3d registry
  ▼
  bump image.tag in gitops/config/<svc>/<env>.yaml
  (by hand, or the manual `image-bump` workflow → opens it as a PR)
  │
  ▼  merge to main  (dev: low-friction  ·  staging/prod: reviewed)
  │
  ▼
  ArgoCD sees git change ─► syncs ─► Argo Rollouts blue-green:
        dev / staging → auto-promote once the new pods are Ready
        prod          → new version waits in PREVIEW; a human promotes it
  ▼
  new version live — zero downtime.   Rollback = revert the PR (git is the truth).
```

- dev / staging track `main` and auto-promote a merged bump.
- prod also tracks `main`, but its rollout sets `autoPromotionEnabled: false`:
  a merged bump syncs the manifests, the new version health-checks in preview,
  and a human promotes it via `kubectl argo rollouts promote api-service-rollout -n app`.

**See it end-to-end (against a live cluster):**
```bash
scripts/demo-deploy.sh dev            # build→push→bump→auto-promote, asserts zero downtime
scripts/demo-deploy.sh dev --break    # bad image never promotes; old version keeps serving
scripts/demo-deploy.sh prod           # release + manual promotion gate
```
It records and restores the starting state on exit (safe to re-run).

## Environments at a glance

One host, three independent k3d clusters (bring up only what you need):

```
Docker host
├─ k3d-platform-dev      :80/:443     1 srv + 1 agent   tracks main     Kyverno Audit    auto-promote
├─ k3d-platform-staging  :8080/:8443  1 srv + 1 agent   tracks main     Kyverno Enforce  auto-promote
└─ k3d-platform-prod     :9080/:9443  1 srv + 2 agents  tracks main     Kyverno Enforce  MANUAL promotion gate + PDB + anti-affinity
```

Everything else is identical (same modules, same charts); the differences are
config-only (per-env `env.hcl` + `gitops/config/<app>/<env>.yaml` overlays), where
the per-env replicas/storage/promotion settings live.

## Running the tests

The same checks run locally and remotely (the gate, in Forgejo Actions on pushes
touching `apps/**` or the infra paths, under `.forgejo/workflows/`). One command
reproduces the whole CI gate locally:

```bash
scripts/test.sh            # FULL suite — every check ci-apps + ci-infra run, in order,
                           #   with a pass/fail/skip summary (exits non-zero on any fail).
                           #   Needs docker + network for the image build, trivy, dep scan.
scripts/test.sh --quick    # fast inner loop: correctness tests + lint/format only
                           #   (skips the docker/network scans: image+trivy, dep scan,
                           #    gitleaks, trivy config). Good for a tight edit→test cycle.
scripts/test.sh --install  # bootstrap the PINNED toolchain first (mise/.tool-versions +
                           #   dep scan + helm-unittest, at CI versions), then run.
                           #   Use on a fresh machine; combines with --quick.
```

A missing tool is reported as **SKIP** (not a silent pass), so an incomplete run is
visible; run `scripts/test.sh --install` (or `mise install`) and re-run for the full
gate. When `mise` is present its pinned versions are put on `PATH` automatically, so
results match CI regardless of what else is installed.

Alternatives — the same checks as git hooks, or run piecemeal:

```bash
pre-commit run -a                                  # the checks wired as commit hooks
                                                   #   (tests + lint + gitleaks + shellcheck;
                                                   #    no image/vuln scans — test.sh adds those)
# …or individually:
cd apps/api-service && cargo test                  # + apps/inventory-service (unit — no DB)
helm unittest charts/microservice gitops/bootstrap # chart logic (rollout/hpa/overlays/tiny)
for m in terraform/modules/*/tests; do d=$(dirname "$m"); (cd "$d" && tofu init -backend=false >/dev/null && tofu test); done
helm lint charts/microservice gitops/config/*      # + `helm template … | kubeconform` (see ci-infra)
shellcheck -x --severity=warning scripts/*.sh
tofu fmt -check -recursive terraform/ && terragrunt hclfmt --check --working-dir stages
```

Where each runs: `cargo test`/`clippy`/`trivy`/`gitleaks` → `ci-apps`;
`tofu fmt/validate/tflint/tofu test`, `terragrunt hclfmt`, `helm lint/unittest/kubeconform`,
`trivy config`, `shellcheck` → `ci-infra`.

## Forgejo vs GitHub (what the GitOps source actually is)

Forgejo is a self-hosted git server, the same shape as GitHub/GitLab: it hosts
repos, speaks the git protocol, serves a REST API, does pull requests, and runs CI
(Forgejo Actions, with GitHub-Actions-compatible workflow syntax). The difference is
*where it lives*:

```
Typical GitHub-based GitOps:            This sandbox (in-cluster Forgejo):
  repo on github.com (external)           repo in Forgejo, running as a pod IN the cluster
  ArgoCD needs a GitHub App or PAT        ArgoCD uses an in-cluster URL + generated creds
    to read a PRIVATE repo                  (nothing external to mint, store, or rotate)
  Actions runners in GitHub cloud         Forgejo Actions runner = a pod in the cluster
```

Why Forgejo here: the sandbox stays fully self-contained, with no external accounts,
no GitHub App/PAT baked into the cluster to sync a private repo, and nothing to leak.
The workflows use standard GitHub-Actions syntax, so they'd run unchanged on GitHub.
To use real GitHub instead, set `local_git.enabled = false` and point
`gitops.repo_url` at your GitHub repo; ArgoCD then reconciles from GitHub and the
in-cluster Forgejo isn't deployed. Nothing else changes.

## Access (per env; context = `k3d-<prefix>-<env>`, e.g. `k3d-platform-dev`)

No port-forwards needed. Every UI has a Traefik Ingress on a `*.127.0.0.1.sslip.io`
host (public wildcard DNS → 127.0.0.1). One command prints every URL and
credential, reading the live loadbalancer ports and the generated secrets:

```bash
scripts/endpoints.sh dev      # or staging / prod
```

Or start at the portal, a single dashboard that auto-discovers every
annotated service (ArgoCD, Forgejo, Vault, Grafana, Prometheus, Alertmanager,
the apps) with live cluster/Grafana/Prometheus widgets:

```
http://home.127.0.0.1.sslip.io[:port]
```

`lazy.sh` prints the full endpoint table at the end of every bring-up. Ports are
the dev defaults `:80/:443` unless the host already uses them, in which case
`lazy.sh` shifts up and `endpoints.sh` reports the real ones. Passwords are all
generated / Vault-backed (never in git); `endpoints.sh` fetches them live and
hides them for prod.

## Remote access (connect from another machine)
Each cluster's API is on `0.0.0.0:<api_port>` (dev 6445 / staging 6446 / prod 6447).
For clean TLS from a remote host, add that host's IP to the API cert on create:
```bash
K3D_TLS_SAN=192.168.1.50 terragrunt run-all apply --terragrunt-working-dir stages/dev
```
Then copy the kubeconfig, point the server at `https://<this-host-ip>:6445`.

## Tear down
Use the teardown script. It deletes the cluster *and* clears its state (both,
so a later redeploy doesn't reuse stale state and skip Vault/DB provisioning,
which would cause an app DB-auth failure):
```bash
./scripts/lazy-down.sh              # dev
./scripts/lazy-down.sh dev staging  # those envs
./scripts/lazy-down.sh all          # all envs + shared registry + all state
```
Manual equivalents:
```bash
# clean, state-aware (needs the cluster reachable):
TF_VAR_vault_token=root terragrunt run-all destroy --terragrunt-working-dir stages/dev
# fast (must do BOTH — cluster + state):
k3d cluster delete platform-dev && rm -rf .tfstate/dev
# full reset:
k3d cluster delete --all && k3d registry delete --all && rm -rf .tfstate
```

## Notes
- ArgoCD ServerSideDiff is on, so operator/apiserver-defaulted fields (CNPG
  Cluster, Kyverno CRDs) diff clean; apps report Synced without brittle
  per-field ignore lists.
- `lazy.sh` auto-picks the first free host ports per env (so multiple clusters
  never collide) and caps prod to 1 agent on a shared host (design is 2).
- Images are built + pushed to a k3d registry (`k3d-platform-registry:5111`) with a
  real `dev` tag (never `:latest`, so Kyverno's disallow-latest passes).

---

## Observability

Full monitoring stack, all via ArgoCD (sync-wave 3): kube-prometheus-stack
(Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics), Loki
(logs), Alloy (ships pod logs → Loki), blackbox-exporter (synthetic probes), and
an in-repo `monitoring-config` chart (PrometheusRules, Probes, dashboards,
datasources, Grafana-admin ExternalSecret).

**Method — RED + USE.** The services expose `http_requests_total{method,route,code}`
and `http_request_duration_seconds{method,route}` (RED), scraped via the chart's
ServiceMonitor and rendered by the "platform · Service RED" dashboard. Resource
signals (USE) come from node-exporter, kube-state-metrics, and the CNPG PodMonitor
(`cnpg_*`). App instrumentation: `/metrics` (RED middleware, low-cardinality route
label), `/healthz` (liveness) + `/readyz` (DB-ping readiness that gates traffic),
and structured JSON logs → Alloy → Loki.

**Alerts** (symptom-based, low-noise; `gitops/config/monitoring-config`):

| Alert | Expr (summary) | Severity |
|---|---|---|
| ServiceDown | `up{job=~app} == 0` 2m | critical |
| HighErrorRate | 5xx ratio > 5% 5m | warning |
| HighLatencyP95 | p95 > 0.5s 10m | warning |
| BlackboxProbeFailed | `probe_success == 0` 5m | critical |
| PostgresDown | `cnpg_collector_up == 0` 2m | critical |
| PostgresConnectionsSaturation | backends/max_connections > 85% 5m | warning |
| PostgresPVCFillingUp | PVC usage > 80% 10m | warning |

Alertmanager uses a `null` receiver in the sandbox, with a `critical` route ready to
wire to Slack/PagerDuty from a Secret (shown, not enabled); `Watchdog` is the
dead-man's-switch. k3s embeds the control-plane components, so their default
ServiceMonitors/rules are disabled to avoid permanent false `…Down` alerts.

```bash
CTX=k3d-platform-dev
kubectl --context $CTX -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl --context $CTX -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   # dashboards + Explore→Loki
kubectl --context $CTX -n app scale deploy/api-service --replicas=0                            # fire ServiceDown after 2m
```

**Next:** long-term metrics storage (Thanos/Mimir + object store), Loki to S3/GCS,
real Alertmanager receivers, OpenTelemetry tracing, SLO-as-code burn-rate rules.

---

## Deploy safety & rollback

A deploy is the declarative image-tag bump above; delivery is an Argo Rollouts
**blue-green** (`charts/microservice/templates/rollout.yaml`). Green comes up beside
the live blue behind a preview Service and only takes traffic once healthy:

- `readinessProbe: /readyz` — green becomes *Available* only when its DB check
  passes, and promotion waits for Available, so a crash-looping or DB-less image is
  never promoted (traffic stays on blue → zero downtime).
- `progressDeadlineSeconds: 120` — a stuck rollout fails rather than hangs, so
  ArgoCD selfHeal can reconcile a revert on its own.
- `scaleDownDelaySeconds` — keeps blue briefly after promotion for an instant abort.
- prod: `autoPromotionEnabled: false` — green health-checks in preview and a human
  promotes it (`kubectl argo rollouts promote`).

**Rollback** = `git revert` the bump commit (declarative, auditable). Break-glass,
outside git: `argocd app history <app>` / `argocd app rollback <app> <rev>`, or
`kubectl argo rollouts abort <name>` to fall straight back to blue.
`scripts/demo-deploy.sh <env>` drives the loop live; `--break` deploys a bad image
and proves it never promotes while the old version keeps serving.

**Next:** a metric-based `prePromotionAnalysis` (Prometheus 5xx/p95 over a bake
window) to catch a *Ready-but-erroring* version that readiness alone can't.

---

## Troubleshooting

- **`k3d` not found** → install via the k3d install script, or `brew install k3d`.
- **Ingress host ports already in use** → another env's cluster is up; bring it down
  (`k3d cluster delete platform-dev`) or use the other env's ports.
- **Apps `CrashLoopBackOff` / `readyz` 503 early** → expected until the ESO
  ExternalSecret + CNPG role land (eventual consistency across sync waves); they
  recover automatically.
- **`services` layer can't reach Vault** → Vault (wave 0) must be Ready first;
  `bootstrap` waits for it, but if you run `services` standalone, wait for the Vault
  pod (`kubectl -n vault get pod`).
- **Vault pod restarted → secrets stop refreshing** → dev-mode Vault is in-memory,
  so a restart wipes KV. Existing k8s Secrets survive (ESO `deletionPolicy: Retain`)
  so running pods keep working, but re-run the services layer to repopulate:
  `TF_VAR_vault_token=root terragrunt apply --terragrunt-working-dir stages/<env>/services`
  (idempotent). Production Vault (Raft + PVC + auto-unseal) persists across restarts.
- **Images not found in-cluster** → the cluster layer builds + pushes them
  (`terraform/cluster/images.tf`, docker provider → k3d registry); re-apply the
  cluster layer after a code change, or rely on CI-published images.
