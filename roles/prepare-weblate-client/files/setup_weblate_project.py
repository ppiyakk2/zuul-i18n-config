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

"""Setup Weblate project, categories, and components via REST API.

Usage:
    python setup_weblate_project.py --config ~/.config/weblate

This script creates:
  1. A project (e.g., contributor-guide)
  2. Categories under the project (branches like master, stable/2026.01)
  3. Components under each category (doc, doc-users, doc-operators, etc.)
"""

import argparse
import configparser
import json
import os
import re
import sys

import requests


class SimpleIniConfig:
    """Read Weblate URL and API key from weblate.ini (wlc format)."""

    def __init__(self, inifile):
        config = configparser.ConfigParser(delimiters=("=",))
        config.read(inifile)
        self.url = config.get("weblate", "url").strip().rstrip("/")
        # Format 1: [weblate] section has key directly (Zuul template)
        if config.has_option("weblate", "key"):
            self.key = config.get("weblate", "key").strip()
        # Format 2: [keys] section maps URL -> token (wlc format)
        elif config.has_section("keys"):
            for url, key in config.items("keys"):
                if url.startswith(("http://", "https://")):
                    self.key = key.strip()
                    break
            else:
                raise ValueError("No API key found in [keys] section")
        else:
            raise ValueError("No key found in config")


class WeblateSetup:
    """Create Weblate projects and categories via REST API."""

    def __init__(self, wconfig, verify=True):
        # Ensure base URL ends with /api
        url = wconfig.url.rstrip("/")
        if not url.endswith("/api"):
            url = url + "/api"
        self.api_base = url
        self.headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": "Token " + wconfig.key,
        }
        self.verify = verify

    def _api_url(self, path):
        return f"{self.api_base}/{path.lstrip('/')}"

    def _get(self, path):
        resp = requests.get(
            self._api_url(path),
            headers=self.headers,
            verify=self.verify,
        )
        return resp

    def _post(self, path, data):
        resp = requests.post(
            self._api_url(path),
            headers=self.headers,
            data=json.dumps(data),
            verify=self.verify,
        )
        return resp

    # -- Project ----------------------------------------------------------

    def get_project(self, slug):
        """Check if a project exists. Returns response."""
        return self._get(f"projects/{slug}/")

    def create_project(self, name, slug, web=""):
        """Create a project. Returns (created: bool, response)."""
        existing = self.get_project(slug)
        if existing.status_code == 200:
            print(f"[project] '{slug}' already exists — skipping")
            return False, existing

        data = {
            "name": name,
            "slug": slug,
            "web": web,
        }
        resp = self._post("projects/", data)
        if resp.status_code in (200, 201):
            print(f"[project] '{slug}' created successfully")
            return True, resp
        else:
            print(f"[project] failed to create '{slug}': "
                  f"HTTP {resp.status_code} — {resp.text}")
            return False, resp

    # -- Category ---------------------------------------------------------

    def list_categories(self, project_slug):
        """List existing categories for a project."""
        resp = self._get(f"projects/{project_slug}/categories/")
        if resp.status_code == 200:
            return resp.json().get("results", [])
        return []

    def create_category(self, project_slug, name, slug):
        """Create a category under a project.

        Categories in Weblate represent groupings — here we use them
        for branches (master, stable/2026.01, etc.).
        """
        existing = self.list_categories(project_slug)
        for cat in existing:
            if cat.get("slug") == slug:
                print(f"[category] '{slug}' already exists "
                      f"in project '{project_slug}' — skipping")
                return False, cat

        project_url = self._api_url(f"projects/{project_slug}/")
        data = {
            "name": name,
            "slug": slug,
            "project": project_url,
        }
        resp = self._post("categories/", data)
        if resp.status_code in (200, 201):
            print(f"[category] '{slug}' created in project '{project_slug}'")
            return True, resp
        else:
            print(f"[category] failed to create '{slug}': "
                  f"HTTP {resp.status_code} — {resp.text}")
            return False, resp

    # -- Component --------------------------------------------------------

    def get_category_url(self, project_slug, category_slug):
        """Get the API URL for a category."""
        categories = self.list_categories(project_slug)
        for cat in categories:
            if cat.get("slug") == category_slug:
                return cat.get("url")
        return None

    def list_components(self, project_slug):
        """List all components in a project (paginated)."""
        components = []
        path = f"projects/{project_slug}/components/"
        while path:
            resp = self._get(path)
            if resp.status_code != 200:
                break
            data = resp.json()
            components.extend(data.get("results", []))
            next_url = data.get("next")
            if next_url:
                # next_url is absolute, extract the path after /api/
                path = next_url.split("/api/", 1)[-1]
            else:
                path = None
        return components

    def create_component(self, project_slug, name, slug,
                         pot_file=None, category_slug=None,
                         source_language="en_US"):
        """Create a component with POT file upload (po-mono format).

        Uses docfile upload with po-mono format and explicit source_language.
        POT files must have 'Language: enu' header to avoid the built-in
        'en' language alias conflict.

        Args:
            project_slug: Project slug
            name: Component display name
            slug: Component slug
            pot_file: Path to POT file (with Language: enu header)
            category_slug: Category slug to place the component under
            source_language: Source language code (default: en_US)
        """
        # Check if component already exists
        existing = self.list_components(project_slug)
        for comp in existing:
            if comp.get("slug") == slug:
                comp_cat = comp.get("category_slug", "")
                if comp_cat == (category_slug or ""):
                    print(f"[component] '{slug}' already exists "
                          f"in category '{category_slug}' — skipping")
                    return False, comp

        # Build multipart form data
        form_data = {
            "name": (None, name),
            "slug": (None, slug),
            "file_format": (None, "po-mono"),
            "source_language": (None, source_language),
        }

        # Attach to category if specified
        if category_slug:
            category_url = self.get_category_url(project_slug, category_slug)
            if category_url:
                form_data["category"] = (None, category_url)
            else:
                print(f"[component] WARNING: category '{category_slug}' "
                      f"not found, creating without category")

        # Attach POT file
        if pot_file:
            form_data["docfile"] = (
                os.path.basename(pot_file),
                open(pot_file, "rb"),
                "application/x-gettext",
            )

        headers = {
            "Accept": "application/json",
            "Authorization": self.headers["Authorization"],
        }
        url = self._api_url(f"projects/{project_slug}/components/")
        resp = requests.post(
            url, headers=headers, files=form_data, verify=self.verify,
        )

        if resp.status_code in (200, 201):
            print(f"[component] '{slug}' created "
                  f"(category: {category_slug or 'none'})")
            return True, resp
        else:
            print(f"[component] failed to create '{slug}': "
                  f"HTTP {resp.status_code} — {resp.text[:200]}")
            return False, resp


# Default components for contributor-guide
DEFAULT_COMPONENTS = [
    "doc",
    "doc-code-and-documentation",
    "doc-common",
    "doc-contributing",
    "doc-non-code-contribution",
    "doc-operators",
    "doc-organizations",
    "doc-users",
]


def prepare_pot_for_weblate(src_pot, dst_pot):
    """Add 'Language: enu' header to POT file for Weblate compatibility.

    Weblate's built-in 'en' pseudo-language has 'en_us' as an alias,
    which conflicts with the real 'en_US' language. Using 'enu'
    (a unique alias for en_US) avoids this conflict.
    """
    with open(src_pot, "r", encoding="utf-8") as f:
        content = f.read()

    # Add Language header if not present
    if '"Language:' not in content:
        content = content.replace(
            '"Content-Transfer-Encoding:',
            '"Language: enu\\n"\n"Content-Transfer-Encoding:',
        )
    dst_dir = os.path.dirname(dst_pot)
    if dst_dir:
        os.makedirs(dst_dir, exist_ok=True)
    with open(dst_pot, "w", encoding="utf-8") as f:
        f.write(content)


def slugify_branch(branch):
    """Convert branch name to Weblate slug.

    e.g., stable/2026.01 -> stable-2026-01
    Only letters, numbers, underscores, and hyphens are allowed.
    """
    slug = branch.replace("/", "-")
    slug = re.sub(r"[^a-zA-Z0-9_-]", "-", slug)
    return slug


def main():
    parser = argparse.ArgumentParser(
        description="Setup Weblate project and categories"
    )
    parser.add_argument(
        "--config", default="~/.config/weblate",
        help="Path to weblate.ini config file (default: ~/.config/weblate)"
    )
    parser.add_argument(
        "--project-name", default="contributor-guide",
        help="Project name (default: contributor-guide)"
    )
    parser.add_argument(
        "--project-slug", default=None,
        help="Project slug (default: same as project-name)"
    )
    parser.add_argument(
        "--project-web",
        default="https://docs.openstack.org/contributor-guide/",
        help="Project website URL"
    )
    parser.add_argument(
        "--branches", nargs="+", default=["master"],
        help="Branch names to create as categories (default: master)"
    )
    parser.add_argument(
        "--components", nargs="+", default=None,
        help="Component names to create (default: all contributor-guide docs)"
    )
    parser.add_argument(
        "--pot-dir", default=None,
        help="Directory containing POT files for component creation"
    )
    parser.add_argument(
        "--no-verify-ssl", action="store_true",
        help="Disable SSL verification"
    )
    args = parser.parse_args()

    config_path = os.path.expanduser(args.config)
    wconfig = SimpleIniConfig(config_path)

    project_slug = args.project_slug or args.project_name

    setup = WeblateSetup(wconfig, verify=not args.no_verify_ssl)

    # 1. Create project
    created, resp = setup.create_project(
        name=args.project_name,
        slug=project_slug,
        web=args.project_web,
    )
    if not created and resp.status_code not in (200, 201):
        print("Failed to create or find project, aborting.")
        sys.exit(1)

    # 2. Create categories (branches)
    category_slugs = []
    for branch in args.branches:
        slug = slugify_branch(branch)
        category_slugs.append(slug)
        setup.create_category(
            project_slug=project_slug,
            name=branch,
            slug=slug,
        )

    # 3. Prepare POT files (add Language: enu header if missing)
    components = args.components or DEFAULT_COMPONENTS
    pot_dir = args.pot_dir
    if pot_dir:
        prepared_dir = os.path.join(pot_dir, "_prepared")
        os.makedirs(prepared_dir, exist_ok=True)
        for comp_name in components:
            src = os.path.join(pot_dir, f"{comp_name}.pot")
            dst = os.path.join(prepared_dir, f"{comp_name}.pot")
            if os.path.exists(src):
                prepare_pot_for_weblate(src, dst)
        pot_dir = prepared_dir

    # 4. Create components under each category
    for cat_slug in category_slugs:
        print(f"\n--- Creating components in category '{cat_slug}' ---")
        for comp_name in components:
            pot_file = None
            if pot_dir:
                pot_path = os.path.join(pot_dir, f"{comp_name}.pot")
                if os.path.exists(pot_path):
                    pot_file = pot_path
                else:
                    print(f"[component] WARNING: POT not found: {pot_path}")
            setup.create_component(
                project_slug=project_slug,
                name=comp_name,
                slug=comp_name,
                pot_file=pot_file,
                category_slug=cat_slug,
            )

    print("\nDone! Summary:")
    print(f"  Project: {project_slug}")
    print(f"  Categories: {', '.join(args.branches)}")
    print(f"  Components per category: {', '.join(components)}")
    print(f"  Total components: {len(components) * len(category_slugs)}")


if __name__ == "__main__":
    main()
