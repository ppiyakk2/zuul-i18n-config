#!/usr/bin/env bash
# Provision the local environment to run upstream/propose translation jobs
# without Zuul. Dispatches to Mac or Ubuntu by detecting uname.

set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

case "${OS}" in
    Darwin)
        exec bash "${_DIR}/lib/provision-mac.sh" "$@"
        ;;
    Linux)
        if [ ! -f /etc/os-release ]; then
            echo "[local] ERROR: /etc/os-release not found; unsupported Linux." >&2
            exit 1
        fi
        . /etc/os-release
        if [ "${ID:-}" != "ubuntu" ]; then
            echo "[local] ERROR: only Ubuntu is supported (detected: ${ID:-unknown})." >&2
            exit 1
        fi
        exec bash "${_DIR}/lib/provision-ubuntu.sh" "$@"
        ;;
    *)
        echo "[local] ERROR: unsupported OS '${OS}'. Supported: Darwin (Mac), Linux (Ubuntu)." >&2
        exit 1
        ;;
esac
