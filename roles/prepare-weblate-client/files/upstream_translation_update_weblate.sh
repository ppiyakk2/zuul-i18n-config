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
HORIZON_DIR=$4

# WEBLATE_BRANCH: normalize for slug ( '/' -> '-' )
WEBLATE_BRANCH=${BRANCHNAME//\//-}

SCRIPTSDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPTSDIR/common_translation_update.sh"

# checks weblate env
: "${WEBLATE_URL:?Set WEBLATE_URL}"
: "${WEBLATE_TOKEN:?Set WEBLATE_TOKEN}"
WEBLATE_PROJECT="${WEBLATE_PROJECT:-$PROJECT}"
WEBLATE_COMPONENT="${WEBLATE_COMPONENT:-$PROJECT-$WEBLATE_BRANCH}"


# Check if the component exists in Weblate
weblate_component_check_or_skip() {
  local url="${WEBLATE_URL%/}/api/components/${WEBLATE_PROJECT}/${WEBLATE_COMPONENT}/"
  # Separate response body/code
  local tmp resp_code
  tmp="$(mktemp)"
  resp_code=$(curl -w "%{http_code}" --config ~/.curlrc \
               "$url" -o "$tmp" || true)

  # If response is not 200 (component does not exist) → skip (exit 0)
  if [[ "$resp_code" != "200" ]]; then
    echo "[weblate] component unavailable (HTTP $resp_code) -> skip job"
    ERROR_ABORT=0
    rm -f "$tmp"
    exit 0
  fi

  # Check lock status
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.locked==true or .is_locked==true' "$tmp" >/dev/null; then
      echo "[weblate] component locked -> skip job"
      ERROR_ABORT=0
      rm -f "$tmp"
      exit 0
    fi
  else
    if grep -qE '"(locked|is_locked)"[[:space:]]*:[[:space:]]*true' "$tmp"; then
      echo "[weblate] component locked -> skip job"
      ERROR_ABORT=0
      rm -f "$tmp"
      exit 0
    fi
  fi

  rm -f "$tmp"
}

init_branch "$BRANCHNAME"

# List of all modules to copy POT files from
ALL_MODULES=""

# Setup venv - needed for all projects for our tools
setup_venv

# Skip if component does not exist or is locked in Weblate
weblate_component_check_or_skip

setup_git

# Project setup and updating POT files.
case "$PROJECT" in
  api-site|openstack-manuals|security-doc)
    init_manuals "$PROJECT"
    setup_manuals "$PROJECT" "$WEBLATE_BRANCH"
    case "$PROJECT" in
      api-site)      ALL_MODULES="api-quick-start firstapp" ;;
      security-doc)  ALL_MODULES="security-guide" ;;
      *)             ALL_MODULES="doc" ;;
    esac
    if [[ "$WEBLATE_BRANCH" == "master" && -f releasenotes/source/conf.py ]]; then
      extract_messages_releasenotes
      ALL_MODULES="releasenotes $ALL_MODULES"
    fi
    ;;
  training-guides)
    setup_training_guides "$WEBLATE_BRANCH"
    ALL_MODULES="doc"
    ;;
  i18n)
    setup_i18n "$WEBLATE_BRANCH"
    ALL_MODULES="doc"
    ;;
  tripleo-ui)
    setup_reactjs_project "$PROJECT" "$WEBLATE_BRANCH"
    ALL_MODULES="i18n"
    ;;
  *)
    setup_project "$PROJECT" "$WEBLATE_BRANCH"

    module_names=$(get_modulename "$PROJECT" python)
    if [ -n "$module_names" ]; then
      if [[ "$WEBLATE_BRANCH" == "master" && -f releasenotes/source/conf.py ]]; then
        extract_messages_releasenotes
        ALL_MODULES="releasenotes $ALL_MODULES"
      fi
      for modulename in $module_names; do
        extract_messages_python "$modulename"
        ALL_MODULES="$modulename $ALL_MODULES"
      done
    fi

    module_names=$(get_modulename "$PROJECT" django)
    if [ -n "$module_names" ]; then
      install_horizon
      if [[ "$WEBLATE_BRANCH" == "master" && -f releasenotes/source/conf.py ]]; then
        extract_messages_releasenotes
        ALL_MODULES="releasenotes $ALL_MODULES"
      fi
      for modulename in $module_names; do
        extract_messages_django "$modulename"
        ALL_MODULES="$modulename $ALL_MODULES"
      done
    fi

    if [[ -f doc/source/conf.py ]]; then
      if [[ ${DOC_TARGETS[*]} =~ "$PROJECT" ]]; then
        extract_messages_doc
        ALL_MODULES="doc $ALL_MODULES"
      fi
    fi
    ;;
esac

# Weblate API upload
copy_pot "$ALL_MODULES"
mkdir -p translation-source
mv .translation-source translation-source

# POT upload
for pot in translation-source/*.pot; do
  [ -f "$pot" ] || continue

  msgen "$pot" -o "$pot"

  curl -X POST \
    --config ~/.curlrc \
    -H "Accept: application/json" \
    -F "file=@${pot}" \
    -F "method=replace" \
    "${WEBLATE_URL%/}/api/translations/${WEBLATE_PROJECT}/${WEBLATE_COMPONENT}/en_US/file/" >/dev/null
done

# Tell finish function that everything is fine.
ERROR_ABORT=0
