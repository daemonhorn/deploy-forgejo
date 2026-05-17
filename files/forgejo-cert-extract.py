#!/usr/bin/env python3
"""
Extract the base public key (type + base64) from an SSH certificate blob.

Usage: forgejo-cert-extract.py <base64-cert>
Output: "<key-type> <base64-key>" on stdout, or exits non-zero on failure.

Called by forgejo-keys.sh when AuthorizedKeysCommand receives a certificate
key type (e.g. ecdsa-sha2-nistp384-cert-v01@openssh.com). OpenSSH passes
the full cert blob as %k; we decode it to get the embedded base public key
so Forgejo can look up the user by their registered key fingerprint.

Debug: set FORGEJO_KEYS_DEBUG=1 in the environment for verbose per-field
cert parsing traces on stderr (viewed via: journalctl -t forgejo-auth).
"""
import os
import sys
import base64
import struct
import io
import traceback

DEBUG = os.environ.get("FORGEJO_KEYS_DEBUG", "0") == "1"


def _dbg(msg):
    if DEBUG:
        print(f"[cert-extract] {msg}", file=sys.stderr)


def read_string(bio):
    length_bytes = bio.read(4)
    if len(length_bytes) < 4:
        raise ValueError("truncated length prefix")
    (length,) = struct.unpack(">I", length_bytes)
    data = bio.read(length)
    if len(data) < length:
        raise ValueError(f"truncated data: expected {length} bytes, got {len(data)}")
    return data


def extract_base_key(cert_b64):
    try:
        cert_data = base64.b64decode(cert_b64)
    except Exception as exc:
        raise ValueError(f"base64 decode failed (input_len={len(cert_b64)}): {exc}") from exc

    _dbg(f"blob_bytes={len(cert_data)} b64_chars={len(cert_b64)}")
    bio = io.BytesIO(cert_data)

    cert_type_bytes = read_string(bio)
    cert_type = cert_type_bytes.decode()
    _dbg(f"cert_type={cert_type!r}")

    if not cert_type.endswith("-cert-v01@openssh.com"):
        raise ValueError(f"not a certificate type: {cert_type!r}")

    base_type = cert_type.replace("-cert-v01@openssh.com", "")
    _dbg(f"base_type={base_type!r}")

    # Skip nonce (32 bytes for ed25519/ecdsa; present in all cert types)
    nonce = read_string(bio)
    _dbg(f"nonce_len={len(nonce)}")

    # Read the key-type-specific public key fields and reassemble wire format.
    def w(s):
        return struct.pack(">I", len(s)) + s

    if base_type.startswith("ecdsa-sha2-"):
        curve = read_string(bio)
        point = read_string(bio)
        _dbg(f"ecdsa curve={curve!r} point_len={len(point)}")
        key_data = w(base_type.encode()) + w(curve) + w(point)

    elif base_type == "ssh-ed25519":
        pk = read_string(bio)
        _dbg(f"ed25519 pk_len={len(pk)}")
        key_data = w(b"ssh-ed25519") + w(pk)

    elif base_type in ("ssh-rsa", "rsa-sha2-256", "rsa-sha2-512"):
        e = read_string(bio)
        n = read_string(bio)
        _dbg(f"rsa e_len={len(e)} n_len={len(n)}")
        # RSA certs always use ssh-rsa as base key type regardless of sig algorithm.
        key_data = w(b"ssh-rsa") + w(e) + w(n)
        base_type = "ssh-rsa"

    else:
        raise ValueError(f"unsupported base key type: {base_type!r}")

    result_b64 = base64.b64encode(key_data).decode()
    _dbg(f"result base_type={base_type} key_b64_len={len(result_b64)}")
    return base_type, result_b64


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <base64-cert>", file=sys.stderr)
        sys.exit(1)

    cert_b64 = sys.argv[1]
    try:
        key_type, key_b64 = extract_base_key(cert_b64)
        print(f"{key_type} {key_b64}")
    except Exception as exc:
        print(
            f"error: {type(exc).__name__}: {exc} (blob_b64_len={len(cert_b64)})",
            file=sys.stderr,
        )
        if DEBUG:
            traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
