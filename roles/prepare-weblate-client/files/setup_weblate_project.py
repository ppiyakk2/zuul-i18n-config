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
import sys

import requests


class SimpleIniConfig:
    """Read Weblate URL and API key from weblate.ini (wlc format)."""

    def __init__(self, inifile):
        config = configparser.ConfigParser(delimiters=("=",))
        config.read(inifile)
        self.url = config.get("weblate", "url").strip().rstrip("/")
        # Keys section maps URL -> token
        if config.has_section("keys"):
            for url, key in config.items("keys"):
                if url.startswith(("http://", "https://")):
                    self.key = key.strip()
                    break
            else:
                raise ValueError("No API key found in [keys] section")
        else:
            raise ValueError("No [keys] section in config")


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
                         category_slug=None, file_format="po",
                         source_language="en"):
        """Create a component (file-upload mode, no VCS).

        Args:
            project_slug: Project slug
            name: Component display name
            slug: Component slug
            category_slug: Category slug to place the component under
            file_format: Translation file format (default: po)
            source_language: Source language code (default: en)
        """
        # Check if component already exists
        existing = self.list_components(project_slug)
        for comp in existing:
            if comp.get("slug") == slug:
                # Check if it's in the right category
                comp_cat = comp.get("category_slug", "")
                if comp_cat == (category_slug or ""):
                    print(f"[component] '{slug}' already exists "
                          f"in category '{category_slug}' — skipping")
                    return False, comp

        data = {
            "name": name,
            "slug": slug,
            "file_format": file_format,
            "filemask": f"locale/*/LC_MESSAGES/{slug}.po",
            "new_base": f"locale/{slug}.pot",
            "vcs": "local",
            "repo": "local:",
            "source_language": {"code": source_language},
        }

        # Attach to category if specified
        if category_slug:
            category_url = self.get_category_url(project_slug, category_slug)
            if category_url:
                data["category"] = category_url
            else:
                print(f"[component] WARNING: category '{category_slug}' "
                      f"not found, creating without category")

        resp = self._post(f"projects/{project_slug}/components/", data)
        if resp.status_code in (200, 201):
            print(f"[component] '{slug}' created "
                  f"(category: {category_slug or 'none'})")
            return True, resp
        else:
            print(f"[component] failed to create '{slug}': "
                  f"HTTP {resp.status_code} — {resp.text}")
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


def slugify_branch(branch):
    """Convert branch name to Weblate slug.

    e.g., stable/2026.01 -> stable-2026-01
    Only letters, numbers, underscores, and hyphens are allowed.
    """
    import re
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
        "--no-verify-ssl", action="store_true",
        help="Disable SSL verification"
    )
    args = parser.parse_args()

    import os
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

    # 3. Create components under each category
    components = args.components or DEFAULT_COMPONENTS
    for cat_slug in category_slugs:
        print(f"\n--- Creating components in category '{cat_slug}' ---")
        for comp_name in components:
            setup.create_component(
                project_slug=project_slug,
                name=comp_name,
                slug=comp_name,
                category_slug=cat_slug,
            )

    print("\nDone! Summary:")
    print(f"  Project: {project_slug}")
    print(f"  Categories: {', '.join(args.branches)}")
    print(f"  Components per category: {', '.join(components)}")
    print(f"  Total components: {len(components) * len(category_slugs)}")


if __name__ == "__main__":
    main()
