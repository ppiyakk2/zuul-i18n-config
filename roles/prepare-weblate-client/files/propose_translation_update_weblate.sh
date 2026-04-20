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

echo "=========================================="
echo "[propose] propose_translation_update_weblate.sh"
echo "=========================================="
echo "  project=$project"
echo "  branch=$branch"
echo "  PWD=$(pwd)"

echo ""
echo "=========================================="
echo "[step 1/4] Download translations from Weblate"
echo "=========================================="
python3 "$SCRIPTSDIR/download_translations_weblate.py" \
    --config ~/.config/weblate \
    --project "$project" \
    --category "$branch"

echo ""
echo "=========================================="
echo "[step 2/4] Setup git"
echo "=========================================="
setup_git

echo ""
echo "=========================================="
echo "[step 3/4] Filter commits"
echo "=========================================="
setup_review "$branch"
filter_commits

echo ""
echo "=========================================="
echo "[step 4/4] Send patch"
echo "=========================================="
send_patch "$branch"

ERROR_ABORT=0
