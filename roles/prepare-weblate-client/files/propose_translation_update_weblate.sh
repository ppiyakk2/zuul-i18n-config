#!/bin/bash

# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

set -e
set -o pipefail

SCRIPTSDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTSDIR/common_translation_update.sh"

project=$1
branch=${2:-"master"}
PROJECT=$project
WEBLATE_BRANCH=${branch//\//-}
# install_horizon expects HORIZON_DIR to locate the horizon source tree;
# propose runs cd'd to the repo root, so default to current directory.
HORIZON_DIR=${HORIZON_DIR:-.}


# ---------------------------------------------------------------
# Project-type proposal functions
# ---------------------------------------------------------------

# Doc-only projects (openstack-manuals, contributor-guide, ...)
function propose_manuals {
    init_manuals "$PROJECT"

    case "$PROJECT" in
        api-site)
            cleanup_module "api-quick-start"
            cleanup_module "firstapp"
            ;;
        security-doc)
            cleanup_module "security-guide"
            ;;
        *)
            cleanup_module "doc"
            ;;
    esac

    # Stage imported upstream translations.
    for FILE in "${DocFolder}"/*; do
        DOCNAME=${FILE#${DocFolder}/}
        if [ -d "${DocFolder}/${DOCNAME}/locale" ]; then
            git add -A "${DocFolder}/${DOCNAME}/locale"
        fi
        if [ -d "${DocFolder}/${DOCNAME}/source/locale" ]; then
            git add -A "${DocFolder}/${DOCNAME}/source/locale"
        fi
    done
}

# Per-module Python/Django cleanup (mirrors OpenStack's
# propose_python_django).
function propose_python_django_module {
    local modulename=$1
    local version=$2

    if [ ! -d "$modulename/locale" ]; then
        return
    fi
    local content
    content=$(ls -A "$modulename/locale/" 2>/dev/null || true)
    if [ -z "$content" ]; then
        return
    fi

    # Stage first so cleanup_po_files can `git rm` tracked files.
    git add -A "$modulename/locale"

    cleanup_module "$modulename"
    if [ "$version" == "master" ]; then
        # Remove obsolete log-level translation files on master only;
        # stable branches keep them for historical parity.
        cleanup_log_files "$modulename"
    fi

    if [ -d "$modulename/locale" ]; then
        git add -A "$modulename/locale"
    fi
}

# Releasenotes quality gate and cleanup. Requires sphinx + reno in the
# venv (provided by ensure-sphinx role via propose pre.yaml).
function propose_releasenotes {
    local version=$1

    if [ "$version" != "master" ]; then
        return
    fi
    if [ ! -f releasenotes/source/conf.py ]; then
        return
    fi

    # check_releasenotes_per_language needs per-release POT files in
    # releasenotes/work/, so keep the workdir after extraction.
    extract_messages_releasenotes 1

    local lang_po
    for lang_po in $(find releasenotes/source/locale \
            -name 'releasenotes.po' 2>/dev/null); do
        check_releasenotes_per_language "$lang_po"
    done
    rm -rf releasenotes/work

    cleanup_pot_files "releasenotes"
    compress_po_files "releasenotes"

    if [ -d releasenotes/source/locale ]; then
        git add -A releasenotes/source/locale
    fi
}

# Python / Django projects (horizon, etc.)
function propose_python_django_all {
    setup_project "$PROJECT" "$WEBLATE_BRANCH"

    local python_modules
    local django_modules
    python_modules=$(get_modulename "$PROJECT" python)
    django_modules=$(get_modulename "$PROJECT" django)

    # Horizon's releasenotes/source/conf.py imports the horizon package;
    # install it so sphinx-build can run during POT extraction.
    if [ -n "$django_modules" ] \
            && [ "$branch" == "master" ] \
            && [ -f releasenotes/source/conf.py ]; then
        install_horizon
    fi

    local m
    for m in $python_modules; do
        echo "  Python module: $m"
        propose_python_django_module "$m" "$branch"
    done
    for m in $django_modules; do
        echo "  Django module: $m"
        propose_python_django_module "$m" "$branch"
    done

    propose_releasenotes "$branch"
}


# ---------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------

echo "=========================================="
echo "[propose] propose_translation_update_weblate.sh"
echo "=========================================="
echo "  project=$project"
echo "  branch=$branch"
echo "  WEBLATE_BRANCH=$WEBLATE_BRANCH"
echo "  PWD=$(pwd)"

echo ""
echo "=========================================="
echo "[step 1/7] Initializing branch: $branch"
echo "=========================================="
init_branch "$branch"

echo ""
echo "=========================================="
echo "[step 2/7] Setting up venv"
echo "=========================================="
setup_venv

echo ""
echo "=========================================="
echo "[step 3/7] Setting up git"
echo "=========================================="
setup_git

echo ""
echo "=========================================="
echo "[step 4/7] Downloading translations from Weblate"
echo "=========================================="
python3 "$SCRIPTSDIR/download_translations_weblate.py" \
    --config ~/.config/weblate \
    --project "$project" \
    --category "$WEBLATE_BRANCH"

echo ""
echo "=========================================="
echo "[step 5/7] Cleanup PO files for: $PROJECT"
echo "=========================================="
case "$PROJECT" in
    api-site|openstack-manuals|security-doc|contributor-guide)
        echo "  Type: manuals project"
        propose_manuals
        ;;
    training-guides)
        echo "  Type: training-guides"
        cleanup_module "doc"
        [ -d doc/source/locale ] && git add -A doc/source/locale
        ;;
    i18n)
        echo "  Type: i18n"
        cleanup_module "doc"
        [ -d doc/source/locale ] && git add -A doc/source/locale
        ;;
    *)
        echo "  Type: python/django"
        propose_python_django_all
        ;;
esac

echo ""
echo "=========================================="
echo "[step 6/7] Filter commits"
echo "=========================================="
setup_review "$branch"
filter_commits

echo ""
echo "=========================================="
echo "[step 7/7] Send patch"
echo "=========================================="
send_patch "$branch"

echo ""
echo "=========================================="
echo "[done] propose_translation_update_weblate.sh completed successfully"
echo "=========================================="
ERROR_ABORT=0
