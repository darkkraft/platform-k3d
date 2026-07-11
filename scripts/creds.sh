#!/usr/bin/env bash
# creds.sh — print every username/password for an environment, fetched LIVE from
# the cluster. Nothing is hardcoded: values come from the k8s Secrets that back
# each app. Several of those Secrets are materialised by External Secrets
# Operator from Vault (platform/monitoring, platform/db/*), so this is the effective
# "fetch from Vault" — without needing a Vault token or tunnel.
#
# Usage: scripts/creds.sh [dev|staging|prod]   (default: dev)
set -euo pipefail

ENV="${1:-dev}"
case "$ENV" in dev | staging | prod) ;; *)
  echo "usage: $0 [dev|staging|prod]" >&2
  exit 1
  ;;
esac
CTX="k3d-platform-$ENV"

kubectl --context "$CTX" get ns >/dev/null 2>&1 || {
  echo "cluster '$CTX' not reachable — is it up? (scripts/lazy.sh $ENV)" >&2
  exit 1
}

# base64-decode a key out of a Secret; empty string if the Secret isn't there yet.
g() { kubectl --context "$CTX" -n "$1" get secret "$2" -o "jsonpath={.data['$3']}" 2>/dev/null | base64 -d 2>/dev/null || true; }
v() { [ -n "$1" ] && printf '%s' "$1" || printf '<not ready yet>'; }

C='\033[0;36m'
B='\033[1m'
D='\033[0;90m'
N='\033[0m'
row() { printf "  ${B}%-16s${N} ${C}%-16s${N} %s\n" "$1" "$2" "$3"; }

echo
printf "${B}[%s] credentials${N} — context ${C}%s${N}\n\n" "$ENV" "$CTX"
printf "  ${D}%-16s %-16s %s${N}\n" "APP" "USER" "PASSWORD / TOKEN"
row "ArgoCD"         "admin"                                  "$(v "$(g argocd argocd-initial-admin-secret password)")"
row "Grafana"        "$(v "$(g monitoring grafana-admin admin-user)")" "$(v "$(g monitoring grafana-admin admin-password)")"
row "Forgejo"        "$(v "$(g forgejo forgejo-admin username)")"      "$(v "$(g forgejo forgejo-admin password)")"
row "Vault"          "-"                                      "token: root  (dev mode)"
row "api-service DB" "$(v "$(g app api-service-db username)")"       "$(v "$(g app api-service-db password)")"
row "inventory DB"   "$(v "$(g app inventory-service-db username)")" "$(v "$(g app inventory-service-db password)")"
echo
printf "  ${D}Grafana + DB creds originate in Vault (platform/monitoring, platform/db/*) and are\n"
printf "  materialised into these Secrets by External Secrets Operator. ArgoCD's initial\n"
printf "  admin secret and Forgejo's admin are generated at install (not in Vault).${N}\n"
echo
