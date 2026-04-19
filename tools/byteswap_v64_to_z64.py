#!/usr/bin/env python3
"""Byteswap an N64 ROM from .v64 (byte-pair swapped) to .z64 (big-endian native)."""
import sys
import hashlib
from pathlib import Path

EXPECTED_SHA1_US_Z64 = "9bef1128717f958171a4afac3ed78ee2bb4e86ce"
Z64_MAGIC = bytes.fromhex("80371240")


def byteswap_pairs(data: bytes) -> bytes:
    if len(data) % 2 != 0:
        raise ValueError("ROM length not divisible by 2")
    out = bytearray(len(data))
    out[0::2] = data[1::2]
    out[1::2] = data[0::2]
    return bytes(out)


def main(src: str, dst: str) -> int:
    src_path = Path(src)
    dst_path = Path(dst)
    data = src_path.read_bytes()
    print(f"Read {len(data)} bytes from {src_path}")

    magic = data[:4]
    if magic == Z64_MAGIC:
        print("Already z64 (big-endian). Copying.")
        out = data
    elif magic == bytes.fromhex("37804012"):
        print("Detected v64 (byte-pair swapped). Swapping.")
        out = byteswap_pairs(data)
    elif magic == bytes.fromhex("40123780"):
        print("Detected n64 (32-bit word swapped). Not yet implemented.")
        return 2
    else:
        print(f"Unknown magic {magic.hex()}; cannot determine format.")
        return 2

    if out[:4] != Z64_MAGIC:
        print(f"ERROR: output magic {out[:4].hex()} != expected {Z64_MAGIC.hex()}")
        return 3

    sha1 = hashlib.sha1(out).hexdigest()
    print(f"Output SHA1: {sha1}")
    if sha1 == EXPECTED_SHA1_US_Z64:
        print("SHA1 matches canonical US z64 ROM.")
    else:
        print("WARNING: SHA1 does NOT match canonical US z64 ROM — continuing anyway.")

    dst_path.write_bytes(out)
    print(f"Wrote {len(out)} bytes to {dst_path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: byteswap_v64_to_z64.py <src.v64> <dst.z64>")
        sys.exit(1)
    sys.exit(main(sys.argv[1], sys.argv[2]))
