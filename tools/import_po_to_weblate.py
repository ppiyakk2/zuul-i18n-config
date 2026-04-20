#!/usr/bin/env python3
"""Import existing PO files from a repository into Weblate.

One-time utility to seed Weblate with translations that already
exist in the source repository.

Usage:
    python3 import_po_to_weblate.py \
        --config ~/.config/weblate \
        --project contributor-guide \
        --category master \
        --po-dir doc/source/locale

PO files are expected at:
    <po-dir>/<lang>/LC_MESSAGES/<component>.po
The component slug is derived from the PO filename
(e.g., doc-common.po -> doc-common).
"""

import argparse
import glob
import os
import sys

import requests

sys.path.insert(0, os.path.join(
    os.path.dirname(__file__), "..", "roles",
    "prepare-weblate-client", "files"))

from setup_weblate_project import SimpleIniConfig, WeblateSetup, slugify_branch  # noqa: E402


def find_po_files(po_dir):
    """Find all PO files.

    Returns list of (lang, component_slug, filepath).
    """
    results = []
    pattern = os.path.join(po_dir, "*/LC_MESSAGES/*.po")
    for path in sorted(glob.glob(pattern)):
        rel = os.path.relpath(path, po_dir)
        parts = rel.replace("\\", "/").split("/")
        # parts: [lang, "LC_MESSAGES", "filename.po"]
        if len(parts) != 3:
            continue
        lang = parts[0]
        comp_slug = os.path.splitext(parts[2])[0]
        results.append((lang, comp_slug, path))
    return results


def ensure_translation(
    setup, project_slug, category_slug, comp_slug, language,
):
    """Ensure a translation exists for a component.

    Create if missing.
    """
    comp_path = f"{category_slug}%252F{comp_slug}"
    url = setup._api_url(
        f"translations/{project_slug}/{comp_path}/{language}/"
    )
    resp = requests.get(url, headers=setup.headers, verify=setup.verify)
    if resp.status_code == 200:
        return True

    # Create the translation
    create_url = setup._api_url(
        f"components/{project_slug}/{comp_path}/translations/"
    )
    resp = requests.post(
        create_url,
        headers=setup.headers,
        json={"language_code": language},
        verify=setup.verify,
    )
    if resp.status_code in (200, 201):
        return True
    else:
        print(f"  [{language}] failed to add language: "
              f"HTTP {resp.status_code} — {resp.text[:200]}")
        return False


def upload_po(
    setup, project_slug, category_slug,
    comp_slug, language, po_file,
):
    """Upload a PO file to Weblate."""
    if not ensure_translation(
        setup, project_slug, category_slug,
        comp_slug, language,
    ):
        return False

    comp_path = f"{category_slug}%252F{comp_slug}"
    url = setup._api_url(
        f"translations/{project_slug}/{comp_path}/{language}/file/"
    )
    headers = {
        "Accept": "application/json",
        "Authorization": setup.headers["Authorization"],
    }
    with open(po_file, "rb") as f:
        files = {
            "file": (
                os.path.basename(po_file), f,
                "application/x-gettext",
            ),
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
        skipped = result.get("skipped", 0)
        print(
            f"  [{language}] OK "
            f"(accepted: {accepted}, "
            f"skipped: {skipped}, total: {total})"
        )
        return True
    else:
        print(
            f"  [{language}] FAILED: "
            f"HTTP {resp.status_code} — "
            f"{resp.text[:200]}"
        )
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Import PO files into Weblate",
    )
    parser.add_argument(
        "--config", default="~/.config/weblate",
    )
    parser.add_argument("--project", required=True)
    parser.add_argument(
        "--category", required=True,
        help="Branch name (e.g., master)",
    )
    parser.add_argument(
        "--po-dir", required=True,
        help="Directory with locale/<lang>/LC_MESSAGES/*.po",
    )
    args = parser.parse_args()

    config_path = os.path.expanduser(args.config)
    wconfig = SimpleIniConfig(config_path)
    setup = WeblateSetup(wconfig)
    category_slug = slugify_branch(args.category)

    po_files = find_po_files(args.po_dir)
    if not po_files:
        print(f"No PO files found in {args.po_dir}")
        sys.exit(0)

    # Group by component
    by_comp = {}
    for lang, comp_slug, path in po_files:
        by_comp.setdefault(comp_slug, []).append((lang, path))

    print(
        f"Found {len(po_files)} PO file(s) "
        f"across {len(by_comp)} component(s)"
    )
    print(f"Project: {args.project}, Category: {category_slug}\n")

    ok = 0
    fail = 0
    for comp_slug in sorted(by_comp):
        print(f"--- {comp_slug} ---")
        for lang, path in sorted(by_comp[comp_slug]):
            if upload_po(
                setup, args.project, category_slug,
                comp_slug, lang, path,
            ):
                ok += 1
            else:
                fail += 1

    print(f"\nDone: {ok} uploaded, {fail} failed")


if __name__ == "__main__":
    main()
