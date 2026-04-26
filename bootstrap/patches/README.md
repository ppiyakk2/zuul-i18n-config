# Zuul container patches

`graphql_init.py` is mounted into `zuul-scheduler`, `zuul-executor`, and
`zuul-web` containers (see `docker-compose.yaml`) at:

    /usr/local/lib/python3.11/site-packages/zuul/driver/github/graphql/__init__.py

It is a 4-line null-safety patch over the upstream Zuul 14.x file. Without it,
Zuul crashes when GitHub's GraphQL API returns `null` for `commit` or
`branchProtectionRules.pageInfo` on certain branches (notably brand-new repos
or PRs against deleted refs).

## Diff against upstream (`quay.io/zuul-ci/zuul-scheduler` 14.0.x)

```diff
@@ -118 +118 @@
-            if not rules_pageinfo['hasNextPage']:
+            if not rules_pageinfo or not rules_pageinfo['hasNextPage']:
@@ -184 +184 @@
-        status = commit.get('status') or {}
+        status = (commit.get('status') if commit else None) or {}
@@ -199,0 +200,2 @@
+        if not commit:
+            return
@@ -283 +285 @@
-            if not rules_pageinfo['hasNextPage']:
+            if not rules_pageinfo or not rules_pageinfo['hasNextPage']:
```

## When can this patch be removed

When upstream Zuul ships these null guards in
`zuul/driver/github/graphql/__init__.py`. As of Zuul 14.0.x they are absent.
Re-check on every Zuul image bump: pull the new container, diff
`__init__.py`, and drop this patch (and the corresponding volume mounts in
`docker-compose.yaml`) once upstream is fixed.
