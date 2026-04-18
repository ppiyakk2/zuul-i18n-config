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

"""Upload POT files to Weblate components.

Called after a new commit is merged to update translation sources.
For each POT file:
  1. Preprocess (msgen + Language:enu header)
  2. Check if the component exists — create if missing
  3. Upload to the component's source language translation

Usage:
    python3 upload_pot_weblate.py \
        --config ~/.config/weblate \
        --project contributor-guide \
        --category master \
        --pot-dir translation-source/
"""

import argparse
import glob
import os
import subprocess
import sys
import tempfile

from setup_weblate_project import (
    SimpleIniConfig,
    WeblateSetup,
    prepare_pot_for_weblate,
    slugify_branch,
)


def msgen_pot(src, dst):
    """Run msgen to copy msgid -> msgstr (fill English source text).

    This is required for po-mono format where msgstr is displayed
    as the source text in the translation UI.
    """
    try:
        subprocess.run(
            ["msgen", src, "-o", dst],
            check=True, capture_output=True, text=True,
        )
        return True
    except subprocess.CalledProcessError as e:
        print(f"[msgen] failed for {src}: {e.stderr}")
        return False
    except FileNotFoundError:
        print("[msgen] ERROR: msgen not found. Install gettext.")
        sys.exit(1)


def preprocess_pot(pot_file, work_dir):
    """Apply msgen and add Language:enu header.

    Returns path to the preprocessed file, or None on failure.
    """
    basename = os.path.basename(pot_file)
    msgen_path = os.path.join(work_dir, f"msgen_{basename}")
    final_path = os.path.join(work_dir, basename)

    # Step 1: msgen (fill msgstr with English source)
    if not msgen_pot(pot_file, msgen_path):
        return None

    # Step 2: Add Language:enu header
    prepare_pot_for_weblate(msgen_path, final_path)
    return final_path


def pot_to_component_slug(pot_file):
    """Derive component slug from POT filename.

    e.g., doc-common.pot -> doc-common
    """
    return os.path.splitext(os.path.basename(pot_file))[0]


def main():
    parser = argparse.ArgumentParser(
        description="Upload POT files to Weblate components"
    )
    parser.add_argument(
        "--config", default="~/.config/weblate",
        help="Path to weblate.ini config file",
    )
    parser.add_argument(
        "--project", required=True,
        help="Weblate project slug (e.g., contributor-guide)",
    )
    parser.add_argument(
        "--category", required=True,
        help="Branch name used as category (e.g., master, stable/2026.01)",
    )
    parser.add_argument(
        "--pot-dir", required=True,
        help="Directory containing POT files to upload",
    )
    parser.add_argument(
        "--source-language", default="en_US",
        help="Source language code (default: en_US)",
    )
    parser.add_argument(
        "--no-verify-ssl", action="store_true",
        help="Disable SSL verification",
    )
    parser.add_argument(
        "--auto-create", action="store_true", default=True,
        help="Auto-create missing components (default: true)",
    )
    args = parser.parse_args()

    config_path = os.path.expanduser(args.config)
    wconfig = SimpleIniConfig(config_path)
    setup = WeblateSetup(wconfig, verify=not args.no_verify_ssl)

    category_slug = slugify_branch(args.category)

    # Collect POT files
    pot_files = sorted(glob.glob(os.path.join(args.pot_dir, "**", "*.pot"), recursive=True))
    if not pot_files:
        print(f"[upload] No POT files found in {args.pot_dir}")
        sys.exit(0)

    print(f"[upload] Found {len(pot_files)} POT file(s) in {args.pot_dir}")
    print(f"[upload] Project: {args.project}, Category: {category_slug}")

    # Ensure category exists
    existing_cats = setup.list_categories(args.project)
    cat_exists = any(c.get("slug") == category_slug for c in existing_cats)
    if not cat_exists:
        print(f"[upload] Category '{category_slug}' not found — creating")
        setup.create_category(args.project, args.category, category_slug)

    # Cache existing components in THIS category (avoid repeated API calls)
    # The API returns category as a URL (e.g., .../api/categories/1/),
    # so we first resolve our category_slug to its URL.
    target_cat_url = setup.get_category_url(args.project, category_slug)
    existing_components = setup.list_components(args.project)
    existing_slugs = set()
    for c in existing_components:
        comp_cat = c.get("category") or ""
        if comp_cat == target_cat_url:
            existing_slugs.add(c.get("slug"))

    results = {"ok": 0, "created": 0, "fail": 0, "skip": 0}

    with tempfile.TemporaryDirectory() as work_dir:
        for pot_file in pot_files:
            comp_slug = pot_to_component_slug(pot_file)
            print(f"\n--- {comp_slug} ---")

            # 1. Preprocess POT
            prepared = preprocess_pot(pot_file, work_dir)
            if not prepared:
                print(f"[{comp_slug}] preprocessing failed — skipping")
                results["fail"] += 1
                continue

            # 2. Check/create component
            if comp_slug not in existing_slugs:
                if args.auto_create:
                    print(f"[{comp_slug}] component not found — creating")
                    created, resp = setup.create_component(
                        project_slug=args.project,
                        name=comp_slug,
                        slug=comp_slug,
                        pot_file=prepared,
                        category_slug=category_slug,
                        source_language=args.source_language,
                    )
                    if created:
                        existing_slugs.add(comp_slug)
                        results["created"] += 1
                        # Component was just created with the POT file,
                        # so no separate upload needed
                        results["ok"] += 1
                        continue
                    else:
                        print(f"[{comp_slug}] creation failed — skipping")
                        results["fail"] += 1
                        continue
                else:
                    print(f"[{comp_slug}] component not found — skipping")
                    results["skip"] += 1
                    continue

            # 3. Upload POT to existing component's source language
            upload_ok, resp = upload_source_file(
                setup, args.project, comp_slug,
                category_slug, prepared, args.source_language,
            )
            if upload_ok:
                results["ok"] += 1
            else:
                results["fail"] += 1

    # Summary
    print(f"\n{'=' * 50}")
    print(f"Upload complete:")
    print(f"  OK:      {results['ok']}")
    print(f"  Created: {results['created']}")
    print(f"  Failed:  {results['fail']}")
    print(f"  Skipped: {results['skip']}")

    if results["fail"] > 0:
        sys.exit(1)


def upload_source_file(setup, project_slug, comp_slug,
                       category_slug, pot_file, source_language):
    """Upload a preprocessed POT to the component's source language.

    The component URL includes the category as a prefix in the slug:
    /api/translations/{project}/{category}%252F{component}/{lang}/file/
    """
    import requests

    # Build the component path (category/component, URL-encoded)
    comp_path = f"{category_slug}%252F{comp_slug}"
    url = setup._api_url(
        f"translations/{project_slug}/{comp_path}/{source_language}/file/"
    )

    headers = {
        "Accept": "application/json",
        "Authorization": setup.headers["Authorization"],
    }

    with open(pot_file, "rb") as f:
        files = {
            "file": (os.path.basename(pot_file), f, "application/x-gettext"),
        }
        data = {"method": "replace"}
        resp = requests.post(
            url, headers=headers, files=files, data=data,
            verify=setup.verify,
        )

    if resp.status_code in (200, 201):
        result = resp.json()
        accepted = result.get("accepted", 0)
        total = result.get("total", 0)
        print(f"[{comp_slug}] uploaded OK "
              f"(accepted: {accepted}, total: {total})")
        return True, resp
    else:
        print(f"[{comp_slug}] upload failed: "
              f"HTTP {resp.status_code} — {resp.text[:200]}")
        return False, resp


if __name__ == "__main__":
    main()
