#!/usr/bin/env bash
# lazy.sh — one-command install + bring-up (CONVENIENCE ONLY).
#
# This is NOT the platform driver — the platform IS Terragrunt/OpenTofu. This
# script only (1) installs the prereqs for your OS and (2) runs
# `terragrunt run-all apply` for the environment(s) you name. Everything it does
# by hand, you can do yourself; see docs/RUNBOOK.md.
#
# Usage:
#   ./scripts/lazy.sh                 # dev (one cluster)
#   ./scripts/lazy.sh dev staging     # two clusters
#   ./scripts/lazy.sh all             # dev + staging + prod (three clusters)
#   ./scripts/lazy.sh --tiny dev      # dev, minus the heavy add-ons (fits ~8 GB)
#
# macOS: installs colima + docker + tools via Homebrew and starts colima.
# Linux: expects Docker running; installs k3d/terragrunt if missing.
#
# NOTE on `curl | bash`: the prereq installers below (Homebrew, k3d) use the
# vendors' official install scripts — this is a LOCAL developer-convenience
# bootstrap you opt into, and is deliberately distinct from the CI pipeline,
# which does NOT curl|sh anything (it bakes the exact pinned toolchain into a
# SHA-verified image — see .forgejo/Dockerfile.ci). Prefer `mise install` from
# .tool-versions to skip these entirely.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Args: env names, plus flags. -y/--yes skips the approval prompt (also
# LAZY_YES=1); --tiny selects the resource-light profile (also PROFILE=tiny).
# Collected without expanding an empty array (macOS bash 3.2 + set -u safe).
YES="${LAZY_YES:-0}"; ARGS=()
for a in "$@"; do
  case "$a" in
    -y|--yes)   YES=1 ;;
    --tiny)     export PROFILE=tiny ;;
    --full)     export PROFILE=full ;;
    *) ARGS+=("$a") ;;
  esac
done
if [ "${#ARGS[@]}" -gt 0 ]; then ENVS=("${ARGS[@]}"); else ENVS=(dev); fi
[ "${ENVS[0]:-}" = "all" ] && ENVS=(dev staging prod)
export TF_VAR_vault_token="${TF_VAR_vault_token:-root}"
# Profile flows to Terragrunt (stages/<env>/bootstrap reads PROFILE) → the ArgoCD
# root app → the bootstrap chart, which skips apps flagged heavy in "tiny".
export PROFILE="${PROFILE:-full}"

# Silence Homebrew's noisy hints/caveats/cleanup chatter — we surface our own.
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_PATH_SHADOW_CHECK=1
# Log file for verbose tool output (brew, colima, terragrunt) kept out of the UI.
LOG_DIR="${REPO_ROOT}/.lazy-logs"; mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/lazy-$(date +%Y%m%d-%H%M%S).log"

# Real escape bytes (ANSI-C quoting) so colors render whether they're placed in a
# printf format string OR passed as a %s argument — printf only interprets
# backslash escapes in the format, never in arguments.
C=$'\033[0;34m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; D=$'\033[0;90m'; N=$'\033[0m'
log(){  printf "${C}==>${N} %s\n" "$*"; }
ok(){   printf "${G}[ok]${N} %s\n" "$*"; }
warn(){ printf "${Y}[warn]${N} %s\n" "$*"; }
step(){ printf "${C}[%d/%d]${N} %s\n" "$1" "$2" "$3"; }

# Run a long command in the background with a Braille spinner on the line.
# Usage: run_spin "message" cmd args...
# Output goes to $LOG_FILE; the spinner replaces itself with [ok]/[fail] on done.
run_spin() {
  local msg="$1"; shift
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; local i=0
  printf "${C}==>${N} %s " "$msg"
  "$@" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${C}==>${N} %s ${D}%s${N}   " "$msg" "${spin:i%10:1}"
    i=$((i+1)); sleep 0.08
  done
  wait "$pid" && printf "\r${G}[ok]${N} %s\n" "$msg" \
       || { printf "\r${R}[fail]${N} %s\n" "$msg"; tail -20 "$LOG_FILE"; exit 1; }
}

# Filter raw terragrunt output into a live, COLOR-CODED progress stream: one
# line per meaningful terraform step, tagged with the layer ([1/3 cluster] etc.)
# and a symbol/colour by action — green ✓ complete, cyan + creating, yellow ~
# modifying, red ✗ destroying, dim · heartbeats and ▸ local-exec output.
# Written in awk (portable across GNU + BSD/macOS) with fflush() so lines appear
# the instant they happen; ANSI is stripped via a literal ESC byte passed with
# -v (no GNU-only `sed -u`). Heartbeats keep long Helm installs from looking
# frozen; the [id=…] suffix is trimmed for readability.
tg_progress() {
  awk -v esc=$'\033' -v n="$N" -v c="$C" -v g="$G" -v y="$Y" -v r="$R" -v d="$D" '
    function strip(s){ gsub(esc "\\[[0-9;]*m", "", s); return s }
    {
      s = strip($0)
      if (s !~ /\[(cluster|bootstrap|services)\] (tofu|OpenTofu): /) next
      layer = "?"
      if (match(s, /\[(cluster|bootstrap|services)\]/)) layer = substr(s, RSTART + 1, RLENGTH - 2)
      step = (layer == "cluster") ? "1/3 cluster" : (layer == "bootstrap") ? "2/3 bootstrap" : (layer == "services") ? "3/3 services" : layer
      msg = s; sub(/.*(tofu|OpenTofu): /, "", msg)
      sub(/ \[id=[^]]*\]$/, "", msg)   # trim noisy [id=…] suffix

      if (msg ~ /^Apply complete!/) { printf "  %s✔  [%s] %s%s\n", g, step, msg, n; fflush(); next }

      if      (msg ~ /Creation complete|Modifications complete/) { sym="✓"; col=g }
      else if (msg ~ /Destruction complete/)                     { sym="✓"; col=r }
      else if (msg ~ /Creating\.\.\./)                           { sym="+"; col=c }
      else if (msg ~ /Modifying\.\.\./)                          { sym="~"; col=y }
      else if (msg ~ /Destroying\.\.\./)                         { sym="✗"; col=r }
      else if (msg ~ /Still creating/)                           { sym="·"; col=d }
      else if (msg ~ /\(local-exec\):/)                          { sym="▸"; col=d }
      else                                                       { next }

      if (col == d)   # secondary (heartbeats, command output): whole line dim, no tag
        printf "     %s%s %s%s\n", d, sym, msg, n
      else            # primary action: coloured symbol, dim layer tag, plain message
        printf "  %s%s%s %s[%s]%s %s\n", col, sym, n, d, step, n, msg
      fflush()
    }
  '
}

TG_VERSION="v0.67.16"

# Plan/README shown before anything is installed or applied, so you know exactly
# what this will do before approving.
plan_banner() {
  printf "\n${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
  printf "  ${B:-}${C}lazy.sh${N} — bring up the platform platform on k3d (Terragrunt/OpenTofu)\n"
  printf "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
  printf "  ${Y}Environments:${N} %s   ${D}(each = its own k3d cluster)${N}\n" "${ENVS[*]}"
  if [ "${PROFILE:-full}" = "tiny" ]; then
    printf "  ${Y}Profile:${N} ${B:-}tiny${N}   ${D}(skips Loki/Alloy/blackbox/trivy-operator — fits ~8 GB)${N}\n\n"
  else
    printf "  ${Y}Profile:${N} full   ${D}(all components; use --tiny for a ~8 GB host)${N}\n\n"
  fi
  printf "  Terragrunt applies 3 layers per env, in order:\n"
  printf "    ${C}[1/3] cluster${N}   k3d cluster + shared registry + build/push app & CI images\n"
  printf "    ${C}[2/3] bootstrap${N} ArgoCD + in-cluster Forgejo (GitOps source), seed repo, wait for Vault\n"
  printf "    ${C}[3/3] services${N}  Vault KV + per-service DB creds + ESO token, reconcile CNPG roles\n"
  printf "  ${D}then ArgoCD reconciles the rest — operators, DB, apps, monitoring, policies.${N}\n\n"
  printf "  ${Y}This will${N} create Docker containers (k3d nodes + registry) and write local\n"
  printf "  state under .tfstate/. ${D}Idempotent — re-runs reuse existing clusters.${N}\n"
  printf "  ${D}Teardown:${N} ./scripts/lazy-down.sh <env>    ${D}Access after:${N} scripts/endpoints.sh <env>\n"
  printf "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
}

# Approval gate. -y/--yes (or LAZY_YES=1) skips it; on a non-interactive shell
# with no -y we stop rather than apply unattended.
confirm() {
  if [ "$YES" = 1 ]; then ok "approved (-y) — proceeding"; return 0; fi
  if [ -t 0 ]; then
    printf "  ${Y}Proceed?${N} [y/N] "; read -r ans
    case "${ans:-}" in y | Y | yes | YES) echo ;; *) warn "aborted — nothing changed."; exit 0 ;; esac
  else
    warn "non-interactive shell — re-run with ${C}-y${N} (or LAZY_YES=1) to apply."; exit 0
  fi
}

install_mac() {
  if ! command -v brew >/dev/null 2>&1; then
    run_spin "installing Homebrew" /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  local tools=(colima docker kubectl helm k3d opentofu terragrunt git jq)
  local total=${#tools[@]}; local n=0; local missing=0
  for f in "${tools[@]}"; do
    if brew list "$f" >/dev/null 2>&1; then n=$((n+1)); else missing=$((missing+1)); fi
  done
  if [ "$missing" = 0 ]; then
    ok "all $total Homebrew tools already installed"
  else
    log "installing $missing missing tool(s) via Homebrew"
    for f in "${tools[@]}"; do
      brew list "$f" >/dev/null 2>&1 && continue
      n=$((n+1)); run_spin "brew install $f ($(printf '%d/%d' "$n" "$total"))" brew install "$f"
    done
  fi
  if colima status >/dev/null 2>&1; then
    ok "colima already running"
  else
    run_spin "starting colima (6 CPU / 12 GB / 60 GB)" \
      colima start --cpu 6 --memory 12 --disk 60
  fi
  # colima's docker socket is NOT at the default /var/run/docker.sock, so the
  # tofu docker provider (and k3d) can't find the daemon unless DOCKER_HOST points
  # at colima's socket. Linux keeps the default socket, so this is macOS-only.
  # Respect an existing DOCKER_HOST (user override / custom context).
  if [ -z "${DOCKER_HOST:-}" ]; then
    local sock
    sock="$(docker context inspect colima --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    [ -n "$sock" ] || sock="$(colima status 2>&1 | sed -n 's/.*docker socket: //p' | tr -d '[:space:]"' || true)"
    if [ -n "$sock" ]; then
      export DOCKER_HOST="$sock"
      ok "DOCKER_HOST -> $DOCKER_HOST"
    else
      warn "could not determine colima docker socket — the docker provider may fail"
    fi
  fi
}

install_linux() {
  command -v docker >/dev/null 2>&1 || { warn "Docker not found — install Docker and re-run"; exit 1; }
  docker info >/dev/null 2>&1 || { warn "Docker daemon not usable (permissions?)"; exit 1; }
  if ! command -v k3d >/dev/null 2>&1; then
    run_spin "installing k3d" bash -c \
      'curl -sfL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash'
  fi
  for t in kubectl helm tofu; do
    command -v "$t" >/dev/null 2>&1 || { warn "$t not found — install it (e.g. via mise/.tool-versions) and re-run"; exit 1; }
  done
  if ! command -v terragrunt >/dev/null 2>&1; then
    run_spin "installing terragrunt ${TG_VERSION}" sudo bash -c \
      "curl -sSLo /usr/local/bin/terragrunt https://github.com/gruntwork-io/terragrunt/releases/download/${TG_VERSION}/terragrunt_linux_amd64 && chmod +x /usr/local/bin/terragrunt"
  fi
}

# Show the plan and get approval BEFORE installing prereqs or touching Docker.
plan_banner
confirm

case "$(uname -s)" in
  Darwin) log "macOS detected"; install_mac ;;
  Linux)  log "Linux detected"; install_linux ;;
  *) warn "unsupported OS: $(uname -s)"; exit 1 ;;
esac

# If mise/asdf is present it pins exact tool versions from .tool-versions.
if command -v mise >/dev/null 2>&1; then
  run_spin "mise install (.tool-versions)" mise install
fi
ok "prereqs ready  ${D}(log: $LOG_FILE)${N}"

port_busy() { (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$1 "; }
# First free port at or above $1 — avoids collisions between clusters brought up
# in the same run (each env's ports are chosen just before its apply, so already-
# bound ports from earlier envs are skipped).
free_port() { local p="$1"; while port_busy "$p"; do p=$((p+1)); done; echo "$p"; }

# Running >1 full cluster on ONE host is heavy: k3s can't reliably start a ~7th
# node, so cap prod to 1 agent on a shared host (its env.hcl design is 2 agents;
# use separate hosts for real multi-agent HA). Also give nodes longer to be Ready.
MULTI=$([ "${#ENVS[@]}" -gt 1 ] && echo 1 || echo 0)
export K3D_WAIT_TIMEOUT="${K3D_WAIT_TIMEOUT:-600s}"

# Terragrunt CLI generation differs by version, and brew (macOS) installs the
# latest while the Linux path pins an older release — so detect it. The
# redesigned CLI (v0.73+, incl. 1.x) uses `run --all -- <cmd>` with
# --working-dir/--non-interactive; older releases use `run-all <cmd> --terragrunt-*`.
# `--help` probes are UNRELIABLE — legacy 0.67 returns exit 0 for `run --help`
# (then forwards `run` to tofu, which fails), so we compare the version instead.
tg_ver="$(terragrunt --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
tg_major="${tg_ver%%.*}"; tg_minor="$(printf '%s' "$tg_ver" | cut -d. -f2)"
if [ "${tg_major:-0}" -ge 1 ] || { [ "${tg_major:-0}" -eq 0 ] && [ "${tg_minor:-0}" -ge 73 ]; }; then
  TG_CLI=new
else
  TG_CLI=legacy
fi
log "terragrunt ${tg_ver:-unknown} — using ${TG_CLI} CLI syntax"

for env in "${ENVS[@]}"; do
  case "$env" in dev|staging|prod) ;; *) warn "skipping unknown env '$env'"; continue ;; esac

  # Base host ports come from the env's own env.hcl (single source of truth —
  # the terragrunt cluster layer reads the same values), so lazy.sh never carries
  # its own copy. Then pick the first free port at/above the base so multiple
  # clusters never collide.
  ENV_HCL="$REPO_ROOT/stages/$env/env.hcl"
  BH="$(grep -oE 'http_port[[:space:]]*=[[:space:]]*[0-9]+' "$ENV_HCL" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  BS="$(grep -oE 'https_port[[:space:]]*=[[:space:]]*[0-9]+' "$ENV_HCL" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  [ -n "$BH" ] && [ -n "$BS" ] || { warn "$env: could not read http/https_port from $ENV_HCL"; continue; }
  HP="$(free_port "$BH")"; HSP="$(free_port "$BS")"
  [ "$HP" != "$BH" ] || [ "$HSP" != "$BS" ] && warn "$env: ports busy -> using $HP/$HSP"

  AGENTS_OVERRIDE=""
  if [ "$MULTI" = 1 ] && [ "$env" = "prod" ]; then
    AGENTS_OVERRIDE="1"; warn "prod on a shared host -> 1 agent (design is 2; use separate hosts for HA)"
  fi

  log "bringing up '$env': cluster -> bootstrap -> services"
  # Build the apply invocation for the detected CLI generation (see TG_CLI above).
  if [ "$TG_CLI" = new ]; then
    tg_args=(run --all --non-interactive --working-dir "$REPO_ROOT/stages/$env" -- apply -auto-approve)
  else
    tg_args=(run-all apply -auto-approve --terragrunt-non-interactive --terragrunt-working-dir "$REPO_ROOT/stages/$env")
  fi
  # Only export K3D_AGENTS when overriding (empty would break tonumber()).
  # Stream a live, human-readable progress line for every meaningful terraform
  # step — newline-terminated (NOT an in-place spinner), so you actually SEE the
  # apply working on a TTY, through a pipe, and in CI/agent capture alike. Full
  # untouched output is still tee'd to $LOG_FILE. pipefail + `if` so a terragrunt
  # failure is caught (not masked by the tee/awk exit codes) without set -e
  # aborting before we can show the log tail.
  if env K3D_HTTP_PORT="$HP" K3D_HTTPS_PORT="$HSP" \
       ${AGENTS_OVERRIDE:+K3D_AGENTS="$AGENTS_OVERRIDE"} \
       terragrunt "${tg_args[@]}" 2>&1 | tee -a "$LOG_FILE" | tg_progress; then
    ok "'$env' applied — ArgoCD is reconciling the rest"
  else
    printf "${R}[fail]${N} '%s' apply failed (see %s)\n" "$env" "$LOG_FILE"
    tail -30 "$LOG_FILE"; exit 1
  fi
done

echo
ok "Done. Every UI is on a *.127.0.0.1.sslip.io hostname via Traefik — no port-forwards:"
for env in "${ENVS[@]}"; do
  "$REPO_ROOT/scripts/endpoints.sh" "$env"
done
