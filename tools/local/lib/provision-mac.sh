#!/usr/bin/env bash
# Idempotent Mac provisioner. Mirrors the Ansible roles ensure-babel,
# ensure-sphinx, prepare-weblate-client to produce the same end-state:
#   ~/.venv with translation pip packages
#   ~/scripts/ with roles/prepare-weblate-client/files/*.{sh,py}
#   ~/.config/weblate with Weblate API credentials

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/common.sh"

BREW_PACKAGES=(gettext coreutils gnu-sed)
VENV_DIR="${HOME}/.venv"
# Python used to create the venv. .env.local can override via LOCAL_PYTHON.
PYTHON_BIN="${LOCAL_PYTHON:-${HOME}/.pyenv/versions/3.10.12/bin/python3}"
SCRIPTS_SRC_DIR="${REPO_ROOT}/roles/prepare-weblate-client/files"
SCRIPTS_DEST_DIR="${HOME}/scripts"
WEBLATE_CONFIG_DIR="${HOME}/.config"
WEBLATE_CONFIG_FILE="${WEBLATE_CONFIG_DIR}/weblate"
ZSHRC_FILE="${HOME}/.zshrc"
ZSHRC_SENTINEL="# zuul-i18n-config:gettext"

ensure_brew() {
    command -v brew >/dev/null 2>&1 \
        || die "Homebrew not installed. See https://brew.sh"
}

install_brew_packages() {
    for pkg in "${BREW_PACKAGES[@]}"; do
        if brew list --versions "${pkg}" >/dev/null 2>&1; then
            log "brew ${pkg} already installed"
        else
            log "brew install ${pkg}"
            brew install "${pkg}"
        fi
    done
}

ensure_gettext_on_path() {
    # gettext is keg-only on Mac; make it available to this shell and
    # persist in ~/.zshrc once (guarded by sentinel).
    local gettext_prefix
    gettext_prefix="$(brew --prefix gettext)"
    export PATH="${gettext_prefix}/bin:${PATH}"
    if [ -f "${ZSHRC_FILE}" ] && grep -qF "${ZSHRC_SENTINEL}" "${ZSHRC_FILE}"; then
        log "gettext PATH already configured in ~/.zshrc"
        return 0
    fi
    log "appending gettext PATH to ~/.zshrc"
    {
        echo ""
        echo "${ZSHRC_SENTINEL}"
        echo "export PATH=\"\$(brew --prefix gettext)/bin:\$PATH\""
        echo "export PATH=\"\$(brew --prefix gnu-sed)/libexec/gnubin:\$PATH\""
    } >> "${ZSHRC_FILE}"
}

ensure_venv() {
    [ -x "${PYTHON_BIN}" ] \
        || die "python not found at ${PYTHON_BIN}. Install via 'pyenv install 3.10.12' or set LOCAL_PYTHON in .env.local."
    if [ ! -x "${VENV_DIR}/bin/python" ]; then
        log "creating venv at ${VENV_DIR} (using ${PYTHON_BIN})"
        "${PYTHON_BIN}" -m venv "${VENV_DIR}"
    else
        local existing
        existing="$("${VENV_DIR}/bin/python" --version 2>&1)"
        log "venv exists at ${VENV_DIR} (${existing})"
    fi
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip setuptools
}

install_pip_packages() {
    log "installing pip packages into venv"
    "${VENV_DIR}/bin/pip" install --quiet \
        pbr Babel lxml requests \
        sphinx reno sphinx-intl openstackdocstheme \
        'wlc==1.15'
}

write_weblate_config() {
    mkdir -p "${WEBLATE_CONFIG_DIR}"
    chmod 700 "${WEBLATE_CONFIG_DIR}"
    umask 077
    cat > "${WEBLATE_CONFIG_FILE}" <<EOF
[weblate]
url = ${WEBLATE_URL}

[keys]
${WEBLATE_URL} = ${WEBLATE_TOKEN}
EOF
    chmod 600 "${WEBLATE_CONFIG_FILE}"
    log "wrote ${WEBLATE_CONFIG_FILE}"
}

copy_scripts() {
    mkdir -p "${SCRIPTS_DEST_DIR}"
    log "copying scripts to ${SCRIPTS_DEST_DIR}"
    # Copy every .sh and .py from the role's files/ dir. Superset of what
    # roles/prepare-weblate-client/tasks/main.yaml copies (includes
    # check_weblate_project.py which the upstream script references).
    local f
    for f in "${SCRIPTS_SRC_DIR}"/*.sh "${SCRIPTS_SRC_DIR}"/*.py; do
        [ -f "${f}" ] || continue
        cp -f "${f}" "${SCRIPTS_DEST_DIR}/"
    done
    chmod 755 "${SCRIPTS_DEST_DIR}"/*.sh
}

main() {
    load_env_local
    ensure_brew
    install_brew_packages
    ensure_gettext_on_path
    ensure_venv
    install_pip_packages
    write_weblate_config
    copy_scripts
    log "Mac provisioning done. venv: ${VENV_DIR}, scripts: ${SCRIPTS_DEST_DIR}"
}

main "$@"
