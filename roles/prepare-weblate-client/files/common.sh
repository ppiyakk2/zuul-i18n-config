#!/bin/bash
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

# GitHub-adapted version of common.sh
# Original: openstack/project-config copy-proposal-common-scripts

# Setup git so that scripts can work with branches.
# In Zuul the initial state of the repo is detached HEAD.
function setup_git {
    git checkout -B proposals
}

# Set up commit message. In the OpenStack workflow this queries Gerrit
# for an existing open change and reuses its Change-Id.
# For GitHub we simply use the initial commit message as-is.
function setup_commit_message {
    local PROJECT=$1
    local USERNAME=$2
    local BRANCH=$3
    local TOPIC=$4
    local INITIAL_COMMIT_MSG=$5

    CHANGE_ID=""
    CHANGE_NUM=""
    COMMIT_MSG="$INITIAL_COMMIT_MSG"
}

# Check whether a change is already approved.
# For GitHub this is a no-op; PR merge status is handled differently.
function check_already_approved {
    local CHANGE_ID=$1
    # No-op for GitHub workflow
    return 0
}
