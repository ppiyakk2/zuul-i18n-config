# Zuul Server Bootstrap

How to bring up a fresh Zuul + Nodepool stack on a clean Ubuntu 24.04 VM,
end-to-end. The artefacts referenced here live in [`bootstrap/`](../bootstrap/).

The reference test environment was built with these steps; the existing
`<ZUUL_HOST_IP>` server is identical to what this document produces.

## One-command bootstrap (recommended)

Once the prerequisites in "[What you need before starting](#what-you-need-before-starting)"
are in place, the entire procedure collapses to:

```bash
cp local.conf.sample local.conf      # at the repo root
$EDITOR local.conf                   # fill in IPs, App credentials, tenant, projects
./stack.sh                           # idempotent — safe to re-run
```

`stack.sh` orchestrates everything described in the manual procedure below.
Subcommands:

| Command | Effect |
|---------|--------|
| `./stack.sh` (or `up`) | Full bootstrap: Docker → certs/keys → configs → worker → `docker compose up` → secret encryption |
| `./stack.sh down` | `docker compose down -v` (DESTRUCTIVE — wipes ZK + DB volumes; secrets must be re-encrypted on next `up`) |
| `./stack.sh status` | Container health + `/api/tenants` |
| `./stack.sh encrypt-secrets` | Re-emit `local-secrets.yaml` from current plaintext values in `local.conf` (after the stack is up) |

The script never pushes commits to your config-project — it only emits an
encrypted `local-secrets.yaml` for you to paste into your fork's
`zuul.d/secrets.yaml` and push manually (so a runaway `stack.sh` cannot
overwrite real production secrets).

The rest of this document explains each phase in detail; read on if you want
to understand what `stack.sh` is doing, debug failures, or run individual
phases by hand.

---

## Manual procedure (for understanding/debugging)

## What you need before starting

| Resource | Notes |
|----------|-------|
| Ubuntu 24.04 VM, 2+ vCPU, 4+ GB RAM, public IP | Will host the Zuul stack |
| Worker VM (Ubuntu 24.04) reachable on private/public IP | See [remote-node-setup.md](remote-node-setup.md). Can be the same VM only for smoke testing |
| GitHub App | See [github-app-setup.md](github-app-setup.md). You need: `app_id`, the `.pem` private key, a webhook secret string |
| A **dedicated** GitHub fork to use as the Zuul config-project | See "[Why a dedicated config-project fork](#why-a-dedicated-config-project-fork)" below — do not reuse another Zuul instance's config-project |
| GitHub repos to monitor as untrusted-projects | The source repos that fire jobs |
| SSH access to the Zuul VM as a user with `sudo` | All commands assume `ubuntu` |

## 1. Install Docker on the Zuul host

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ubuntu
# Re-login so the docker group takes effect, or prefix all commands with sudo.
```

Verify:

```bash
docker --version            # 27+ tested
docker compose version      # v2.30+ tested
```

## 2. Stage bootstrap files on the host

Clone or copy this repo to your workstation, then push the `bootstrap/` tree
to the host:

```bash
# On your workstation:
ssh ubuntu@<ZUUL_HOST_IP> 'mkdir -p ~/zuul-test/{etc/zuul,etc/nodepool,etc/nginx,certs,keys,patches,logs}'
cd zuul-i18n-config/bootstrap
scp docker-compose.yaml zoo.cfg openssl.cnf zk-ca.sh node-Dockerfile \
    ubuntu@<ZUUL_HOST_IP>:~/zuul-test/
scp etc/zuul/logging.conf  ubuntu@<ZUUL_HOST_IP>:~/zuul-test/etc/zuul/
scp etc/nginx/default.conf ubuntu@<ZUUL_HOST_IP>:~/zuul-test/etc/nginx/
scp patches/graphql_init.py ubuntu@<ZUUL_HOST_IP>:~/zuul-test/patches/
```

## 3. Generate ZooKeeper TLS certificates

ZooKeeper inside the stack uses mTLS. Generate the CA and server/client certs:

```bash
# On the Zuul host:
cd ~/zuul-test
chmod +x zk-ca.sh
./zk-ca.sh ./certs zk
```

This produces:

```
certs/certs/{cacert,client,zk}.pem
certs/keys/{clientkey,zkkey}.pem
certs/keystores/zk.pem
```

The certs have a 10-year validity. Re-run only when rotating.

## 4. Generate SSH key pairs

Two key pairs:

* `nodepool_rsa` — used by the executor to SSH into worker nodes. The public
  key is installed on every worker.
* `zuul_rsa` — used by Zuul jobs to push commits back to GitHub via SSH (only
  needed if you switch propose jobs from the GitHub REST API to git+ssh).

```bash
cd ~/zuul-test/keys
ssh-keygen -t rsa -b 4096 -f nodepool_rsa -N ""
ssh-keygen -t rsa -b 4096 -f zuul_rsa -N ""
```

Install the nodepool public key on every worker:

```bash
cat ~/zuul-test/keys/nodepool_rsa.pub | \
    ssh ubuntu@<WORKER_IP> 'cat >> ~/.ssh/authorized_keys'
```

## 5. Place the GitHub App private key

Copy the `.pem` you downloaded when creating the GitHub App
([github-app-setup.md](github-app-setup.md)) to the host:

```bash
scp github_app.pem ubuntu@<ZUUL_HOST_IP>:~/zuul-test/etc/zuul/github_app.pem
ssh ubuntu@<ZUUL_HOST_IP> 'chmod 600 ~/zuul-test/etc/zuul/github_app.pem'
```

## 6. Fill in the config templates

```bash
# On the Zuul host:
cd ~/zuul-test/etc
cp zuul/zuul.conf.example       zuul/zuul.conf
cp zuul/main.yaml.example       zuul/main.yaml
cp nodepool/nodepool.yaml.example nodepool/nodepool.yaml
```

(The `.example` files come from `bootstrap/etc/...` — scp them in step 2 if
you didn't already.)

Replace placeholders. Each placeholder appears in exactly one file:

Each placeholder appears in exactly one file. Substitute with your real
values (the examples below use RFC 5737 documentation addresses and a
fake App ID — replace with yours):

```bash
# zuul.conf
sed -i 's|<ZUUL_HOST_IP>|203.0.113.10|g'           zuul/zuul.conf
sed -i 's|<GITHUB_APP_ID>|123456|'                 zuul/zuul.conf
sed -i 's|<GITHUB_WEBHOOK_TOKEN>|change-me|'       zuul/zuul.conf
sed -i 's|<ZUUL_OPERATOR_SECRET>|change-this-too|' zuul/zuul.conf

# main.yaml
sed -i 's|<TENANT_NAME>|i18n-test|'                zuul/main.yaml
sed -i 's|<CONFIG_PROJECT>|your-org/zuul-i18n-config|' zuul/main.yaml
# Hand-edit the `<UNTRUSTED_PROJECT_*>` lines.

# nodepool.yaml
sed -i 's|<WORKER_INTERNAL_IP>|192.0.2.20|'        nodepool/nodepool.yaml
```

> **Production:** also change `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`,
> `[keystore].password` in `docker-compose.yaml` / `zuul.conf`. They ship with
> dev defaults (`rootpassword`, `secret`).

## 7. Bring the stack up

```bash
cd ~/zuul-test
docker compose up -d
```

Wait for readiness:

```bash
until curl -sf http://localhost:9000/api/tenants > /dev/null; do sleep 3; done
docker ps
curl -s http://localhost:9000/api/tenants  # → [{"name":"i18n-test"}]
```

If `tenants` returns `[]`, check `docker logs zuul-test-scheduler-1` — usually
the GitHub App lacks access to the config-project, or `main.yaml` syntax is
off.

## 8. Encrypt secrets and push them to the config-project

Zuul has now generated a project-specific RSA keypair for your config-project
(stored in ZooKeeper). Encrypt all secrets against the **public** half before
committing them to `zuul.d/secrets.yaml`.

We provide a helper that handles the chunking and the `web` cache pitfall:

```bash
# On your workstation, with the new Zuul host reachable:
tools/encrypt_secret.py \
    --container zuul-test-scheduler-1 \
    --tenant i18n-test \
    --project <your-org>/zuul-i18n-config \
    --plaintext 'https://weblate.example.com/api/' \
    --plaintext 'wlu_xxxxxxxxxxxxxxx'
```

Paste the output blocks into `zuul.d/secrets.yaml` (the helper emits one
`<field>: !encrypted/pkcs1-oaep` block per `--plaintext`; rename `<field>` to
`url`, `token`, etc. as appropriate).

> **Why `--container` and not `--zuul-host`:** right after a `docker compose
> up` (or any `down -v`+`up`), the public Zuul Web cache can serve a stale
> public key for ~30 seconds. Encrypting against that stale key produces
> ciphertext the scheduler can't decrypt — and the failure only surfaces at
> job-run time as `ValueError: Decryption failed`. `--container` queries
> `http://web:9000` from inside the docker network, which bypasses the
> external cache. Use `--zuul-host` only after the server has been stable for
> a while.

Commit and push to your config-project's single branch (typically `main`):

```bash
cd ~/your-config-fork
git add zuul.d/secrets.yaml
git commit -m "Initial encrypted secrets"
git push
```

Restart the scheduler so it re-reads the project layout:

```bash
docker restart zuul-test-scheduler-1 zuul-test-executor-1
```

Confirm no `Decryption failed` warnings:

```bash
docker logs --since 30s zuul-test-scheduler-1 | grep -E "Decryption|priming"
# Expect: only "Config priming complete" — no "Decryption failed" lines.
```

## 9. Smoke-test with a manual enqueue

GitHub webhooks may be blocked by your security group. The REST API works
regardless:

```bash
COMMIT=$(git ls-remote https://github.com/<org>/<source-repo>.git refs/heads/master | awk '{print $1}')

ssh ubuntu@<ZUUL_HOST_IP> "
TOKEN=\$(docker exec zuul-test-scheduler-1 zuul create-auth-token \
    --auth-config zuul_operator --tenant i18n-test --user admin 2>/dev/null | head -1)
docker exec zuul-test-scheduler-1 curl -s -X POST \
    'http://web:9000/api/tenant/i18n-test/project/<org>/<source-repo>/enqueue' \
    -H \"Authorization: \$TOKEN\" -H 'Content-Type: application/json' \
    -d '{\"trigger\":\"zuul\",\"pipeline\":\"post\",\"ref\":\"refs/heads/master\",
        \"newrev\":\"$COMMIT\",
        \"oldrev\":\"0000000000000000000000000000000000000000\"}'
"
```

`true` means accepted. Watch the build:

```bash
curl -s "http://<ZUUL_HOST_IP>:9000/api/tenant/i18n-test/builds?project=<org>/<source-repo>&limit=1" \
    | python3 -m json.tool
```

A `result: SUCCESS` means the bootstrap is complete. `RETRY_LIMIT` with no
log_url usually means decryption is still failing — re-check step 8.

## Why a dedicated config-project fork

A Zuul tenant **must** have exclusive ownership of its config-project's
ref space. If two Zuul instances share the same config-project repo, you
can't make either work without breaking the other:

* Each instance generates its own RSA keypair for the project. Re-encrypting
  `secrets.yaml` for instance B invalidates instance A's ability to decrypt.
* Even with `load-branch: <only-mine>` set in `main.yaml`, Zuul's tenant
  parser **still cats every branch's `zuul.d/`** (verified on Zuul 14.x)
  and tries to validate the layout. Secrets encrypted with the other
  instance's key produce `Decryption failed` warnings during config priming
  and `RETRY_LIMIT` at run time.
* `include-branches: [...]` in `main.yaml` does not change this behavior on
  Zuul 14.x.

So: **one Zuul instance = one config-project fork = one branch (typically
`main`)**. If you need a second test environment, fork the repo into a new
namespace (e.g. `cloudlikejs/zuul-i18n-config-tst`) and point the new
instance's `main.yaml` at that fork.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `[]` from `/api/tenants` | GitHub App can't read the config-project, or `main.yaml` parse error | Check `docker logs zuul-test-scheduler-1` for `GithubException` or YAML errors |
| `Decryption failed` in scheduler logs at priming | Stale `web` pubkey cache, or sharing config-project with another Zuul instance | Re-encrypt with `--container`; use a dedicated fork |
| Job ends `RETRY_LIMIT` in <5s with no log_url | Same as above — secrets failed to decrypt at job-prep time | Same |
| Build is `RETRY` then `RETRY_LIMIT` after node assignment | Worker SSH key not installed, or worker can't be reached at the IP in `nodepool.yaml` | `ssh -i ~/zuul-test/keys/nodepool_rsa ubuntu@<WORKER_IP>` from the Zuul host |
| `Waiting on logger` shown forever in job-output | `zuul_console` not started on the worker | Confirm `playbooks/base/pre.yaml` runs `zuul_console:` task; check executor logs |
| New branches/forks not picked up by Zuul | ZK branch cache stale | `docker compose down -v && docker compose up -d` (note: this **regenerates the project keypair** — you must re-encrypt and push secrets again) |

## What state lives where

Knowing this matters when something needs reset:

| State | Location | Survives `docker restart` | Survives `down -v` |
|-------|----------|---------------------------|---------------------|
| Pipeline/job/secret config | GitHub config-project | yes | yes |
| Project encryption keypair | ZooKeeper (`zk-data` volume) | yes | **no — regenerated** |
| Branch cache, ongoing build state | ZooKeeper | yes | no |
| Build history | MariaDB (`mysql-data` volume) | yes | no |
| Logs | `~/zuul-test/logs/` (host bind) | yes | yes |
| Generated RSA SSH keys for nodepool/zuul | `~/zuul-test/keys/` (host bind) | yes | yes |
| ZK TLS CA | `~/zuul-test/certs/` (host bind) | yes | yes |
| GitHub App private key | `~/zuul-test/etc/zuul/github_app.pem` | yes | yes |

`down -v` is the nuclear option — destroys ZK + DB volumes and forces
secrets re-encryption. Use only on cold/dev environments.
