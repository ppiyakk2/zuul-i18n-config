#!/usr/bin/env bash
# Local wrapper that invokes ~/scripts/upstream_translation_update_weblate.sh
# with the same signature Zuul uses.

set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_DIR}/lib/common.sh"

load_env_local
parse_common_args "$@"
derive_jobname_upstream
require_provisioned_scripts
guard_target_dir

# Horizon upstream needs upper-constraints.txt for install_horizon().
if [ "${PROJECT}" = "horizon" ]; then
    fetch_upper_constraints "${BRANCH}"
fi

log "running upstream_translation_update_weblate.sh ${PROJECT} ${JOBNAME} ${BRANCH}"
log "  target_dir=${TARGET_DIR}"
cd "${TARGET_DIR}"

export WEBLATE_URL WEBLATE_TOKEN
exec "${HOME}/scripts/upstream_translation_update_weblate.sh" \
    "${PROJECT}" "${JOBNAME}" "${BRANCH}"
