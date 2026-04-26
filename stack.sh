#!/usr/bin/env bash
# stack.sh — one-command Zuul test environment bootstrap.
#
# Usage:
#   ./stack.sh                  # equivalent to `./stack.sh up`
#   ./stack.sh up               # full bootstrap (idempotent)
#   ./stack.sh down             # destroy stack + ZK/MariaDB volumes (DESTRUCTIVE)
#   ./stack.sh status           # show container health + tenant API
#   ./stack.sh encrypt-secrets  # re-emit encrypted secrets (after the stack is up)
#
# Reads ./local.conf for site-specific values. See local.conf.sample.

set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${_DIR}/local.conf"
SECRETS_OUT="${_DIR}/local-secrets.yaml"

log()  { printf '\033[1;34m[stack]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[stack]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[stack]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

load_conf() {
    [[ -f "$CONF" ]] || die "local.conf not found. Copy local.conf.sample → local.conf and fill it in."
    # shellcheck disable=SC1090
    source "$CONF"

    : "${ZUUL_HOST_IP:?ZUUL_HOST_IP not set in local.conf}"
    : "${ZUUL_HOST_USER:?}"
    : "${ZUUL_HOST_SSH_KEY:?}"
    : "${TENANT_NAME:?}"
    : "${CONFIG_PROJECT:?}"
    : "${GITHUB_APP_ID:?}"
    : "${GITHUB_APP_PEM:?}"
    : "${GITHUB_WEBHOOK_TOKEN:?}"
    : "${ZUUL_OPERATOR_SECRET:?}"
    : "${UNTRUSTED_PROJECTS_YAML:?}"
    CONFIG_PROJECT_BRANCH="${CONFIG_PROJECT_BRANCH:-main}"
    SKIP_WORKER="${SKIP_WORKER:-0}"

    if [[ "$SKIP_WORKER" -eq 0 ]]; then
        : "${WORKER_HOST_IP:?WORKER_HOST_IP not set (or set SKIP_WORKER=1)}"
        : "${WORKER_INTERNAL_IP:?}"
        : "${WORKER_USER:?}"
        : "${WORKER_SSH_KEY:?}"
    fi

    # Expand ~ in paths
    GITHUB_APP_PEM="${GITHUB_APP_PEM/#\~/$HOME}"
    ZUUL_HOST_SSH_KEY="${ZUUL_HOST_SSH_KEY/#\~/$HOME}"
    [[ "${WORKER_SSH_KEY:-}" ]] && WORKER_SSH_KEY="${WORKER_SSH_KEY/#\~/$HOME}"
}

# ---------- SSH helpers ----------
zssh()    { ssh -i "$ZUUL_HOST_SSH_KEY" -o StrictHostKeyChecking=no \
                "$ZUUL_HOST_USER@$ZUUL_HOST_IP" "$@"; }
zscp_to() { scp -i "$ZUUL_HOST_SSH_KEY" -o StrictHostKeyChecking=no -q \
                "$@" "$ZUUL_HOST_USER@$ZUUL_HOST_IP:$DEST"; }
wssh()    { ssh -i "$WORKER_SSH_KEY" -o StrictHostKeyChecking=no \
                "$WORKER_USER@$WORKER_HOST_IP" "$@"; }

# ---------- preflight ----------
preflight() {
    log "Pre-flight checks"
    [[ -f "$GITHUB_APP_PEM" ]] || die "GitHub App PEM not found at $GITHUB_APP_PEM"
    [[ -d "$_DIR/bootstrap" ]] || die "bootstrap/ directory missing"
    zssh true || die "Cannot SSH to Zuul host $ZUUL_HOST_IP as $ZUUL_HOST_USER"
    [[ "$SKIP_WORKER" -eq 0 ]] && { wssh true || die "Cannot SSH to worker $WORKER_HOST_IP"; }
    command -v python3 >/dev/null || die "python3 required locally for secret encryption"
    log "Pre-flight OK"
}

# ---------- 1. Docker on the Zuul host ----------
install_docker() {
    if zssh 'command -v docker >/dev/null && docker compose version >/dev/null 2>&1'; then
        log "Docker + compose already installed on Zuul host (skipping)"
        return
    fi
    log "Installing Docker on Zuul host (this may take a minute)"
    zssh '
        set -e
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
        sudo usermod -aG docker '"$ZUUL_HOST_USER"' || true
    '
}

# ---------- 2. Stage bootstrap files ----------
stage_files() {
    log "Staging bootstrap files to ~/zuul-test/"
    zssh 'mkdir -p ~/zuul-test/{etc/zuul,etc/nodepool,etc/nginx,certs,keys,patches,logs}'
    DEST='~/zuul-test/'           zscp_to "$_DIR/bootstrap/docker-compose.yaml" \
                                          "$_DIR/bootstrap/zoo.cfg" \
                                          "$_DIR/bootstrap/openssl.cnf" \
                                          "$_DIR/bootstrap/zk-ca.sh" \
                                          "$_DIR/bootstrap/node-Dockerfile"
    DEST='~/zuul-test/etc/zuul/'  zscp_to "$_DIR/bootstrap/etc/zuul/logging.conf"
    DEST='~/zuul-test/etc/nginx/' zscp_to "$_DIR/bootstrap/etc/nginx/default.conf"
    DEST='~/zuul-test/patches/'   zscp_to "$_DIR/bootstrap/patches/graphql_init.py"
    zssh 'chmod +x ~/zuul-test/zk-ca.sh'
}

# ---------- 3. ZK CA + SSH keys ----------
gen_certs() {
    if zssh 'test -f ~/zuul-test/certs/certs/cacert.pem'; then
        log "ZK CA already exists (skipping)"
        return
    fi
    log "Generating ZooKeeper CA + server/client certs"
    zssh 'cd ~/zuul-test && ./zk-ca.sh ./certs zk' >/dev/null
}

gen_ssh_keys() {
    if zssh 'test -f ~/zuul-test/keys/nodepool_rsa'; then
        log "SSH keys already exist (skipping)"
    else
        log "Generating nodepool_rsa + zuul_rsa"
        zssh '
            cd ~/zuul-test/keys
            ssh-keygen -t rsa -b 4096 -f nodepool_rsa -N "" -C "nodepool@zuul-test" -q
            ssh-keygen -t rsa -b 4096 -f zuul_rsa -N "" -C "zuul@zuul-test" -q
        '
    fi
}

# ---------- 4. GitHub App private key ----------
place_pem() {
    log "Uploading GitHub App private key"
    DEST='~/zuul-test/etc/zuul/github_app.pem' zscp_to "$GITHUB_APP_PEM"
    zssh 'chmod 600 ~/zuul-test/etc/zuul/github_app.pem'
}

# ---------- 5. Render config templates ----------
render_configs() {
    log "Rendering config templates with site values"
    local tmp; tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    # zuul.conf — straight sed substitution
    sed -e "s|<ZUUL_HOST_IP>|$ZUUL_HOST_IP|g" \
        -e "s|<GITHUB_APP_ID>|$GITHUB_APP_ID|g" \
        -e "s|<GITHUB_WEBHOOK_TOKEN>|$GITHUB_WEBHOOK_TOKEN|g" \
        -e "s|<ZUUL_OPERATOR_SECRET>|$ZUUL_OPERATOR_SECRET|g" \
        "$_DIR/bootstrap/etc/zuul/zuul.conf.example" > "$tmp/zuul.conf"

    # main.yaml — emitted from scratch (the .example file's structure is fixed)
    cat > "$tmp/main.yaml" <<EOF
- tenant:
    name: $TENANT_NAME
    source:
      github.com:
        config-projects:
          - $CONFIG_PROJECT:
              load-branch: $CONFIG_PROJECT_BRANCH
        untrusted-projects:
$UNTRUSTED_PROJECTS_YAML
EOF

    # nodepool.yaml
    sed -e "s|<WORKER_INTERNAL_IP>|$WORKER_INTERNAL_IP|g" \
        "$_DIR/bootstrap/etc/nodepool/nodepool.yaml.example" > "$tmp/nodepool.yaml"

    DEST='~/zuul-test/etc/zuul/'     zscp_to "$tmp/zuul.conf" "$tmp/main.yaml"
    DEST='~/zuul-test/etc/nodepool/' zscp_to "$tmp/nodepool.yaml"
}

# ---------- 6. Worker node prep ----------
prep_worker() {
    if [[ "$SKIP_WORKER" -ne 0 ]]; then
        warn "SKIP_WORKER=1 — leaving worker unmanaged"
        return
    fi
    log "Provisioning worker $WORKER_HOST_IP (apt + locale + PEP668)"
    wssh '
        set -e
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3-virtualenv python3-pip python3-venv \
            gettext locales \
            python3-sphinx python3-babel python3-requests python3-openstackdocstheme
        sudo locale-gen en_US.UTF-8 >/dev/null
        mkdir -p ~/.config/pip
        printf "[global]\nbreak-system-packages = true\n" > ~/.config/pip/pip.conf
    '
    log "Installing nodepool pubkey on worker"
    local pubkey
    pubkey=$(zssh 'cat ~/zuul-test/keys/nodepool_rsa.pub')
    wssh "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        grep -qxF '$pubkey' ~/.ssh/authorized_keys || echo '$pubkey' >> ~/.ssh/authorized_keys
    "
}

# ---------- 7. Bring the stack up ----------
compose_up() {
    log "Bringing stack up (docker compose up -d)"
    zssh 'cd ~/zuul-test && sudo docker compose up -d' | tail -20
    log "Waiting for /api/tenants to respond"
    zssh 'until curl -sf http://localhost:9000/api/tenants >/dev/null; do sleep 3; done'
    log "Stack ready"
    zssh 'sudo docker ps --format "table {{.Names}}\t{{.Status}}"'
    zssh "curl -s http://localhost:9000/api/tenants"
    echo
}

# ---------- 8. Encrypt user-provided plaintext secrets (optional) ----------
encrypt_secrets() {
    local have_any=0
    [[ -n "${WEBLATE_API_TOKEN:-}" ]] && have_any=1
    [[ -n "${GITHUB_PAT:-}" ]] && have_any=1
    if [[ $have_any -eq 0 ]]; then
        warn "No plaintext secrets provided in local.conf — skipping encryption."
        warn "When you have them, edit local.conf and rerun: ./stack.sh encrypt-secrets"
        return
    fi

    log "Encrypting user secrets via the running scheduler container"
    : > "$SECRETS_OUT"

    local enc_url="" enc_wlt="" enc_gh=""
    if [[ -n "${WEBLATE_API_URL:-}" && -n "${WEBLATE_API_TOKEN:-}" ]]; then
        enc_url=$(remote_encrypt "$WEBLATE_API_URL")
        enc_wlt=$(remote_encrypt "$WEBLATE_API_TOKEN")
        cat >> "$SECRETS_OUT" <<EOF
- secret:
    name: weblate_api_credentials
    data:
      url: !encrypted/pkcs1-oaep
$enc_url
      token: !encrypted/pkcs1-oaep
$enc_wlt

EOF
    fi
    if [[ -n "${GITHUB_PAT:-}" ]]; then
        enc_gh=$(remote_encrypt "$GITHUB_PAT")
        cat >> "$SECRETS_OUT" <<EOF
- secret:
    name: github_credentials
    data:
      token: !encrypted/pkcs1-oaep
$enc_gh
EOF
    fi

    log "Encrypted secrets written to $SECRETS_OUT"
    log "Next step: copy this content into your config-project's zuul.d/secrets.yaml,"
    log "  commit on the '$CONFIG_PROJECT_BRANCH' branch of $CONFIG_PROJECT, and push."
    log "  Then: ssh $ZUUL_HOST_USER@$ZUUL_HOST_IP 'sudo docker restart zuul-test-scheduler-1 zuul-test-executor-1'"
}

remote_encrypt() {
    # Encrypts via the scheduler container so we always use the live pubkey
    # (avoids the web-cache stale-key pitfall — see tools/encrypt_secret.py).
    local plaintext="$1"
    zssh "sudo docker exec -i zuul-test-scheduler-1 python3 -c \"
import sys, base64, textwrap
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
import requests
r = requests.get('http://web:9000/api/tenant/$TENANT_NAME/key/$CONFIG_PROJECT.pub')
pub = serialization.load_pem_public_key(r.text.encode())
data = sys.stdin.buffer.read()
pad = padding.OAEP(mgf=padding.MGF1(hashes.SHA1()), algorithm=hashes.SHA1(), label=None)
mc = (pub.key_size//8) - 2*20 - 2
out = []
for i in range(0, len(data), mc):
    b = base64.b64encode(pub.encrypt(data[i:i+mc], pad)).decode()
    out.append(textwrap.fill(b, 80,
        initial_indent='        - ', subsequent_indent='          '))
print('\n'.join(out))
\"" <<<"$plaintext"
}

# ---------- subcommands ----------
cmd_up() {
    load_conf
    preflight
    install_docker
    stage_files
    gen_certs
    gen_ssh_keys
    place_pem
    render_configs
    prep_worker
    compose_up
    encrypt_secrets
    log "Done."
    log "Web UI:  http://$ZUUL_HOST_IP:9000/"
    log "Logs:    http://$ZUUL_HOST_IP:8088/"
}

cmd_down() {
    load_conf
    warn "This will run 'docker compose down -v' on $ZUUL_HOST_IP."
    warn "ZK and MariaDB volumes will be DELETED, and Zuul will regenerate the"
    warn "config-project encryption keypair on next 'up' — secrets must be"
    warn "re-encrypted and re-pushed."
    read -r -p "Continue? [yes/N] " ans
    [[ "$ans" == "yes" ]] || { log "Aborted"; exit 0; }
    zssh 'cd ~/zuul-test && sudo docker compose down -v'
    log "Stack torn down. Run './stack.sh up' to rebuild."
}

cmd_status() {
    load_conf
    log "Containers:"
    zssh 'sudo docker ps --format "table {{.Names}}\t{{.Status}}"' || die "SSH failed"
    log "Tenants:"
    curl -s "http://$ZUUL_HOST_IP:9000/api/tenants" || die "API not reachable"
    echo
}

cmd_encrypt_secrets() {
    load_conf
    encrypt_secrets
}

case "${1:-up}" in
    up)              cmd_up ;;
    down)            cmd_down ;;
    status)          cmd_status ;;
    encrypt-secrets) cmd_encrypt_secrets ;;
    -h|--help|help)
        sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
        exit 0
        ;;
    *)  die "Unknown subcommand: $1 (try 'help')" ;;
esac
