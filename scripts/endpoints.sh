#!/usr/bin/env bash
# Show every endpoint + credential for an environment, in one table.
# No port-forwards needed: every UI has a Traefik Ingress on a
# *.127.0.0.1.sslip.io hostname (public wildcard DNS -> 127.0.0.1), reachable
# through the k3d loadbalancer's mapped host ports.
#
# Usage: scripts/endpoints.sh [dev|staging|prod]   (default: dev)
set -euo pipefail

ENV="${1:-dev}"
case "$ENV" in dev | staging | prod) ;; *)
  echo "usage: $0 [dev|staging|prod]" >&2
  exit 1
  ;;
esac

CLUSTER="platform-$ENV"
CTX="k3d-$CLUSTER"
BASE="127.0.0.1.sslip.io"

# Actual host ports of this env's loadbalancer (lazy.sh may have shifted them
# off 80/443 if those were busy) — read live from Docker, never assumed.
lb_port() { docker port "k3d-$CLUSTER-serverlb" "$1/tcp" 2>/dev/null | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1; }
HTTP_PORT="$(lb_port 80)"
HTTPS_PORT="$(lb_port 443)"
[ -n "$HTTP_PORT" ] || {
  echo "cluster '$CLUSTER' is not running (scripts/lazy.sh $ENV)" >&2
  exit 1
}
P=""
[ "$HTTP_PORT" != "80" ] && P=":$HTTP_PORT"
PS=""
[ "$HTTPS_PORT" != "443" ] && PS=":$HTTPS_PORT"

secret() { kubectl --context "$CTX" -n "$1" get secret "$2" -o "jsonpath={.data['$3']}" 2>/dev/null | base64 -d 2>/dev/null || true; }
val() { [ -n "$1" ] && echo "$1" || echo "<not ready yet>"; }

# Access policy: dev/staging print passwords (sandbox convenience); prod never
# does — it prints the kubectl command to fetch them instead.
if [ "$ENV" = "prod" ]; then
  pw() { echo "(hidden — kubectl --context $CTX -n $2 get secret $3 -o jsonpath='{.data['\''$4'\'']}' | base64 -d)"; }
else
  pw() { val "$1"; }
fi

ARGO_PW="$(secret argocd argocd-initial-admin-secret password)"
GRAFANA_USER="$(secret monitoring grafana-admin admin-user)"
GRAFANA_PW="$(secret monitoring grafana-admin admin-password)"
FORGEJO_USER="$(secret forgejo forgejo-admin username)"
FORGEJO_PW="$(secret forgejo forgejo-admin password)"

C='\033[0;36m'
B='\033[1m'
D='\033[0;90m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'
row() { printf "  ${B}%-14s${N} ${C}%-45s${N} %s\n" "$1" "$2" "$3"; }
hr() { printf "${D}  ─── %s ───${N}\n" "$1"; }

echo
printf "${B}[%s]${N} endpoints — context ${C}%s${N} (http :%s / https :%s)\n\n" "$ENV" "$CTX" "$HTTP_PORT" "$HTTPS_PORT"
row "Portal" "http://home.$BASE$P" "all services, one page (auto-discovered)"
row "ArgoCD" "http://argocd.$BASE$P" "admin / $(pw "$ARGO_PW" argocd argocd-initial-admin-secret password)"
row "Grafana" "http://grafana.$BASE$P" "$(val "$GRAFANA_USER") / $(pw "$GRAFANA_PW" monitoring grafana-admin admin-password)"
row "Prometheus" "http://prometheus.$BASE$P" "(no auth)"
row "Alertmanager" "http://alertmanager.$BASE$P" "(no auth)"
row "Vault" "http://vault.$BASE$P" "token: root (dev mode)"
row "Forgejo" "http://forgejo.$BASE$P" "$(val "$FORGEJO_USER") / $(pw "$FORGEJO_PW" forgejo forgejo-admin password)"
row "api-service" "https://api.$BASE$PS" "(local-ca TLS; curl -k)  /orders /healthz /metrics"
row "inventory" "https://inventory.$BASE$PS" "(local-ca TLS; curl -k)  /products /healthz /metrics"
echo
# ── Cluster access (kubectl): local context + how to reach it remotely ──────
API_HOSTPORT="$(docker port "k3d-$CLUSTER-serverlb" 6443/tcp 2>/dev/null | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1)"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$HOST_IP" ] || HOST_IP="<this-host-ip>"
hr "cluster access (kubectl)"
printf "  context ${C}%s${N} is already in your kubeconfig:\n" "$CTX"
printf "    ${D}kubectl --context %s get pods -A${N}\n" "$CTX"
printf "    ${D}kubectl --context %s -n %s get pods${N}\n" "$CTX" "app"
printf "  remote (another machine): API server on ${C}https://%s:%s${N}\n" "$HOST_IP" "${API_HOSTPORT:-6445}"
printf "    ${D}clean TLS needs this host's IP in the cert SANs at create:${N}\n"
printf "    ${D}K3D_TLS_SAN=%s ./scripts/lazy.sh %s${N}   (details: docs/RUNBOOK.md)\n" "$HOST_IP" "$ENV"
echo

# ── Platform health: is everything up? (converges a few min after apply) ────
hr "platform health"
if kubectl --context "$CTX" -n argocd get applications >/dev/null 2>&1; then
  APP_STATES="$(kubectl --context "$CTX" -n argocd get applications --no-headers 2>/dev/null | awk '{print $NF}')"
  TOTAL="$(printf '%s\n' "$APP_STATES" | grep -c . || true)"
  HEALTHY="$(printf '%s\n' "$APP_STATES" | grep -c '^Healthy$' || true)"
  OTHER="$(printf '%s\n' "$APP_STATES" | grep -vc '^Healthy$' || true)"
  PODS_TOTAL="$(kubectl --context "$CTX" -n app get pods --no-headers 2>/dev/null | grep -cE 'api-service|inventory' || true)"
  PODS_READY="$(kubectl --context "$CTX" -n app get pods --no-headers 2>/dev/null | grep -E 'api-service|inventory' | grep -c '1/1' || true)"
  if [ "${HEALTHY:-0}" = "${TOTAL:-0}" ] && [ "${PODS_READY:-0}" = "${PODS_TOTAL:-0}" ] && [ "${TOTAL:-0}" -gt 0 ]; then
    printf "  ${G}✔ all %s ArgoCD apps Healthy · %s/%s app pods Ready${N}\n" "$TOTAL" "$PODS_READY" "$PODS_TOTAL"
  else
    printf "  ${Y}… converging:${N} ${G}%s${N}/%s apps Healthy (${Y}%s${N} not yet) · %s/%s app pods Ready\n" \
      "${HEALTHY:-0}" "${TOTAL:-0}" "${OTHER:-0}" "${PODS_READY:-0}" "${PODS_TOTAL:-0}"
    printf "  ${D}apps warm up as ArgoCD syncs waves and ESO+CNPG wire the DB creds — usually 2-4 min.${N}\n"
  fi
else
  printf "  ${Y}ArgoCD not reachable yet${N} — cluster may still be starting.\n"
fi
echo
printf "  ${D}watch live:${N}   kubectl --context %s -n argocd get applications -w\n" "$CTX"
printf "  ${D}re-check:${N}     scripts/endpoints.sh %s\n" "$ENV"
echo
