#!/usr/bin/env python3
"""Encrypt secrets for a Zuul config-project.

Usage:
    encrypt_secret.py --tenant TENANT --project ORG/REPO \\
        [--zuul-host HOST | --container CONTAINER] \\
        --plaintext VALUE [--plaintext VALUE ...]

The script wraps Zuul's RSA-OAEP-SHA1 chunking and emits YAML chunks ready
to paste into `zuul.d/secrets.yaml`. One `--plaintext` produces one chunk
block.

Why not just `curl /api/tenant/.../key/...pub`?

The Zuul web container caches project public keys. Right after a
`docker compose up` (or `down -v`+`up`) the externally-served key can lag
behind the actual key in ZooKeeper for several seconds. Encrypting against
the stale key produces ciphertext that the scheduler/executor cannot
decrypt, surfacing only at job-run time as `ValueError: Decryption failed`.

To avoid this, prefer `--container` mode: the script runs inside the
scheduler container and fetches the key over the internal docker network
via `http://web:9000`, which always reflects the current state.

Examples:

    # Quick fetch over public API (fine once the server has been up >30s):
    tools/encrypt_secret.py --zuul-host <ZUUL_HOST_IP>:9000 \\
        --tenant i18n-test --project <your-org>/zuul-i18n-config \\
        --plaintext 'wlu_xxxxxxxxxxxx'

    # Reliable: encrypt from inside the running scheduler container:
    tools/encrypt_secret.py --container zuul-test-scheduler-1 \\
        --tenant i18n-test --project <your-org>/zuul-i18n-config \\
        --plaintext 'wlu_xxxxxxxxxxxx'
"""
import argparse
import base64
import shutil
import subprocess
import sys
import textwrap
import urllib.request


def fetch_pubkey_via_http(host: str, tenant: str, project: str) -> bytes:
    url = f"http://{host}/api/tenant/{tenant}/key/{project}.pub"
    with urllib.request.urlopen(url, timeout=10) as r:
        return r.read()


def fetch_pubkey_via_container(container: str, tenant: str, project: str) -> bytes:
    docker = shutil.which("docker") or "docker"
    cmd = [
        "sudo", docker, "exec", container, "curl", "-sf",
        f"http://web:9000/api/tenant/{tenant}/key/{project}.pub",
    ]
    result = subprocess.run(cmd, check=True, capture_output=True)
    return result.stdout


def encrypt(public_key_pem: bytes, plaintext: bytes) -> str:
    """Encrypt with PKCS1-OAEP-SHA1 (Zuul's scheme), chunking if needed."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    pub = serialization.load_pem_public_key(public_key_pem)
    max_chunk = (pub.key_size // 8) - 2 * 20 - 2  # 470 bytes for 4096-bit
    pad = padding.OAEP(
        mgf=padding.MGF1(algorithm=hashes.SHA1()),
        algorithm=hashes.SHA1(),
        label=None,
    )

    lines = []
    for offset in range(0, len(plaintext), max_chunk):
        chunk = plaintext[offset:offset + max_chunk]
        ciphertext_b64 = base64.b64encode(pub.encrypt(chunk, pad)).decode()
        wrapped = textwrap.fill(
            ciphertext_b64,
            width=80,
            initial_indent="        - ",
            subsequent_indent="          ",
        )
        lines.append(wrapped)
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--tenant", required=True)
    p.add_argument("--project", required=True,
                   help="Project slug, e.g. <your-org>/zuul-i18n-config")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--zuul-host",
                     help="HOST:PORT serving the Zuul REST API")
    src.add_argument("--container",
                     help="Docker container name (e.g. zuul-test-scheduler-1)")
    p.add_argument("--plaintext", action="append", required=True,
                   help="Value to encrypt; repeat for multiple values")
    args = p.parse_args()

    if args.zuul_host:
        pubkey = fetch_pubkey_via_http(args.zuul_host, args.tenant, args.project)
    else:
        pubkey = fetch_pubkey_via_container(
            args.container, args.tenant, args.project)

    print(f"# pubkey from "
          f"{args.zuul_host or args.container} "
          f"({args.tenant}/{args.project})", file=sys.stderr)

    for value in args.plaintext:
        print("      <field>: !encrypted/pkcs1-oaep")
        print(encrypt(pubkey, value.encode()))


if __name__ == "__main__":
    main()
