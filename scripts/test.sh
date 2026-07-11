#!/usr/bin/env bash
# test.sh — run the whole test / lint / scan suite locally, mirroring CI
# (.forgejo/workflows/ci-apps.yaml + ci-infra.yaml). One command to reproduce the
# gate before you push. Every check runs; results are collected and summarised at
# the end, and the script exits non-zero if any check FAILED.
#
# Usage:
#   scripts/test.sh            # full suite — same as CI (needs docker + network
#                              #   for the image build, trivy, dep scan, gitleaks)
#   scripts/test.sh --quick    # fast inner loop: correctness tests + lint/format
#                              #   only; skips docker/network steps
#   scripts/test.sh --install  # first install the PINNED toolchain (mise +
#                              #   helm-unittest), then run
#
# The toolchain is pinned in .tool-versions (installed with mise/asdf). `--install`
# bootstraps it — and the tool that isn't mise-managed (helm-unittest) at the
# same version CI uses. If mise is present, its pinned
# versions are put on PATH automatically so results match CI. A missing tool is
# reported as SKIP (never a silent pass); `--install` (or `mise install`) fixes it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT" || exit 1

# Version kept in lockstep with .forgejo/Dockerfile.ci (the one non-mise tool).
HELM_UNITTEST_VERSION=0.5.1

QUICK=0; DO_INSTALL=0
for a in "$@"; do
  case "$a" in
    -q|--quick)   QUICK=1 ;;
    -i|--install) DO_INSTALL=1 ;;
    -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a (try --quick / --install / --help)" >&2; exit 2 ;;
  esac
done

C=$'\033[0;34m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; B=$'\033[1m'; N=$'\033[0m'
PASS=(); FAIL=(); SKIP=()
SKIP_RC=77   # a check function returns this to signal "skipped" (tool absent)

have() { command -v "$1" >/dev/null 2>&1; }

# Prefer the pinned toolchain: put mise's .tool-versions binaries ahead of
# whatever is on the ambient PATH, so versions match CI.
use_pinned_path() {
  if have mise; then
    local bp; bp="$(mise bin-paths 2>/dev/null | paste -sd: -)"
    [ -n "$bp" ] && export PATH="$bp:$PATH"
  fi
}

install_toolchain() {
  printf "${C}${B}▶ installing the pinned toolchain${N}\n"
  # Bootstrap a version manager if neither is present. mise reads .tool-versions
  # and installs the EXACT pinned versions (matching CI) — so prefer it. On a Mac
  # / Linuxbrew box without mise, install it via Homebrew first.
  if ! have mise && ! have asdf; then
    if have brew; then
      echo "→ no mise/asdf found — installing mise via Homebrew"
      brew install mise || return 1
      use_pinned_path
    else
      echo "  ${R}no mise, asdf, or brew found.${N} Install a version manager, then re-run:" >&2
      echo "    macOS/Linux:  curl https://mise.run | sh   # then: exec \$SHELL" >&2
      echo "    Homebrew:     brew install mise" >&2
      echo "    docs:         https://mise.jdx.dev" >&2
      echo "  …or install the tools listed in .tool-versions manually." >&2
      return 1
    fi
  fi
  # A single tool's registry hiccup (e.g. a GitHub 404/rate-limit on one release)
  # must NOT abort the whole install — do the best-effort mise/asdf pass, then fill
  # any gaps from brew below. Tools still missing at the end just SKIP in the run.
  if have mise; then
    echo "→ mise install (.tool-versions)"
    mise trust >/dev/null 2>&1 || true
    mise install || echo "  ${Y}⚠ mise install had failures (above) — filling gaps via brew${N}"
  elif have asdf; then
    echo "→ asdf install (.tool-versions)"
    asdf install || echo "  ${Y}⚠ asdf install had failures (above) — filling gaps via brew${N}"
  fi
  use_pinned_path

  # Brew fallback for anything the version manager couldn't provide (formula names
  # differ for a couple). Best-effort per tool; brew installs latest, which the
  # checks tolerate (e.g. terragrunt version detection).
  if have brew; then
    local t f
    for t in tofu terragrunt helm rust kubeconform trivy tflint gitleaks shellcheck yq jq; do
      have "$t" && continue
      case "$t" in tofu) f=opentofu ;; kubectl) f=kubernetes-cli ;; *) f="$t" ;; esac
      echo "→ brew install $f (mise didn't provide $t)"; brew install "$f" || true
    done
    use_pinned_path
  fi
  if have helm && ! helm plugin list 2>/dev/null | grep -q '^unittest'; then
    echo "→ helm plugin install helm-unittest ${HELM_UNITTEST_VERSION}"
    helm plugin install https://github.com/helm-unittest/helm-unittest --version "${HELM_UNITTEST_VERSION}" || echo "  ${Y}⚠ helm-unittest plugin install failed — will SKIP${N}"
  fi

  # Honest status: report what's still missing rather than a blanket "ready".
  local want missing=()
  for want in cargo docker gitleaks tofu tflint terragrunt trivy helm kubeconform shellcheck; do
    have "$want" || missing+=("$want")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    printf "${G}✔ toolchain ready${N}\n"
  else
    printf "${Y}toolchain installed with gaps — still missing: %s${N}\n" "${missing[*]}"
    printf "  (those checks will SKIP; install manually and re-run for the full gate)\n"
  fi
  return 0
}

# needtools <tool...>: return SKIP_RC (with a message) if any tool is absent.
needtools() {
  local t miss=()
  for t in "$@"; do have "$t" || miss+=("$t"); done
  [ "${#miss[@]}" -eq 0 ] && return 0
  printf "  ${Y}skip — not installed: %s${N} (run: scripts/test.sh --install)\n" "${miss[*]}"
  return "$SKIP_RC"
}

# ver_ge <have> <min>: true if version <have> >= <min> (dotted numeric).
# Pure bash (no `sort -V` — stock macOS BSD sort lacks it).
ver_ge() {
  local -a a b; local i x y
  IFS=. read -ra a <<< "$1"
  IFS=. read -ra b <<< "$2"
  for i in 0 1 2; do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 0
}

# run <label> <fn>: run a check; classify by exit code (0 pass / 77 skip / else fail).
run() {
  local label="$1" fn="$2" rc
  printf "\n${C}${B}▶ %s${N}\n" "$label"
  "$fn"; rc=$?
  case "$rc" in
    0)          printf "${G}✔ PASS${N} %s\n" "$label"; PASS+=("$label") ;;
    "$SKIP_RC") printf "${Y}▷ SKIP${N} %s\n" "$label"; SKIP+=("$label") ;;
    *)          printf "${R}✘ FAIL${N} %s\n" "$label"; FAIL+=("$label") ;;
  esac
}

APPS=(api-service inventory-service)

# ---- apps (ci-apps.yaml) ----
c_lint()    { needtools cargo || return $?; local s; for s in "${APPS[@]}"; do (cd "apps/$s" && cargo clippy --all-targets -- -D warnings) || return 1; done; }
c_test()    { needtools cargo || return $?; local s; for s in "${APPS[@]}"; do (cd "apps/$s" && cargo test) || return 1; done; }
c_depscan() { needtools trivy || return $?; local s; for s in "${APPS[@]}"; do trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed "apps/$s" || return 1; done; }
c_images() {
  needtools docker trivy || return $?
  local s; for s in "${APPS[@]}"; do
    docker build -t "$s:localtest" "apps/$s" || return 1
    trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed "$s:localtest" || return 1
  done
}
c_gitleaks() { needtools gitleaks || return $?; gitleaks detect --source . --no-banner --redact; }

# ---- infra: terraform / terragrunt (ci-infra.yaml) ----
c_tofufmt()  { needtools tofu || return $?; tofu fmt -check -recursive terraform/; }
c_tofuval()  { needtools tofu || return $?; local d; for d in terraform/cluster terraform/bootstrap terraform/services; do
                 (cd "$d" && tofu init -backend=false -input=false >/dev/null && tofu validate) || return 1; done; }
c_tflint()   { needtools tflint || return $?; tflint --chdir=terraform --recursive; }
c_tofutest() { needtools tofu || return $?; local m d; for m in terraform/modules/*/tests; do d="$(dirname "$m")";
                 echo "== tofu test: $d =="; (cd "$d" && tofu init -backend=false -input=false >/dev/null && tofu test) || return 1; done; }
c_tghcl() {
  needtools terragrunt || return $?
  local ver; ver="$(terragrunt --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  # terragrunt >= 0.73 redesigned the CLI: `hcl fmt --check` + global `--working-dir`.
  # Older (the pinned 0.67.x) uses `hclfmt --terragrunt-check --terragrunt-working-dir`.
  if [ -n "$ver" ] && ver_ge "$ver" 0.73.0; then
    terragrunt --working-dir stages hcl fmt --check
  else
    terragrunt hclfmt --terragrunt-check --terragrunt-working-dir stages
  fi
}
c_trivycfg() { needtools trivy || return $?; trivy config --severity HIGH,CRITICAL --skip-dirs .archive --exit-code 0 .; }

# ---- infra: helm / gitops (ci-infra.yaml) ----
c_helmlint() { needtools helm || return $?; helm lint charts/microservice gitops/bootstrap \
                 gitops/config/cnpg-cluster gitops/config/secret-store \
                 gitops/config/monitoring-config gitops/config/network-policies \
                 gitops/config/kyverno-policies gitops/config/portal; }
c_kubeconform() {
  needtools helm kubeconform || return $?
  helm template ms charts/microservice \
    -f gitops/config/api-service/values.yaml -f gitops/config/api-service/dev.yaml \
    | kubeconform -strict -ignore-missing-schemas -summary || return 1
  local env; for env in dev staging prod; do
    echo "== bootstrap render: $env =="
    helm template root gitops/bootstrap --set environment="$env" \
      | kubeconform -strict -ignore-missing-schemas -summary || return 1
  done
  helm template root gitops/bootstrap --set environment=dev --set profile=tiny \
    | kubeconform -strict -ignore-missing-schemas -summary
}
c_helmunit() {
  needtools helm || return $?
  if ! helm plugin list 2>/dev/null | grep -q '^unittest'; then
    printf "  ${Y}skip — helm-unittest plugin not installed${N} (run: scripts/test.sh --install)\n"
    return "$SKIP_RC"
  fi
  helm unittest charts/microservice gitops/bootstrap
}

# ---- scripts ----
c_shellcheck() { needtools shellcheck || return $?; shellcheck -x --severity=warning scripts/*.sh; }

use_pinned_path
if [ "$DO_INSTALL" = 1 ]; then
  install_toolchain || { echo "toolchain install failed — see above" >&2; exit 1; }
fi

printf "\n${B}Running %s suite (mirrors CI: ci-apps + ci-infra)${N}\n" \
  "$([ "$QUICK" = 1 ] && echo 'QUICK' || echo 'FULL')"

# apps
run "clippy (apps)"                 c_lint
run "cargo test (apps)"             c_test
if [ "$QUICK" = 0 ]; then
  run "trivy fs (apps deps)"        c_depscan
  run "docker build + trivy image"  c_images
  run "gitleaks (repo secret scan)" c_gitleaks
fi
# terraform / terragrunt
run "tofu fmt -check"               c_tofufmt
run "tofu validate (3 roots)"       c_tofuval
run "tflint (recursive)"            c_tflint
run "tofu test (module contracts)"  c_tofutest
run "terragrunt hclfmt -check"      c_tghcl
[ "$QUICK" = 0 ] && run "trivy config (IaC scan)" c_trivycfg
# helm / gitops
run "helm lint"                     c_helmlint
run "kubeconform (rendered)"        c_kubeconform
run "helm unittest (chart logic)"   c_helmunit
# scripts
run "shellcheck (scripts)"          c_shellcheck

printf "\n${B}──────────────── summary ────────────────${N}\n"
printf "  ${G}pass %d${N}   ${R}fail %d${N}   ${Y}skip %d${N}\n" \
  "${#PASS[@]}" "${#FAIL[@]}" "${#SKIP[@]}"
if [ "${#SKIP[@]}" -gt 0 ]; then
  printf "${Y}skipped (missing tool/plugin — run \`scripts/test.sh --install\` for the full gate):${N}\n"
  printf '    ▷ %s\n' "${SKIP[@]}"
fi
if [ "${#FAIL[@]}" -gt 0 ]; then
  printf "${R}${B}failed:${N}\n"
  printf '    ✘ %s\n' "${FAIL[@]}"
  exit 1
fi
printf "${G}${B}all checks passed${N}\n"
