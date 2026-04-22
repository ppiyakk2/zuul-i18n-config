#!/usr/bin/env bash
# Idempotent Ubuntu 24.04 provisioner. Reuses the existing Ansible roles via
# ansible-playbook -c local so local env stays in sync with Zuul.

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/common.sh"

STATE_DIR="${TOOLS_LOCAL_DIR}/.state"
SENTINEL="${STATE_DIR}/ubuntu-ready"
PLAYBOOK="${REPO_ROOT}/playbooks/local/setup.yaml"

APT_PACKAGES=(
    gettext python3-venv python3-pip git curl ansible
    build-essential libxml2-dev libxslt1-dev libssl-dev libffi-dev pkg-config
)

compute_role_hash() {
    cat \
        "${REPO_ROOT}/roles/ensure-babel/tasks/main.yaml" \
        "${REPO_ROOT}/roles/ensure-sphinx/tasks/main.yaml" \
        "${REPO_ROOT}/roles/prepare-weblate-client/tasks/main.yaml" \
        | sha256sum | cut -d' ' -f1
}

install_apt_packages() {
    log "sudo apt-get update + install (${#APT_PACKAGES[@]} packages)"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${APT_PACKAGES[@]}"
}

run_ansible_roles() {
    [ -f "${PLAYBOOK}" ] || die "missing ${PLAYBOOK}"
    log "running ansible-playbook -c local against ${PLAYBOOK}"
    # --roles-path: Zuul auto-sets ANSIBLE_ROLES_PATH, we need to point
    # at the repo's roles/ dir explicitly when running outside Zuul.
    ANSIBLE_ROLES_PATH="${REPO_ROOT}/roles" \
    ansible-playbook -i localhost, -c local \
        -e "weblate_api_credentials={url: '${WEBLATE_URL}', token: '${WEBLATE_TOKEN}'}" \
        "${PLAYBOOK}"
}

main() {
    load_env_local
    mkdir -p "${STATE_DIR}"
    local current_hash
    current_hash="$(compute_role_hash)"
    if [ -f "${SENTINEL}" ] && [ "$(cat "${SENTINEL}")" = "${current_hash}" ]; then
        log "local env already provisioned (role hash match). Skipping."
        exit 0
    fi
    install_apt_packages
    run_ansible_roles
    echo "${current_hash}" > "${SENTINEL}"
    log "Ubuntu provisioning done. Sentinel: ${SENTINEL}"
}

main "$@"
