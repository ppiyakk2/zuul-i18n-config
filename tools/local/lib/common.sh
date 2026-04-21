#!/usr/bin/env bash
# Shared helpers for tools/local/*.sh: env loading, arg parsing, safety guards,
# upper-constraints fetch. Source this from each wrapper.

set -euo pipefail

# Resolve the repo root from this file's location (tools/local/lib/).
# shellcheck disable=SC2155
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_LIB_DIR}/../../.." && pwd)"
TOOLS_LOCAL_DIR="${REPO_ROOT}/tools/local"
ENV_LOCAL_FILE="${TOOLS_LOCAL_DIR}/.env.local"

log() { printf '[local] %s\n' "$*" >&2; }
die() { printf '[local] ERROR: %s\n' "$*" >&2; exit 1; }

# On Mac, prepend GNU sed to PATH so common_translation_update.sh's
# `sed -i <no-suffix>` works (BSD sed requires an explicit suffix).
if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    _gsed_bin="$(brew --prefix gnu-sed 2>/dev/null)/libexec/gnubin"
    if [ -d "${_gsed_bin}" ]; then
        export PATH="${_gsed_bin}:${PATH}"
    fi
    unset _gsed_bin
fi

load_env_local() {
    if [ ! -f "${ENV_LOCAL_FILE}" ]; then
        die "missing ${ENV_LOCAL_FILE}. cp tools/local/.env.local.example tools/local/.env.local and fill in secrets."
    fi
    # shellcheck disable=SC1090
    set -a; source "${ENV_LOCAL_FILE}"; set +a
    : "${WEBLATE_URL:?WEBLATE_URL not set in .env.local}"
    : "${WEBLATE_TOKEN:?WEBLATE_TOKEN not set in .env.local}"
    : "${FORK_OWNER:?FORK_OWNER not set in .env.local}"
    : "${TARGETS_ROOT:?TARGETS_ROOT not set in .env.local}"
}

require_github_env() {
    : "${GITHUB_TOKEN:?GITHUB_TOKEN not set in .env.local (required for propose)}"
}

# Usage: parse_common_args "$@" — sets globals PROJECT, BRANCH, TARGET_DIR,
# JOBNAME, FORCE. Accepts either flags or positional args (project branch).
parse_common_args() {
    PROJECT=""
    BRANCH=""
    TARGET_DIR=""
    JOBNAME=""
    FORCE="0"
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --project)      PROJECT="$2"; shift 2 ;;
            --branch)       BRANCH="$2"; shift 2 ;;
            --target-dir)   TARGET_DIR="$2"; shift 2 ;;
            --jobname)      JOBNAME="$2"; shift 2 ;;
            --force)        FORCE="1"; shift ;;
            -h|--help)      print_usage; exit 0 ;;
            --)             shift; positional+=("$@"); break ;;
            -*)             die "unknown flag: $1" ;;
            *)              positional+=("$1"); shift ;;
        esac
    done
    # Fill from positional if flags missing.
    [ -z "${PROJECT}" ] && [ ${#positional[@]} -ge 1 ] && PROJECT="${positional[0]}"
    [ -z "${BRANCH}"  ] && [ ${#positional[@]} -ge 2 ] && BRANCH="${positional[1]}"

    : "${PROJECT:?--project (or positional 1) required}"
    BRANCH="${BRANCH:-master}"
    TARGET_DIR="${TARGET_DIR:-${TARGETS_ROOT}/${PROJECT}}"
}

# Default jobname derived from project + base jobname.
derive_jobname_upstream() {
    local base="upstream-translation-update"
    if [ -z "${JOBNAME}" ]; then
        if [ "${PROJECT}" = "horizon" ]; then
            JOBNAME="${base}-horizon"
        else
            JOBNAME="${base}"
        fi
    fi
}

# Refuse to run against production repos or production branches without --force.
# target dir must be a git repo whose origin points at the fork.
guard_target_dir() {
    [ -d "${TARGET_DIR}/.git" ] \
        || die "target dir is not a git repo: ${TARGET_DIR}"
    local origin_url
    origin_url="$(git -C "${TARGET_DIR}" remote get-url origin)"
    local expected_re="github.com[:/]${FORK_OWNER}/${PROJECT}(\\.git)?$"
    if ! [[ "${origin_url}" =~ ${expected_re} ]]; then
        die "origin of ${TARGET_DIR} is ${origin_url}, expected fork at github.com/${FORK_OWNER}/${PROJECT}. use --force to override."
    fi
    # Refuse to run on production branch unless branch suffix or --force is set.
    if [ "${BRANCH}" = "master" ] || [[ "${BRANCH}" =~ ^stable/ ]]; then
        if [ -z "${LOCAL_TEST_BRANCH_SUFFIX:-}" ] && [ "${FORCE}" != "1" ]; then
            die "branch '${BRANCH}' looks like a production branch. Set LOCAL_TEST_BRANCH_SUFFIX in .env.local or pass --force (or use a localtest/* branch)."
        fi
    fi
}

# Download upper-constraints.txt into the target project root.
# Needed for propose jobs and horizon upstream.
fetch_upper_constraints() {
    local branch="${1:-${BRANCH}}"
    local dest="${TARGET_DIR}/upper-constraints.txt"
    local url="https://opendev.org/openstack/requirements/raw/branch/${branch}/upper-constraints.txt"
    log "fetching upper-constraints from ${url}"
    # -q disables any user-level ~/.curlrc defaults so auth headers from
    # other hosts do not leak into this request.
    if ! curl -q -fsSL "${url}" -o "${dest}"; then
        # Fallback to master if the branch-specific constraints file is missing.
        log "upper-constraints for ${branch} not found, falling back to master"
        curl -q -fsSL \
            "https://opendev.org/openstack/requirements/raw/branch/master/upper-constraints.txt" \
            -o "${dest}" \
            || die "failed to fetch upper-constraints.txt"
    fi
}

# Make sure the provisioned ~/scripts/ is in place before running a job.
require_provisioned_scripts() {
    if [ ! -f "${HOME}/scripts/upstream_translation_update_weblate.sh" ] \
        || [ ! -f "${HOME}/scripts/propose_translation_update_weblate.sh" ]; then
        die "~/scripts/ not provisioned. Run tools/local/setup.sh first."
    fi
    if [ ! -f "${HOME}/.config/weblate" ]; then
        die "~/.config/weblate not found. Run tools/local/setup.sh first."
    fi
}

print_usage() {
    cat <<USAGE
Usage: ${0##*/} [--project PROJECT] [--branch BRANCH] [--target-dir PATH] [--jobname JOB] [--force]
  Or positional: ${0##*/} PROJECT [BRANCH]

Flags:
  --project      Short project name (e.g., contributor-guide, horizon).
  --branch       Target branch in the fork (e.g., localtest/master). Default: master.
  --target-dir   Checkout path. Default: \$TARGETS_ROOT/<project>.
  --jobname      Zuul job name (upstream wrappers only). Auto-derived if omitted.
  --force        Bypass production-branch guard.

Environment: tools/local/.env.local (copy from .env.local.example).
USAGE
}
