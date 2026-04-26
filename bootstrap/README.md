# bootstrap/

Files needed to stand up a fresh Zuul server from scratch. They get copied to
`~/zuul-test/` on the target host. See [docs/zuul-server-bootstrap.md](../docs/zuul-server-bootstrap.md)
for the step-by-step procedure.

## Layout

```
bootstrap/
├── docker-compose.yaml       # 8-container stack (zk, mysql, scheduler,
│                             #   executor, web, launcher, log-server, node)
├── zoo.cfg                   # ZooKeeper TLS config
├── openssl.cnf               # OpenSSL config used by zk-ca.sh
├── zk-ca.sh                  # Generates ZK CA + client/server certs
├── node-Dockerfile           # Optional: ubuntu-jammy container "node"
│                             #   (kept for backwards compat — can be dropped
│                             #    if you only use a real worker VM)
├── etc/
│   ├── zuul/
│   │   ├── logging.conf
│   │   ├── zuul.conf.example   # → copy to zuul.conf and fill placeholders
│   │   └── main.yaml.example   # → copy to main.yaml and fill placeholders
│   ├── nodepool/
│   │   └── nodepool.yaml.example
│   └── nginx/
│       └── default.conf      # log-server: serves .gz with proper headers
└── patches/
    ├── README.md             # explains why graphql_init.py is needed
    └── graphql_init.py       # null-safety patch for Zuul's GitHub graphql
```

## Files NOT in this directory (you must provide them)

| Where | What | How |
|-------|------|-----|
| `~/zuul-test/etc/zuul/github_app.pem` | GitHub App private key | Download from GitHub App settings — see [docs/github-app-setup.md](../docs/github-app-setup.md) |
| `~/zuul-test/keys/{nodepool,zuul}_rsa{,.pub}` | SSH keys | `ssh-keygen -t rsa -b 4096 -f nodepool_rsa -N "" && ssh-keygen -t rsa -b 4096 -f zuul_rsa -N ""` |
| `~/zuul-test/certs/` | ZK TLS CA bundle | `./zk-ca.sh ./certs zk` |

## Placeholder substitutions

The `.example` files contain placeholders that the bootstrap procedure will
substitute. Each placeholder appears in only one file, so search-and-replace
is safe:

| Placeholder | File | What it is |
|-------------|------|------------|
| `<ZUUL_HOST_IP>` | zuul.conf.example | Public IP/hostname of the Zuul server (appears twice) |
| `<GITHUB_APP_ID>` | zuul.conf.example | GitHub App numeric ID |
| `<GITHUB_WEBHOOK_TOKEN>` | zuul.conf.example | Webhook secret you set when creating the App |
| `<ZUUL_OPERATOR_SECRET>` | zuul.conf.example | HS256 secret for `zuul create-auth-token` (treat as a credential) |
| `<TENANT_NAME>` | main.yaml.example | e.g. `i18n-test` |
| `<CONFIG_PROJECT>` | main.yaml.example | `org/repo` of your single-branch config fork |
| `<UNTRUSTED_PROJECT_*>` | main.yaml.example | Source repos that trigger jobs |
| `<WORKER_INTERNAL_IP>` | nodepool.yaml.example | IP of the worker VM reachable from the Zuul host |
