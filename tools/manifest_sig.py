"""Signs the update manifest's platform entries with the release key (Ed25519), so the apps install only files the
owner published — not whatever a changed latest.json points to.

The signed text of one entry (the apps build the same text and check it with the public key built into them):
    maskoret-update-v1\n<platform>\n<version>\n<build>\n<sha256>
The private key: $MANIFEST_SIGNING_KEY (PEM, the GitHub secret in release.yml), or the file in
$MANIFEST_SIGNING_KEY_FILE, or חשוב/maskoret-manifest-signing.pem on the owner's Mac. Signing uses OpenSSL 3+.
"""
import base64
import os
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUBLIC_KEY = "9W2HCLmnyplrC3gRqnhXipbtU5z5rJJmPLM4xCo96B0="


def message(platform, entry):
    return f"maskoret-update-v1\n{platform}\n{entry['version']}\n{entry['build']}\n{entry['sha256'].lower()}"


def _openssl():
    for path in ("/opt/homebrew/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"):
        if os.path.exists(path):
            return path
    return shutil.which("openssl") or "openssl"


def _key_file(work):
    pem = os.environ.get("MANIFEST_SIGNING_KEY", "").strip()
    if pem:
        path = os.path.join(work, "key.pem")
        with open(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600), "w") as f:
            f.write(pem + "\n")
        return path
    path = os.environ.get("MANIFEST_SIGNING_KEY_FILE") or os.path.join(ROOT, "חשוב", "maskoret-manifest-signing.pem")
    if not os.path.exists(path):
        raise SystemExit("Missing the manifest signing key (MANIFEST_SIGNING_KEY) — the apps would refuse the update.")
    return path


def sign(platform, entry):
    """Returns the entry with its "sig" (base64 of the 64-byte Ed25519 signature)."""
    with tempfile.TemporaryDirectory() as work:
        key = _key_file(work)
        msg = os.path.join(work, "msg")
        with open(msg, "w", encoding="utf-8") as f:
            f.write(message(platform, entry))
        raw = subprocess.run([_openssl(), "pkeyutl", "-sign", "-rawin", "-inkey", key, "-in", msg],
                             check=True, capture_output=True).stdout
        if len(raw) != 64:
            raise SystemExit("OpenSSL did not return an Ed25519 signature (needs OpenSSL 3+).")
        pub = subprocess.run([_openssl(), "pkey", "-in", key, "-pubout", "-outform", "DER"],
                             check=True, capture_output=True).stdout[-32:]
        if base64.b64encode(pub).decode() != PUBLIC_KEY:
            raise SystemExit("The signing key does not match the public key built into the apps.")
    return {**entry, "sig": base64.b64encode(raw).decode()}
