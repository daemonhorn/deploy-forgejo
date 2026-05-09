#!/usr/bin/env python3
"""
Extract the base public key (type + base64) from an SSH certificate blob.

Usage: forgejo-cert-extract.py <base64-cert>
Output: "<key-type> <base64-key>" on stdout, or exits non-zero on failure.

Called by forgejo-keys.sh when AuthorizedKeysCommand receives a certificate
key type (e.g. ecdsa-sha2-nistp384-cert-v01@openssh.com). OpenSSH passes
the full cert blob as %k; we decode it to get the embedded base public key
so Forgejo can look up the user by their registered key fingerprint.
"""
import sys
import base64
import struct
import io


def read_string(bio):
    length_bytes = bio.read(4)
    if len(length_bytes) < 4:
        raise ValueError("truncated")
    (length,) = struct.unpack(">I", length_bytes)
    data = bio.read(length)
    if len(data) < length:
        raise ValueError("truncated")
    return data


def extract_base_key(cert_b64):
    cert_data = base64.b64decode(cert_b64)
    bio = io.BytesIO(cert_data)

    cert_type_bytes = read_string(bio)
    cert_type = cert_type_bytes.decode()

    if not cert_type.endswith("-cert-v01@openssh.com"):
        raise ValueError(f"not a certificate type: {cert_type}")

    base_type = cert_type.replace("-cert-v01@openssh.com", "")

    # Skip nonce
    read_string(bio)

    # Read the key-type-specific public key fields and reassemble wire format.
    def w(s):
        return struct.pack(">I", len(s)) + s

    if base_type.startswith("ecdsa-sha2-"):
        curve = read_string(bio)
        point = read_string(bio)
        key_data = w(base_type.encode()) + w(curve) + w(point)

    elif base_type == "ssh-ed25519":
        pk = read_string(bio)
        key_data = w(b"ssh-ed25519") + w(pk)

    elif base_type in ("ssh-rsa", "rsa-sha2-256", "rsa-sha2-512"):
        e = read_string(bio)
        n = read_string(bio)
        # RSA certs always use ssh-rsa as base key type regardless of sig algorithm.
        key_data = w(b"ssh-rsa") + w(e) + w(n)
        base_type = "ssh-rsa"

    else:
        raise ValueError(f"unsupported base key type: {base_type}")

    return base_type, base64.b64encode(key_data).decode()


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <base64-cert>", file=sys.stderr)
        sys.exit(1)

    try:
        key_type, key_b64 = extract_base_key(sys.argv[1])
        print(f"{key_type} {key_b64}")
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
