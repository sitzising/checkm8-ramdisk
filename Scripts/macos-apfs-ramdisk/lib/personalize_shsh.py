#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Patch SSHRD Lite CPID .shsh ApImg4Ticket: BORD (required) + ECID (best-effort)."""
import argparse
import plistlib
import sys
from pathlib import Path

try:
    from typing import Optional
except ImportError:
    Optional = None  # type: ignore

# ProductType → ApBoardId (BORD)
PRODUCT_BORD = {
    "iPhone10,1": 0x02,
    "iPhone10,2": 0x04,
    "iPhone10,3": 0x06,
    "iPhone10,4": 0x0A,
    "iPhone10,5": 0x0C,
    "iPhone10,6": 0x0E,
    "iPhone9,1": 0x00,
    "iPhone9,2": 0x02,
    "iPhone9,3": 0x0A,
    "iPhone9,4": 0x0C,
    "iPhone8,1": 0x04,
    "iPhone8,2": 0x06,
    "iPhone8,4": 0x02,
}


def _find_tag_int(blob: bytes, tag: bytes, start: int = 0):
    i = blob.find(tag, start)
    while i >= 0:
        p = i + 4
        if p + 2 <= len(blob) and blob[p] == 0x02:
            ln = blob[p + 1]
            if 1 <= ln <= 8 and p + 2 + ln <= len(blob):
                val = int.from_bytes(blob[p + 2 : p + 2 + ln], "big")
                return i, p, ln, val
        i = blob.find(tag, i + 1)
    return None


def _encode_int(value: int) -> bytes:
    if value < 0:
        raise ValueError("negative")
    h = value.to_bytes((value.bit_length() + 7) // 8 or 1, "big")
    if h[0] & 0x80:
        h = b"\x00" + h
    return h


def patch_tag_int(blob: bytearray, tag: bytes, new_value: int, allow_resize: bool = False) -> bool:
    hit = _find_tag_int(bytes(blob), tag)
    if not hit:
        return False
    _i, p, old_ln, old_val = hit
    new_bytes = _encode_int(new_value)
    new_ln = len(new_bytes)
    if new_ln == old_ln:
        blob[p + 2 : p + 2 + old_ln] = new_bytes
        return True
    # 禁止改长度：Lite 通用 ECID 5 字节 → 真机 7 字节会撑坏 ASN.1，
    # 发 iBSS 必掉系统恢复。BORD 本身是 1 字节，可原地改。
    if not allow_resize:
        return False
    blob[p + 1] = new_ln
    del blob[p + 2 : p + 2 + old_ln]
    for b in reversed(new_bytes):
        blob.insert(p + 2, b)
    _bump_parent_lengths(blob, p, new_ln - old_ln)
    return True


def _bump_parent_lengths(blob: bytearray, at: int, delta: int) -> None:
    if delta == 0:
        return
    # Walk backward looking for ASN.1 SEQUENCE/SET with definite length covering `at`
    i = at - 1
    touched = 0
    while i >= 2 and touched < 8:
        if blob[i] in (0x30, 0x31) and blob[i + 1] < 0x80:
            ln = blob[i + 1]
            end = i + 2 + ln
            if end >= at:
                new_ln = ln + delta
                if 0 <= new_ln <= 0x7F:
                    blob[i + 1] = new_ln
                    touched += 1
        elif blob[i] in (0x30, 0x31) and blob[i + 1] == 0x81 and i + 2 < len(blob):
            ln = blob[i + 2]
            end = i + 3 + ln
            if end >= at:
                new_ln = ln + delta
                if 0 <= new_ln <= 0xFF:
                    blob[i + 2] = new_ln
                    touched += 1
        elif blob[i] in (0x30, 0x31) and blob[i + 1] == 0x82 and i + 3 < len(blob):
            ln = (blob[i + 2] << 8) | blob[i + 3]
            end = i + 4 + ln
            if end >= at:
                new_ln = ln + delta
                if 0 <= new_ln <= 0xFFFF:
                    blob[i + 2] = (new_ln >> 8) & 0xFF
                    blob[i + 3] = new_ln & 0xFF
                    touched += 1
        i -= 1


def patch_shsh(src, dst, bord=None, ecid=None):
    data = src.read_bytes()
    plist = plistlib.loads(data)
    ticket = plist.get("ApImg4Ticket")
    if not isinstance(ticket, (bytes, bytearray)):
        raise SystemExit("no ApImg4Ticket")
    blob = bytearray(ticket)
    info = {"bord_before": None, "bord_after": None, "ecid_before": None, "ecid_after": None}

    hit_b = _find_tag_int(bytes(blob), b"BORD")
    hit_e = _find_tag_int(bytes(blob), b"ECID")
    if hit_b:
        info["bord_before"] = hit_b[3]
    if hit_e:
        info["ecid_before"] = hit_e[3]

    if bord is not None:
        if not patch_tag_int(blob, b"BORD", bord, allow_resize=False):
            raise SystemExit("BORD tag not found or length mismatch")
    if ecid is not None:
        # 默认不允许改 ECID 长度；失败则保留 Lite 通用 ECID（checkm8 可接受）
        if not patch_tag_int(blob, b"ECID", ecid, allow_resize=False):
            print(
                "[warn] skip ECID patch (length would change); keep Lite generic ECID — BORD is what matters",
                file=sys.stderr,
            )

    hit_b = _find_tag_int(bytes(blob), b"BORD")
    hit_e = _find_tag_int(bytes(blob), b"ECID")
    if hit_b:
        info["bord_after"] = hit_b[3]
    if hit_e:
        info["ecid_after"] = hit_e[3]

    plist["ApImg4Ticket"] = bytes(blob)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML))
    return info


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", required=True, type=Path)
    ap.add_argument("-o", "--output", required=True, type=Path)
    ap.add_argument("-p", "--product", default="", help="iPhone10,2 → set BORD")
    ap.add_argument("--bord", type=lambda s: int(s, 0), default=None)
    ap.add_argument("--ecid", type=lambda s: int(s, 0), default=None)
    args = ap.parse_args()

    bord = args.bord
    pt = (args.product or "").replace(".", ",")
    if bord is None and pt in PRODUCT_BORD:
        bord = PRODUCT_BORD[pt]
    if bord is None and not args.ecid:
        print("need --bord / --product / --ecid", file=sys.stderr)
        return 2

    info = patch_shsh(args.input, args.output, bord, args.ecid)
    print(
        "OK bord %s→%s ecid %s→%s → %s"
        % (
            info["bord_before"] is not None and hex(info["bord_before"]),
            info["bord_after"] is not None and hex(info["bord_after"]),
            info["ecid_before"] is not None and hex(info["ecid_before"]),
            info["ecid_after"] is not None and hex(info["ecid_after"]),
            args.output,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
