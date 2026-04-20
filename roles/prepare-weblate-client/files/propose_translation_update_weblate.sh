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

source "$(dirname "${BASH_SOURCE[0]}")/common_translation_update.sh"

project=$1
branch=${2:-"master"}

: ${WEBLATE_URL:?ERROR: WEBLATE_URL is not set.}

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' INT TERM EXIT

get_target_info() {
    # Parse component slug to determine target directory and filename.
    # Module-prefixed Django components (e.g., horizon-django,
    # openstack-dashboard-djangojs) go to <module>/locale/.
    # Doc/releasenotes components go to <project>/locale/.
    #
    # Outputs: "<target_dir_base> <po_filename>"
    local component=$1
    local project=$2

    # Check for Django module pattern: <module>-django or <module>-djangojs
    if [[ "$component" =~ ^(.+)-(django|djangojs)$ ]]; then
        local module_slug="${BASH_REMATCH[1]}"
        local domain="${BASH_REMATCH[2]}"
        # Convert slug back to Python module name (hyphens -> underscores)
        local module_name=$(echo "$module_slug" | tr '-' '_')
        echo "$module_name ${domain}.po"
        return
    fi

    # Default: doc/releasenotes components -> project/locale/
    case "$component" in
        *)
            local po_name=$(echo "$component" | tr '-' '_')
            echo "$project ${po_name}.po"
            ;;
    esac
}

download_translation() {
    local project=$1
    local component=$2
    local language=$3
    local output_file=$4

    curl -q -s --config ~/.curlrc \
        "$WEBLATE_URL/translations/$project/$component/$language/file/" \
        -o "$output_file"
    [ $? -eq 0 ] && [ -s "$output_file" ]
}

process_translations() {
    local project=$1
    local component=$2

    if [[ "$component" == "glossary" ]]; then
        return
    fi

    local languages
    set +e
    languages=$(curl -q -s --config ~/.curlrc \
        "$WEBLATE_URL/components/$project/$component/translations/" | \
        jq -r '.results[] | select(.language.code != "en") |
        .language.code' 2>/dev/null)
    set -e

    if [[ -z "$languages" ]]; then
        return
    fi

    local lang
    for lang in $languages; do
        local temp_file="$TEMP_DIR/${component}_${lang}.po"

        if download_translation "$project" "$component" "$lang" \
                                "$temp_file"; then
            local target_info=$(get_target_info "$component" "$project")
            local target_base=$(echo "$target_info" | cut -d' ' -f1)
            local po_filename=$(echo "$target_info" | cut -d' ' -f2)
            local target_dir="$target_base/locale/$lang/LC_MESSAGES"
            mkdir -p "$target_dir"

            cp "$temp_file" "$target_dir/$po_filename"
        fi
    done

    local target_info=$(get_target_info "$component" "$project")
    local target_base=$(echo "$target_info" | cut -d' ' -f1)
    if [ -d "$target_base/locale" ]; then
        find "$target_base/locale" -name "*.po" -exec git add {} +
    fi
}

components=$(curl -q -s --config ~/.curlrc \
    "$WEBLATE_URL/projects/$project/components/" | \
    jq -r '.results[].slug' 2>/dev/null)

if [[ -z "$components" ]]; then
    echo "ERROR: No components found for project $project."
    exit 1
fi

for comp in $components; do
    process_translations "$project" "$comp"
done

setup_git
setup_review "$branch"
filter_commits
send_patch "$branch"
