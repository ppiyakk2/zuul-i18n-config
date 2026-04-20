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

PROJECT=$1
JOBNAME=$2
BRANCHNAME=$3
HORIZON_DIR=${4:-.}

# WEBLATE_BRANCH: normalize for slug ( '/' -> '-' )
WEBLATE_BRANCH=${BRANCHNAME//\//-}

SCRIPTSDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPTSDIR/common_translation_update.sh"

echo "=========================================="
echo "[args] upstream_translation_update_weblate.sh"
echo "=========================================="
echo "  \$1 PROJECT=$PROJECT"
echo "  \$2 JOBNAME=$JOBNAME"
echo "  \$3 BRANCHNAME=$BRANCHNAME"
echo "  \$4 HORIZON_DIR=$HORIZON_DIR"
echo "  WEBLATE_BRANCH=$WEBLATE_BRANCH"
echo "  SCRIPTSDIR=$SCRIPTSDIR"
echo "  PWD=$(pwd)"

echo ""
echo "=========================================="
echo "[step 1/7] Checking Weblate environment"
echo "=========================================="
# checks weblate env
: "${WEBLATE_URL:?Set WEBLATE_URL}"
: "${WEBLATE_TOKEN:?Set WEBLATE_TOKEN}"
WEBLATE_PROJECT="${WEBLATE_PROJECT:-$PROJECT}"
# Derive base URL (strip trailing /api/ if present)
WEBLATE_BASE_URL="${WEBLATE_URL%/}"
WEBLATE_BASE_URL="${WEBLATE_BASE_URL%/api}"
echo "  PROJECT=$PROJECT"
echo "  BRANCHNAME=$BRANCHNAME"
echo "  WEBLATE_PROJECT=$WEBLATE_PROJECT"
echo "  WEBLATE_BRANCH=$WEBLATE_BRANCH"
echo "  WEBLATE_URL=$WEBLATE_URL"
echo "  WEBLATE_BASE_URL=$WEBLATE_BASE_URL"


# Check if the Weblate project exists and is not locked (via Python)
weblate_project_check_or_skip() {
  local result
  result=$(PYTHONPATH="$SCRIPTSDIR" python3 "$SCRIPTSDIR/check_weblate_project.py" \
      --config ~/.config/weblate \
      --project "${WEBLATE_PROJECT}" 2>&1) || true

  echo "  Project check result: $result"

  case "$result" in
    UNAVAILABLE:*)
      echo "[weblate] project '${WEBLATE_PROJECT}' unavailable ($result) -> skip job"
      ERROR_ABORT=0
      exit 0
      ;;
    LOCKED)
      echo "[weblate] project '${WEBLATE_PROJECT}' locked -> skip job"
      ERROR_ABORT=0
      exit 0
      ;;
    OK)
      echo "  Project OK (unlocked)"
      ;;
    *)
      echo "[weblate] project check error: $result"
      echo "  Continuing anyway..."
      ;;
  esac
}

echo ""
echo "=========================================="
echo "[step 2/7] Initializing branch: $BRANCHNAME"
echo "=========================================="
init_branch "$BRANCHNAME"

# List of all modules to copy POT files from
ALL_MODULES=""

echo ""
echo "=========================================="
echo "[step 3/7] Setting up venv"
echo "=========================================="
setup_venv

echo ""
echo "=========================================="
echo "[step 4/7] Checking Weblate project"
echo "=========================================="
weblate_project_check_or_skip

echo ""
echo "=========================================="
echo "[step 5/7] Setting up git"
echo "=========================================="
setup_git

echo ""
echo "=========================================="
echo "[step 6/7] Extracting messages for: $PROJECT"
echo "=========================================="
# Project setup and updating POT files.
case "$PROJECT" in
  api-site|openstack-manuals|security-doc)
    echo "  Type: manuals project"
    init_manuals "$PROJECT"
    setup_manuals "$PROJECT" "$WEBLATE_BRANCH"
    case "$PROJECT" in
      api-site)      ALL_MODULES="api-quick-start firstapp" ;;
      security-doc)  ALL_MODULES="security-guide" ;;
      *)             ALL_MODULES="doc" ;;
    esac
    if [[ "$WEBLATE_BRANCH" == "master" && -f releasenotes/source/conf.py ]]; then
      echo "  Extracting release notes"
      extract_messages_releasenotes
      ALL_MODULES="releasenotes $ALL_MODULES"
    fi
    ;;
  training-guides)
    echo "  Type: training-guides"
    setup_training_guides "$WEBLATE_BRANCH"
    ALL_MODULES="doc"
    ;;
  i18n)
    echo "  Type: i18n"
    setup_i18n "$WEBLATE_BRANCH"
    ALL_MODULES="doc"
    ;;
  tripleo-ui)
    echo "  Type: ReactJS (tripleo-ui)"
    setup_reactjs_project "$PROJECT" "$WEBLATE_BRANCH"
    ALL_MODULES="i18n"
    ;;
  *)
    echo "  Type: generic project"
    setup_project "$PROJECT" "$WEBLATE_BRANCH"

    module_names=$(get_modulename "$PROJECT" python)
    if [ -n "$module_names" ]; then
      echo "  Python modules: $module_names"
      if [[ "$WEBLATE_BRANCH" == "master" && -f releasenotes/source/conf.py ]]; then
        echo "  Extracting release notes"
        extract_messages_releasenotes
        ALL_MODULES="releasenotes $ALL_MODULES"
      fi
      for modulename in $module_names; do
        echo "  Extracting Python messages: $modulename"
        extract_messages_python "$modulename"
        ALL_MODULES="$modulename $ALL_MODULES"
      done
    fi

    module_names=$(get_modulename "$PROJECT" django)
    if [ -n "$module_names" ]; then
      echo "  Django modules: $module_names"
      install_horizon
      if [[ "$WEBLATE_BRANCH" == "master" && -f releasenotes/source/conf.py ]]; then
        echo "  Extracting release notes"
        extract_messages_releasenotes
        ALL_MODULES="releasenotes $ALL_MODULES"
      fi
      for modulename in $module_names; do
        echo "  Extracting Django messages: $modulename"
        extract_messages_django "$modulename"
        ALL_MODULES="$modulename $ALL_MODULES"
      done
    fi

    if [[ -f doc/source/conf.py ]]; then
      if [[ ${DOC_TARGETS[*]} =~ "$PROJECT" ]]; then
        echo "  Extracting doc messages"
        extract_messages_doc
        ALL_MODULES="doc $ALL_MODULES"
      fi
    fi
    ;;
esac
echo "  ALL_MODULES=$ALL_MODULES"

echo ""
echo "=========================================="
echo "[step 7/7] Uploading POT files to Weblate"
echo "=========================================="
# Collect POT files for upload
copy_pot "$ALL_MODULES"
rm -rf translation-source
mv .translation-source translation-source
echo "  POT files:"
find translation-source -name "*.pot" -exec echo "  {}" \; 2>/dev/null || echo "  (none)"

# Upload POT files to Weblate via Python script
# - Preprocesses each POT (msgen + Language:enu header)
# - Auto-creates missing components
# - Uploads to the component's source language (en_US)
python3 "$SCRIPTSDIR/upload_pot_weblate.py" \
    --config ~/.config/weblate \
    --project "$WEBLATE_PROJECT" \
    --category "$WEBLATE_BRANCH" \
    --pot-dir translation-source/

# Tell finish function that everything is fine.
echo ""
echo "=========================================="
echo "[done] upstream_translation_update_weblate.sh completed successfully"
echo "=========================================="
ERROR_ABORT=0
