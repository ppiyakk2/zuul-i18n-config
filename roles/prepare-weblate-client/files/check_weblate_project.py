#!/usr/bin/env python3

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

"""Check if a Weblate project exists and is not locked.

Outputs one of:
  OK                  - project exists and is unlocked
  LOCKED              - project exists but is locked
  UNAVAILABLE:<code>  - project not found or API error
"""

import argparse
import os
import sys

from setup_weblate_project import SimpleIniConfig, WeblateSetup


def main():
    parser = argparse.ArgumentParser(
        description="Check Weblate project availability"
    )
    parser.add_argument(
        "--config", default="~/.config/weblate",
        help="Path to weblate.ini config file (default: ~/.config/weblate)"
    )
    parser.add_argument(
        "--project", required=True,
        help="Weblate project slug to check"
    )
    args = parser.parse_args()

    config_path = os.path.expanduser(args.config)
    wconfig = SimpleIniConfig(config_path)
    setup = WeblateSetup(wconfig)

    resp = setup.get_project(args.project)
    if resp.status_code != 200:
        print("UNAVAILABLE:" + str(resp.status_code))
        sys.exit(0)

    data = resp.json()
    if data.get("locked", False):
        print("LOCKED")
        sys.exit(0)

    print("OK")


if __name__ == "__main__":
    main()
