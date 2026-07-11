#!/usr/bin/env bash
# lazy-down.sh — tear down environment(s) cleanly. The counterpart to lazy.sh.
#
# Deletes the k3d cluster AND removes its Terragrunt state (.tfstate/<env>) —
# BOTH, because deleting only the cluster leaves state that makes a later redeploy
# think Vault/DB are already provisioned (it then skips them on the fresh cluster
# and the app fails DB auth). See docs/RUNBOOK.md.
#
# Usage:
#   ./scripts/lazy-down.sh                 # dev
#   ./scripts/lazy-down.sh dev staging     # those envs
#   ./scripts/lazy-down.sh all             # dev+staging+prod + shared registry + all state
#
# (For a state-aware destroy that also de-registers cloud resources, use instead:
#   new terragrunt (>=0.73/1.x):
#     TF_VAR_vault_token=root terragrunt run --all --working-dir stages/<env> -- destroy -auto-approve
#   legacy terragrunt (<=0.67):
#     TF_VAR_vault_token=root terragrunt run-all destroy --terragrunt-working-dir stages/<env>
#  — slower, needs the cluster reachable; the fast path below is right for the sandbox.)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Real escape bytes (ANSI-C quoting) so colors render in printf arguments too,
# not just format strings.
C=$'\033[0;34m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; D=$'\033[0;90m'; N=$'\033[0m'
log(){  printf "${C}==>${N} %s\n" "$*"; }
ok(){   printf "${G}[ok]${N} %s\n" "$*"; }
warn(){ printf "${Y}[warn]${N} %s\n" "$*"; }
step(){ printf "${C}[%d/%d]${N} %s\n" "$1" "$2" "$3"; }

# Args: env names, plus -y/--yes to skip the confirmation (also LAZY_YES=1).
# Empty-array-safe for macOS bash 3.2 under set -u.
YES="${LAZY_YES:-0}"; RAW=()
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    *) RAW+=("$a") ;;
  esac
done
[ "${#RAW[@]}" -gt 0 ] || RAW=(dev)
FULL=0
if [ "${RAW[0]:-}" = "all" ]; then ENVS=(dev staging prod); FULL=1; else ENVS=("${RAW[@]}"); fi

# Destructive-action plan + approval: show exactly what will be deleted first.
down_banner() {
  printf "\n${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
  printf "  ${R}lazy-down.sh${N} — TEAR DOWN ${R}(destructive, irreversible)${N}\n"
  printf "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
  printf "  ${Y}Environments:${N} %s\n\n" "${ENVS[*]}"
  printf "  For each env this ${R}DELETES${N}:\n"
  printf "    ${R}•${N} the k3d cluster ${C}platform-<env>${N}  ${D}(all workloads, data, volumes)${N}\n"
  printf "    ${R}•${N} its Terragrunt state ${C}.tfstate/<env>${N}  ${D}(so a redeploy is clean)${N}\n"
  [ "$FULL" = 1 ] && printf "    ${R}•${N} the shared k3d registry ${R}+ ALL${N} ${C}.tfstate${N}  ${D}(full reset)${N}\n"
  printf "\n  ${D}Redeploy afterwards with ./scripts/lazy.sh <env>.${N}\n"
  printf "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
}
confirm() {
  if [ "$YES" = 1 ]; then ok "approved (-y) — tearing down"; return 0; fi
  if [ -t 0 ]; then
    printf "  ${Y}Delete the above?${N} [y/N] "; read -r ans
    case "${ans:-}" in y | Y | yes | YES) echo ;; *) warn "aborted — nothing deleted."; exit 0 ;; esac
  else
    warn "non-interactive shell — re-run with ${C}-y${N} (or LAZY_YES=1) to tear down."; exit 0
  fi
}

down_banner
confirm

# macOS/colima: k3d reaches Docker via DOCKER_HOST. lazy.sh exports this inside
# its own process; a standalone lazy-down.sh run does NOT inherit it, so k3d would
# hit the wrong/absent daemon and the delete would silently no-op — leaving the
# cluster running while we still clear state. Point at colima's socket (same
# detection as lazy.sh). Linux uses the default socket and skips this.
if [ "$(uname -s)" = "Darwin" ] && [ -z "${DOCKER_HOST:-}" ]; then
  sock="$(docker context inspect colima --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  [ -n "$sock" ] || sock="$(colima status 2>&1 | sed -n 's/.*docker socket: //p' | tr -d '[:space:]"' || true)"
  [ -n "$sock" ] && { export DOCKER_HOST="$sock"; ok "DOCKER_HOST -> $DOCKER_HOST"; }
fi

total=${#ENVS[@]}; n=0
for env in "${ENVS[@]}"; do
  case "$env" in dev|staging|prod) ;; *) warn "skipping unknown env '$env'"; continue ;; esac
  n=$((n+1)); step "$n" "$total" "tearing down '$env'"
  # Attempt the delete, then VERIFY the cluster is actually gone — never just
  # trust the exit code (which hid the macOS no-op before).
  k3d cluster delete "platform-$env" >/dev/null 2>&1 || true
  if k3d cluster list 2>/dev/null | grep -q "^platform-${env}[[:space:]]"; then
    warn "cluster platform-$env STILL PRESENT — delete failed. Docker/colima reachable? (DOCKER_HOST=${DOCKER_HOST:-unset})"
  else
    ok "cluster platform-$env deleted"
  fi
  rm -rf "$REPO_ROOT/.tfstate/$env" && ok "state .tfstate/$env cleared"
done

if [ "$FULL" = 1 ]; then
  log "full reset: shared registry + any residual state"
  k3d registry delete --all >/dev/null 2>&1 && ok "registries deleted" || true
  rm -rf "$REPO_ROOT/.tfstate" && ok ".tfstate cleared"
fi

ok "teardown complete — redeploy with ./scripts/lazy.sh"
