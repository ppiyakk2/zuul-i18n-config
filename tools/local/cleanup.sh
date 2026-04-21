#!/usr/bin/env bash
# Clean up artifacts created by local test runs. Refuses to touch production
# branches/categories.

set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_DIR}/lib/common.sh"

MODE=""
PROJECT=""
SLUG=""
REF=""

print_cleanup_usage() {
    cat <<USAGE
Usage: cleanup.sh [options]

One of:
  --weblate-category SLUG --project PROJECT
      Delete a Weblate category under the project (must match 'localtest-*' or
      have non-standard prefix — refuses to touch 'master' or 'stable-*').
  --github-branch REF --project PROJECT
      Delete a branch on the fork repo and close its open PR if any
      (must match 'weblate/translations/*').
  --all
      Remove local state: ~/.venv, ~/scripts, ~/.config/weblate,
      tools/local/.state/.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --weblate-category) MODE="weblate"; SLUG="$2"; shift 2 ;;
        --github-branch)    MODE="github";  REF="$2";  shift 2 ;;
        --project)          PROJECT="$2";              shift 2 ;;
        --all)              MODE="all";                shift ;;
        -h|--help)          print_cleanup_usage; exit 0 ;;
        *)                  die "unknown arg: $1" ;;
    esac
done

[ -n "${MODE}" ] || { print_cleanup_usage; exit 1; }

cleanup_weblate() {
    [ -n "${PROJECT}" ] || die "--project required"
    [ -n "${SLUG}" ] || die "--weblate-category SLUG required"
    case "${SLUG}" in
        master|stable-*|stable/*)
            die "refusing to delete production category: ${SLUG}"
            ;;
    esac
    load_env_local
    log "deleting Weblate category ${PROJECT}/${SLUG}"
    local base_url="${WEBLATE_URL%/}"
    base_url="${base_url%/api}"
    curl -fsS -X DELETE \
        -H "Authorization: Token ${WEBLATE_TOKEN}" \
        "${base_url}/api/categories/?project=${PROJECT}&name=${SLUG}" \
        || log "category delete request returned error (may not exist)"
    log "done"
}

cleanup_github() {
    [ -n "${PROJECT}" ] || die "--project required"
    [ -n "${REF}" ] || die "--github-branch REF required"
    case "${REF}" in
        weblate/translations/*) ;;
        *) die "refusing to delete non-weblate branch: ${REF}" ;;
    esac
    load_env_local
    require_github_env
    local api="https://api.github.com/repos/${FORK_OWNER}/${PROJECT}"
    log "closing open PRs from ${REF}"
    local pr_numbers
    pr_numbers="$(curl -fsS \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "${api}/pulls?head=${FORK_OWNER}:${REF}&state=open" \
        | python3 -c 'import json,sys; print(" ".join(str(p["number"]) for p in json.load(sys.stdin)))')"
    for n in ${pr_numbers}; do
        log "  closing PR #${n}"
        curl -fsS -X PATCH \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -d '{"state":"closed"}' \
            "${api}/pulls/${n}" > /dev/null
    done
    log "deleting branch ${REF}"
    curl -fsS -X DELETE \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "${api}/git/refs/heads/${REF}" \
        || log "branch delete returned error (may not exist)"
    log "done"
}

cleanup_all_local() {
    log "removing ~/.venv, ~/scripts, ~/.config/weblate, ${TOOLS_LOCAL_DIR}/.state"
    rm -rf "${HOME}/.venv" "${HOME}/scripts" \
           "${HOME}/.config/weblate" \
           "${TOOLS_LOCAL_DIR}/.state"
    log "done"
}

case "${MODE}" in
    weblate) cleanup_weblate ;;
    github)  cleanup_github ;;
    all)     cleanup_all_local ;;
esac
