#!/usr/bin/env bash
# Local wrapper that invokes ~/scripts/propose_translation_update_weblate.sh
# with the same signature Zuul uses, plus GITHUB_PROJECT/GITHUB_TOKEN.

set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_DIR}/lib/common.sh"

load_env_local
require_github_env
parse_common_args "$@"
require_provisioned_scripts
guard_target_dir

# Propose always needs upper-constraints (horizon Django install, etc.).
fetch_upper_constraints "${BRANCH}"

GITHUB_PROJECT="${FORK_OWNER}/${PROJECT}"

log "running propose_translation_update_weblate.sh ${PROJECT} ${BRANCH}"
log "  target_dir=${TARGET_DIR} github_project=${GITHUB_PROJECT}"
cd "${TARGET_DIR}"

export WEBLATE_URL WEBLATE_TOKEN GITHUB_TOKEN GITHUB_PROJECT
exec "${HOME}/scripts/propose_translation_update_weblate.sh" \
    "${PROJECT}" "${BRANCH}"
