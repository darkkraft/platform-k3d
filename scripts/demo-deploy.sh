#!/usr/bin/env bash
# demo-deploy.sh — end-to-end PROOF of the CD path against a live cluster.
#
# Exercises the REAL GitOps deploy loop and shows the per-env difference:
#
#   dev / staging : bump the image tag in the env overlay → push to `main` in the
#                   in-cluster Forgejo → ArgoCD reconciles → Argo Rollouts
#                   blue-green AUTO-promotes once the green pods are Available
#                   (readiness = /readyz = DB reachable).
#
#   prod          : same push, but the prod Rollout has autoPromotionEnabled=false,
#                   so the new version health-checks in PREVIEW and PAUSES at the
#                   MANUAL gate (old version keeps serving) until a human promotes
#                   it (kubectl argo rollouts promote). That gate is prod's safety.
#
#   --break       : deploy a bogus tag; the new version never becomes Available,
#                   so it is never promoted and the OLD version keeps serving.
#
# "What is live" is read from the Rollout's ACTIVE selector (the ReplicaSet
# actually serving), so a PASS means traffic really moved — not just that git
# changed. Idempotent: records the starting git HEAD + overlay tag and restores
# them + re-pushes Forgejo on exit; safe to run repeatedly.
#
# Usage:  scripts/demo-deploy.sh [dev|staging|prod] [api-service|inventory-service] [--break]
# Requires: a running cluster, docker, kubectl, git, yq, curl; kubectl-argo-rollouts (prod promote).
set -euo pipefail

ENVX=dev; SVC=api-service; BREAK=0
for a in "$@"; do
  case "$a" in
    dev|staging|prod)              ENVX="$a" ;;
    api-service|inventory-service) SVC="$a" ;;
    --break)                       BREAK=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
CTX="k3d-platform-$ENVX"; NS="app"; FJ_NS="forgejo"
ROLLOUT="${SVC}-rollout"; OVERLAY="gitops/config/${SVC}/${ENVX}.yaml"
IS_PROD=0; [ "$ENVX" = "prod" ] && IS_PROD=1

C=$'\033[0;34m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; N=$'\033[0m'
say(){ printf "${C}==>${N} %s\n" "$*"; }
ok(){  printf "${G}[ok]${N} %s\n" "$*"; }
warn(){ printf "${Y}[warn]${N} %s\n" "$*"; }
die(){ printf "${R}[FAIL]${N} %s\n" "$*" >&2; exit 1; }

kubectl --context "$CTX" get ns "$NS" >/dev/null 2>&1 || die "cluster $CTX not reachable — bring it up first (scripts/lazy.sh $ENVX)"
[ -f "$OVERLAY" ] || die "overlay $OVERLAY not found"
case "$SVC" in
  api-service)       HOST_HDR="api.127.0.0.1.sslip.io" ;;
  inventory-service) HOST_HDR="inventory.127.0.0.1.sslip.io" ;;
esac

REG_PORT="$(docker port k3d-platform-registry 5000/tcp 2>/dev/null | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1)"; [ -n "$REG_PORT" ] || REG_PORT=5111
PUSH="localhost:${REG_PORT}/${SVC}"
HTTP_PORT="$(docker port "k3d-platform-${ENVX}-serverlb" 80/tcp 2>/dev/null | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1)"
[ -n "$HTTP_PORT" ] || die "could not read the loadbalancer http port"
URL="http://127.0.0.1:${HTTP_PORT}/healthz"

FJ_USER="$(kubectl --context "$CTX" -n "$FJ_NS" get secret forgejo-admin -o jsonpath='{.data.username}' | base64 -d)"
FJ_PASS="$(kubectl --context "$CTX" -n "$FJ_NS" get secret forgejo-admin -o jsonpath='{.data.password}' | base64 -d)"
PF_PID=""; LP=""; PROBE_PID=""
fj_open() {
  local log; log="$(mktemp)"
  kubectl --context "$CTX" -n "$FJ_NS" port-forward svc/forgejo-http :3000 >"$log" 2>&1 & PF_PID=$!
  for _ in $(seq 1 60); do
    LP="$(sed -n 's/.*127\.0\.0\.1:\([0-9]\{1,\}\).*/\1/p' "$log" | head -1)"
    [ -n "$LP" ] && curl -fsS "http://localhost:$LP/api/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
  [ -n "$LP" ] || { cat "$log" >&2; die "forgejo port-forward never became ready"; }
}
fj_push_main() { git -C "$REPO_ROOT" -c http.extraHeader= push -f "http://$FJ_USER:$FJ_PASS@localhost:$LP/example-org/platform-gitops.git" HEAD:refs/heads/main >/dev/null 2>&1; }
argocd_refresh() {
  for app in "$SVC" root; do
    kubectl --context "$CTX" -n argocd annotate applications.argoproj.io "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done
}

ORIG_HEAD="$(git rev-parse HEAD)"
ORIG_TAG="$(yq -r '.image.tag // ""' "$OVERLAY")"
cleanup() {
  say "cleanup: restoring repo + cluster to the starting state"
  git checkout -q -- "$OVERLAY" 2>/dev/null || true
  git reset -q --hard "$ORIG_HEAD" 2>/dev/null || true
  [ -n "$LP" ] && fj_push_main || true
  argocd_refresh
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null || true
  ok "restored (cluster reconciles back to '${ORIG_TAG:-<chart default>}')"
}
trap cleanup EXIT INT TERM

phase() { kubectl --context "$CTX" -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.phase}' 2>/dev/null; }
synced_tag() { kubectl --context "$CTX" -n "$NS" get deployment "$SVC" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://'; }
# Image tag of the ReplicaSet the ACTIVE service points at = what serves live traffic.
active_tag() {
  local h; h="$(kubectl --context "$CTX" -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.blueGreen.activeSelector}' 2>/dev/null)"
  [ -n "$h" ] || return 0
  kubectl --context "$CTX" -n "$NS" get rs -l "rollouts-pod-template-hash=$h,app.kubernetes.io/name=$SVC" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://'
}
wait_for() { local want="$1" fn="$2" t; t=$(( $(date +%s) + ${3:-300} )); while [ "$(date +%s)" -lt "$t" ]; do [ "$($fn)" = "$want" ] && return 0; sleep 5; done; return 1; }

say "env=$ENVX ($([ $IS_PROD = 1 ] && echo 'PROD: manual promotion gate' || echo 'auto-promote')) service=$SVC ingress=:$HTTP_PORT registry=:$REG_PORT mode=$([ $BREAK = 1 ] && echo BREAK || echo good)"
say "start: serving tag=$(active_tag)  overlay tag=${ORIG_TAG:-<chart default>}  phase=$(phase)"

# 1. new tag + build/push
if [ "$BREAK" = 1 ]; then
  NEW_TAG="v-does-not-exist-$RANDOM"
  warn "BREAK mode: deploying bogus tag '$NEW_TAG' (image intentionally absent)"
else
  NEW_TAG="demo-$(date +%Y%m%d-%H%M%S)"
  say "building $SVC:$NEW_TAG → $PUSH (shared k3d registry)"
  docker build -t "${PUSH}:${NEW_TAG}" "apps/${SVC}" >/dev/null 2>&1
  docker push "${PUSH}:${NEW_TAG}" >/dev/null 2>&1 || docker push "${PUSH}:${NEW_TAG}" >/dev/null
  ok "pushed ${PUSH}:${NEW_TAG}"
fi
OLD_SERVING="$(active_tag)"

# 2. availability probe (zero-downtime evidence)
HITS="$(mktemp)"
( while true; do curl -fsS -H "Host: $HOST_HDR" "$URL" >/dev/null 2>&1 || echo x >> "$HITS"; sleep 1; done ) & PROBE_PID=$!

# 3. deploy = bump the env overlay + push to main (Forgejo). All envs track main;
#    prod differs only in that its rollout pauses for a manual promote (step 4).
say "bumping $OVERLAY: image.tag → $NEW_TAG (the declarative deploy)"
yq -i ".image.tag = \"$NEW_TAG\"" "$OVERLAY"
git add "$OVERLAY"
git -c user.name=demo -c user.email=demo@local commit -q -m "deploy($ENVX): $SVC → $NEW_TAG (demo-deploy.sh)"
fj_open
fj_push_main
argocd_refresh
ok "pushed the deploy to Forgejo; ArgoCD is reconciling"

# 4. watch + assert
if [ "$BREAK" = 1 ]; then
  say "expecting the bad version to NEVER promote; old version keeps serving"
  wait_for "$NEW_TAG" synced_tag 180 || die "ArgoCD did not sync the bump onto the Deployment"
  sleep 60
  now="$(active_tag)"
  [ "$now" != "$NEW_TAG" ] || die "bad version was promoted to active — containment FAILED"
  curl -fsS -H "Host: $HOST_HDR" "$URL" >/dev/null 2>&1 || die "service DOWN during a bad deploy"
  ok "bad version never took traffic (active still '$now', phase=$(phase)) — contained"
elif [ "$IS_PROD" = 1 ]; then
  say "PROD: waiting for ArgoCD to sync, then the rollout to PAUSE at the manual gate"
  wait_for "$NEW_TAG" synced_tag 180 || die "ArgoCD did not sync $NEW_TAG onto the Deployment (synced=$(synced_tag))"
  wait_for "Paused" phase 240 || die "prod rollout did not reach the manual gate (phase=$(phase))"
  [ "$(active_tag)" = "$OLD_SERVING" ] || warn "active moved before promotion (active=$(active_tag))"
  curl -fsS -H "Host: $HOST_HDR" "$URL" >/dev/null 2>&1 || die "service DOWN while paused at the gate"
  ok "manual gate reached: $NEW_TAG health-checked in preview; OLD version ($OLD_SERVING) still serving"
  say "a human promotes it — kubectl argo rollouts promote $ROLLOUT"
  kubectl argo rollouts promote "$ROLLOUT" -n "$NS" --context "$CTX" >/dev/null
  wait_for "$NEW_TAG" active_tag 240 || die "promotion did not complete (active=$(active_tag) phase=$(phase))"
  ok "promoted: prod now serves $NEW_TAG"
else
  say "waiting for the Rollout to AUTO-promote $NEW_TAG (once green is Available/Ready)"
  wait_for "$NEW_TAG" synced_tag 180 || die "ArgoCD did not sync $NEW_TAG onto the Deployment (synced=$(synced_tag))"
  wait_for "$NEW_TAG" active_tag 240 || die "$NEW_TAG not promoted to active in time (active=$(active_tag) phase=$(phase))"
  ok "auto-promoted: live traffic now on $NEW_TAG"
fi

# 5. zero-downtime verdict
kill "$PROBE_PID" 2>/dev/null || true; PROBE_PID=""
FAILS="$(wc -l < "$HITS" | tr -d ' ')"; rm -f "$HITS"
[ "${FAILS:-0}" -le 2 ] || die "service saw $FAILS failed probes during the deploy — NOT zero-downtime"
ok "zero-downtime: ${FAILS} failed probe(s) (<=2 tolerated for scrape jitter)"

printf "\n${G}PASS${N} — %s\n" "$([ $BREAK = 1 ] && echo 'bad deploy contained (never promoted)' || { [ $IS_PROD = 1 ] && echo 'prod deployed via the manual promotion gate, zero downtime' || echo 'dev auto-deploy, zero downtime'; })"
