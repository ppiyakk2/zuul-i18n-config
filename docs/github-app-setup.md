# GitHub App setup for Zuul

Zuul authenticates to GitHub as a GitHub App (not a Personal Access Token).
This document covers creating the App, installing it on the right repos, and
extracting the values that go into `bootstrap/etc/zuul/zuul.conf`.

If you are reusing the existing test-env App (`app_id=<GITHUB_APP_ID>`), you can
skip to "[Reusing an existing App for a new Zuul instance](#reusing-an-existing-app-for-a-new-zuul-instance)".

## What Zuul needs from the App

| Value | Used in | Where to find it after creation |
|-------|---------|---------------------------------|
| App ID | `zuul.conf` `[connection "github.com"] app_id` | App settings page header |
| Webhook secret | `zuul.conf` `webhook_token` | You set it during creation; cannot be retrieved later — write it down |
| Private key (`.pem`) | `etc/zuul/github_app.pem` | Generated on the App page; downloaded once |

The propose jobs additionally use a **Personal Access Token** for pushing PRs
(see `zuul.d/secrets.yaml` `github_credentials`). The App is for read +
webhook + status; the PAT is for write. Don't conflate them.

## 1. Create the App

GitHub → **Settings** → **Developer settings** → **GitHub Apps** → **New
GitHub App**.

Use the org account if Zuul should access org repos; use a personal account
for personal forks.

| Field | Value | Notes |
|-------|-------|-------|
| GitHub App name | e.g. `zuul-i18n-test` | Globally unique on GitHub |
| Homepage URL | `http://<ZUUL_HOST_IP>:9000/` | Anything reachable; not validated |
| Callback URL | (leave blank) | Zuul does not use OAuth user flow |
| Webhook → Active | ☑ Active | Required even if your network blocks delivery — Zuul reads webhooks via REST too |
| Webhook URL | `http://<ZUUL_HOST_IP>:9000/api/connection/github.com/payload` | The path is fixed by Zuul |
| Webhook secret | Generate a random string | This is `webhook_token` in zuul.conf |
| SSL verification | Enable (or disable if your Zuul host lacks TLS) | Test envs commonly disable |

## 2. Permissions

Set repository permissions:

| Permission | Access | Why |
|------------|--------|-----|
| Actions | Read | Build/PR status integration |
| Checks | Read & write | Reporting check runs back to PRs |
| Commit statuses | Read & write | Reporting `check`/`post`/`periodic` results |
| Contents | Read | Cloning repos |
| Issues | Read & write | Periodic jobs may comment on issues |
| Metadata | Read (auto) | Mandatory baseline |
| Pull requests | Read & write | Triggering on PR events; commenting |

Subscribe to events:

* `Push`
* `Pull request`
* `Issue comment` (used by `recheck` triggers)
* `Pull request review` (optional; for review-based pipelines)

Where can this GitHub App be installed: **Only on this account** for a
private/test setup, **Any account** if you intend to install it on multiple
orgs.

Click **Create GitHub App**.

## 3. Generate and download the private key

Scroll to **Private keys** → **Generate a private key**. Browser downloads a
`.pem` file once. Save it as `github_app.pem` and copy it to the Zuul host:

```bash
scp github_app.pem ubuntu@<ZUUL_HOST_IP>:~/zuul-test/etc/zuul/github_app.pem
ssh ubuntu@<ZUUL_HOST_IP> 'chmod 600 ~/zuul-test/etc/zuul/github_app.pem'
```

If you lose this file, regenerate (old keys remain valid until you delete
them).

## 4. Note the App ID

Top of the App settings page, e.g. `App ID: <GITHUB_APP_ID>`. This is the
`app_id=` value in `zuul.conf`.

## 5. Install the App on the right repos

**Install App** → choose the account → **Only select repositories** → pick:

* The Zuul **config-project** fork (e.g. `<your-org>/zuul-i18n-config`)
* Every **untrusted-project** named in `main.yaml` (e.g.
  `<your-org>/contributor-guide`, `<your-org>/horizon`)

Without this step Zuul will return `[]` for `/api/tenants` and the scheduler
log will show `GithubException: 404` when fetching the config-project's
contents.

## 6. (If using forks) `exclude_forks=false`

Zuul's GitHub driver, by default, refuses to monitor any repo whose `fork`
field is `true`. Our test env uses personal forks (`<your-org>/contributor-guide`
is a fork of `openstack/contributor-guide`), so:

```ini
[connection "github.com"]
exclude_forks=false
```

is **mandatory** in `zuul.conf` for this kind of setup. Adding a new fork to
`main.yaml` later does not require changing this — but it does require
restarting the scheduler, and **clearing the ZK branch cache** (the easiest
way is `docker compose down -v && docker compose up -d`, which forces
secret re-encryption — see [zuul-server-bootstrap.md](zuul-server-bootstrap.md)
step 8).

## Reusing an existing App for a new Zuul instance

Two Zuul instances can share one GitHub App. The App's webhook URL points to
exactly one endpoint, so only one of them gets push-driven webhook events;
the other relies on REST API enqueue. That's fine for test environments.

To reuse:

1. Copy `~/zuul-test/etc/zuul/github_app.pem` from the source Zuul to the new
   one.
2. Set the same `app_id` and `webhook_token` in the new `zuul.conf`.
3. Make sure the App is **installed** on every repo your new tenant
   references (re-confirm under App Settings → Install App). Sharing the App
   does not auto-share installs.

The new Zuul will still generate its own per-project encryption keypair —
don't reuse `secrets.yaml` from the source instance verbatim. Re-encrypt
([zuul-server-bootstrap.md](zuul-server-bootstrap.md) step 8).
