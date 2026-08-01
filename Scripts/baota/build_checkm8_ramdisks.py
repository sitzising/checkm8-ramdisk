#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
checkm8（A7–A11）全机型 SSH Ramdisk 离线构建主控
Docker Ubuntu 22.04 + SSHRD_Script_Lite

设备：与客户端 Checkm8UsbPwnCatalog 一致（A7/A8/A9/A10/A11）
覆盖节点（有 IPSW 才编，无则 skip）：
  7.1.2 / 8.4.1 / 9.3.5 / 10.3.3 / 11.4.1 / 12.5.7 / 13.7 / 14.8.1 / 15.8.3 / 16.0 / 16.7.8
  （各节点可自动回退到 alts，例如 12.5.7→12.4.1）

输出：
  $ROOT/ramdisks/{ProductType}/{version}.zip
  $ROOT/manifest.json

用法：
  cd /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
  nohup python3 -u Scripts/baota/build_checkm8_ramdisks.py >> build_checkm8_ramdisks.log 2>&1 &
"""

from __future__ import print_function

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

ROOT = os.environ.get(
    "CHECKM8_ROOT",
    "/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down",
)
LITE_DIR = os.path.join(ROOT, "build", "SSHRD_Script_Lite")
KEYS_DIR = os.path.join(LITE_DIR, "misc", "firmware_keys")
OUT_DIR = os.path.join(ROOT, "ramdisks")
MANIFEST = os.path.join(ROOT, "manifest.json")
DOCKER_BUILDER = os.path.join(ROOT, "Scripts", "baota", "docker-build-sshrd.sh")
PATCH_BOOTARGS = os.path.join(ROOT, "Scripts", "baota", "patch_sshrd_lite_a11.sh")
PATCH_PARSER = os.path.join(ROOT, "Scripts", "baota", "patch_ifirmware_parser_a11.sh")
OK_LIST = os.path.join(ROOT, "build_checkm8_ramdisks.ok.list")
FAIL_LIST = os.path.join(ROOT, "build_checkm8_ramdisks.fail.list")
SKIP_LIST = os.path.join(ROOT, "build_checkm8_ramdisks.skip.list")
BASE_URL = "https://tool.a-cheng.cn/ramdisk/checkm8-down/"

# 与 Models/Checkm8UsbPwnCatalog.cs 对齐（A7–A11 USB checkm8）
DEVICES = [
    # A7
    "iPhone6,1", "iPhone6,2",
    "iPad4,1", "iPad4,2", "iPad4,3", "iPad4,4", "iPad4,5", "iPad4,6",
    "iPad4,7", "iPad4,8", "iPad4,9",
    # A8
    "iPhone7,1", "iPhone7,2",
    "iPad5,1", "iPad5,2", "iPad5,3", "iPad5,4",
    "iPod7,1",
    # A9 / A9X
    "iPhone8,1", "iPhone8,2", "iPhone8,4",
    "iPad6,3", "iPad6,4", "iPad6,7", "iPad6,8", "iPad6,11", "iPad6,12",
    # A10 / A10X
    "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4",
    "iPad7,1", "iPad7,2", "iPad7,3", "iPad7,4", "iPad7,5", "iPad7,6",
    "iPad7,11", "iPad7,12",
    "iPod9,1",
    # A11
    "iPhone10,1", "iPhone10,2", "iPhone10,3", "iPhone10,4", "iPhone10,5", "iPhone10,6",
]

# 覆盖节点：优先 ios，失败则试 alts；zip 名用最终实际版本
NODES = [
    {"out": "7.1.2", "ios": "7.1.2", "alts": [], "coverage": "iOS 7.0 ~ 7.1.2"},
    {"out": "8.4.1", "ios": "8.4.1", "alts": [], "coverage": "iOS 8.0 ~ 8.4.1"},
    {"out": "9.3.5", "ios": "9.3.5", "alts": ["9.3.6"], "coverage": "iOS 9.0 ~ 9.3.x"},
    {"out": "10.3.3", "ios": "10.3.3", "alts": ["10.3.4"], "coverage": "iOS 10.0 ~ 10.3.x"},
    {"out": "11.4.1", "ios": "11.4.1", "alts": [], "coverage": "iOS 11.0 ~ 11.4.1"},
    {"out": "12.5.7", "ios": "12.5.7", "alts": ["12.4.1"], "coverage": "iOS 12.0 ~ 12.5.x"},
    {"out": "13.7", "ios": "13.7", "alts": [], "coverage": "iOS 13.0 ~ 13.7"},
    {"out": "14.8.1", "ios": "14.8.1", "alts": ["14.0"], "coverage": "iOS 14.0 ~ 14.8.1"},
    {"out": "15.8.3", "ios": "15.8.3", "alts": ["15.8.2", "15.7.1", "15.0.2", "15.0"], "coverage": "iOS 15.0 ~ 15.8.x"},
    {"out": "16.0", "ios": "16.0", "alts": [], "coverage": "iOS 16.0 ~ 16.3.1"},
    {"out": "16.7.8", "ios": "16.7.8", "alts": [], "coverage": "iOS 16.4 ~ 16.7.x", "needs_apfs": True},
]

COVERAGE_MAP = {n["out"]: n["coverage"] for n in NODES}
DEFAULT_PREFER = ["16.7.8", "16.0", "15.8.3", "15.7.1", "15.0", "14.8.1", "14.0", "13.7", "12.5.7", "12.4.1", "11.4.1"]

A11_BOOT_ARGS = "rd=md0 -v wdt=-1 cs_enforcement=0 amfi=0xff keepsyms=1"
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
_FWKEYS_CACHE = {}
_IPSW_CACHE = {}


def log(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("[%s] %s" % (ts, msg), flush=True)


def norm_device(s):
    d = (s or "").strip().replace(".", ",")
    if not re.match(r"^(iPhone|iPad|iPod)\d+,\d+$", d):
        raise ValueError("invalid productType: %r" % s)
    return d


def http_json(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def parse_ios_tuple(ver):
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?", (ver or "").strip())
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0))


def node_needs_apfs(node, ios_ver=None):
    if node.get("needs_apfs"):
        return True
    t = parse_ios_tuple(ios_ver or node.get("ios") or node.get("out"))
    return t is not None and t >= (16, 1, 0)


def append_list(path, line):
    with open(path, "a", encoding="utf-8") as f:
        f.write(line.rstrip() + "\n")


def zip_path(device, version):
    return os.path.join(OUT_DIR, device, "%s.zip" % version)


def zip_exists(device, version, min_bytes=1_000_000):
    p = zip_path(device, version)
    return os.path.isfile(p) and os.path.getsize(p) >= min_bytes


def firmwares_for(device):
    if device in _IPSW_CACHE:
        return _IPSW_CACHE[device]
    url = "https://api.ipsw.me/v4/device/%s?type=ipsw" % urllib.parse.quote(device)
    try:
        data = http_json(url)
        m = {}
        for fw in data.get("firmwares") or []:
            ver = (fw.get("version") or "").strip()
            bid = (fw.get("buildid") or "").strip()
            if ver and bid:
                m[ver] = bid
        _IPSW_CACHE[device] = m
    except Exception as e:
        log("[ipsw] %s fail: %s" % (device, e))
        _IPSW_CACHE[device] = {}
    return _IPSW_CACHE[device]


def resolve_ios_build(device, node):
    """返回 (ios_ver, buildid, zip_name) 或 (None,None,None)。zip_name 优先用 node.out。"""
    fw = firmwares_for(device)
    candidates = [node["ios"]] + list(node.get("alts") or [])
    for ver in candidates:
        bid = fw.get(ver)
        if bid:
            # zip 用节点名，便于覆盖语义；若用了 alt 也仍写 out
            return ver, bid, node["out"]
    return None, None, None


def wiki_api(**params):
    params = dict(params)
    params.setdefault("format", "json")
    url = "https://theapplewiki.com/api.php?" + urllib.parse.urlencode(params)
    return http_json(url, timeout=45)


def firmware_keys_wikitext(major):
    if major in _FWKEYS_CACHE:
        return _FWKEYS_CACHE[major]
    page = "Firmware Keys/%d.x" % major
    try:
        d = wiki_api(action="parse", page=page, prop="wikitext")
        wt = d.get("parse", {}).get("wikitext", {}).get("*", "") or ""
    except Exception as e:
        log("[keys] page fail %s: %s" % (page, e))
        wt = ""
    _FWKEYS_CACHE[major] = wt
    return wt


def resolve_keys_page_title(device, build, version):
    t = parse_ios_tuple(version)
    majors = []
    if t:
        majors.append(t[0])
    for m in range(16, 6, -1):
        if m not in majors:
            majors.append(m)
    pat = re.compile(r"\[\[(Keys:[^\|\]]+\(%s\))\|" % re.escape(device), re.I)
    for major in majors:
        wt = firmware_keys_wikitext(major)
        if not wt:
            continue
        for m in pat.finditer(wt):
            title = m.group(1).strip()
            if build in title.replace(" ", "_") or build in title:
                return title
    return None


def parse_keys_template(wt, device, build):
    fields = {}
    for m in re.finditer(r"\|\s*([A-Za-z0-9 \-]+?)\s*=\s*([^\n|}]+)", wt):
        k = re.sub(r"\s+", "", m.group(1)).strip().lower()
        fields[k] = m.group(2).strip()
    comps = [
        ("ibss", "iBSS"),
        ("ibec", "iBEC"),
        ("iboot", "iBoot"),
        ("llb", "LLB"),
        ("sepfirmware", "SEP-Firmware"),
    ]
    lite = {}
    for ckey, pretty in comps:
        fn = fields.get(ckey) or fields.get(ckey + "filename")
        iv = fields.get(ckey + "iv")
        key = fields.get(ckey + "key")
        if not (fn and iv and key):
            continue
        iv = re.sub(r"[^0-9a-fA-F]", "", iv).lower()
        key = re.sub(r"[^0-9a-fA-F]", "", key).lower()
        if len(iv) < 16 or len(key) < 32:
            continue
        tag = pretty.lower().replace("-", "")
        kname = "%s (%s)_%s_%s#%s" % (pretty, device, build, fn, tag)
        lite[kname] = {"iv": iv, "key": key}
    return lite


def ensure_keys(device, build, version):
    os.makedirs(KEYS_DIR, exist_ok=True)
    dest = os.path.join(KEYS_DIR, "%s_%s.json" % (device, build))
    if os.path.isfile(dest) and os.path.getsize(dest) > 80:
        return True
    title = resolve_keys_page_title(device, build, version)
    if not title:
        log("[keys] missing wiki page for %s %s @%s" % (device, build, version))
        return False
    try:
        d = wiki_api(action="parse", page=title, prop="wikitext")
        wt = d.get("parse", {}).get("wikitext", {}).get("*", "") or ""
    except Exception as e:
        log("[keys] parse fail %s: %s" % (title, e))
        return False
    lite = parse_keys_template(wt, device, build)
    if len(lite) < 2:
        log("[keys] empty parse %s" % title)
        return False
    with open(dest, "w", encoding="utf-8") as f:
        json.dump(lite, f)
    log("[keys] saved %s (%d)" % (dest, len(lite)))
    return True


def run_patch(script, label):
    if not os.path.isfile(script):
        log("[warn] patch missing: %s" % script)
        return False
    env = os.environ.copy()
    env["CHECKM8_ROOT"] = ROOT
    r = subprocess.run(["bash", script], cwd=ROOT, env=env)
    if r.returncode != 0:
        log("[fail] %s exit=%s" % (label, r.returncode))
        return False
    log("[patch] %s ok" % label)
    return True


def apply_all_patches():
    ok = run_patch(PATCH_BOOTARGS, "A11 boot-args")
    ok = run_patch(PATCH_PARSER, "ifirmware_parser") and ok
    return ok


def purge_dot_dirs():
    if not os.path.isdir(OUT_DIR):
        return
    for name in list(os.listdir(OUT_DIR)):
        if re.match(r"^(iPhone|iPad|iPod)\d+\.\d+$", name):
            path = os.path.join(OUT_DIR, name)
            log("[clean] remove illegal dot path %s" % path)
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                try:
                    os.remove(path)
                except OSError:
                    pass


def run_docker_build(device, ios_ver, out_ver, buildid="", timeout=7200):
    device = norm_device(device)
    cmd = ["bash", DOCKER_BUILDER, device, ios_ver, buildid or "", out_ver]
    log("[build] %s" % " ".join(cmd))
    env = os.environ.copy()
    env["CHECKM8_ROOT"] = ROOT
    p = subprocess.run(cmd, cwd=ROOT, env=env, timeout=timeout)
    purge_dot_dirs()
    want = zip_path(device, out_ver)
    alt = zip_path(device, ios_ver)
    if out_ver != ios_ver and (not os.path.isfile(want)) and os.path.isfile(alt):
        os.makedirs(os.path.dirname(want), exist_ok=True)
        shutil.move(alt, want)
        log("[rename] %s -> %s" % (alt, want))
    return p.returncode == 0 and zip_exists(device, out_ver)


def pick_default(device):
    for pref in DEFAULT_PREFER:
        if zip_exists(device, pref):
            return pref
    ddir = os.path.join(OUT_DIR, device)
    if not os.path.isdir(ddir):
        return None
    vers = []
    for fn in os.listdir(ddir):
        if fn.endswith(".zip") and fn != "default.zip":
            v = fn[:-4]
            if zip_exists(device, v):
                vers.append(v)
    if not vers:
        return None
    return sorted(vers, key=lambda x: parse_ios_tuple(x) or (0, 0, 0))[-1]


def refresh_default(device):
    ver = pick_default(device)
    if not ver:
        return
    src = zip_path(device, ver)
    dst = os.path.join(OUT_DIR, device, "default.zip")
    try:
        if os.path.lexists(dst):
            os.remove(dst)
    except OSError:
        pass
    try:
        os.symlink(os.path.basename(src), dst)
        log("[default] %s -> %s (symlink)" % (device, ver))
    except OSError:
        shutil.copy2(src, dst)
        log("[default] %s -> %s (copy)" % (device, ver))
    top = os.path.join(OUT_DIR, "%s.zip" % device)
    try:
        shutil.copy2(src, top)
    except OSError:
        pass


def write_manifest():
    devices = {}
    if os.path.isdir(OUT_DIR):
        for name in sorted(os.listdir(OUT_DIR)):
            path = os.path.join(OUT_DIR, name)
            if not os.path.isdir(path):
                continue
            try:
                device = norm_device(name)
            except ValueError:
                continue
            versions = {}
            for fn in sorted(os.listdir(path)):
                if not fn.endswith(".zip") or fn == "default.zip":
                    continue
                ver = fn[:-4]
                if zip_exists(device, ver, min_bytes=1000):
                    versions[ver] = "ramdisks/%s/%s.zip" % (device, ver)
            if not versions:
                continue
            default_ios = pick_default(device) or sorted(
                versions.keys(), key=lambda x: parse_ios_tuple(x) or (0, 0, 0)
            )[-1]
            devices[device] = {
                "defaultIos": default_ios,
                "versions": versions,
                "url": "ramdisks/%s/%s.zip" % (device, default_ios),
                "coverage": {k: COVERAGE_MAP[k] for k in COVERAGE_MAP if k in versions},
            }
    out = {
        "baseUrl": BASE_URL,
        "devices": devices,
        "nodes": [
            {
                "version": n["out"],
                "coverage": n["coverage"],
                "needsApfs": bool(n.get("needs_apfs")),
            }
            for n in NODES
        ],
        "scope": "A7-A11 checkm8 USB devices; iOS 7-16 coverage nodes",
        "a11": {"bootArgs": A11_BOOT_ARGS},
        "updatedAt": datetime.datetime.utcnow().isoformat() + "Z",
        "note": "SSHRD_Script_Lite docker; comma ProductType only; skip if no IPSW/keys; 16.1+ needs APFS/macOS",
    }
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    log("[manifest] devices=%d -> %s" % (len(devices), MANIFEST))


def disk_free_gb():
    st = os.statvfs(ROOT)
    return (st.f_bavail * st.f_frsize) / (1024 ** 3)


def cleanup_temp():
    cache = os.path.join(ROOT, "build", "lite-cache")
    if os.path.isdir(cache):
        for root, _dirs, files in os.walk(cache):
            for fn in files:
                if fn.endswith(".ipsw"):
                    try:
                        os.remove(os.path.join(root, fn))
                    except OSError:
                        pass
    for d in (
        os.path.join(LITE_DIR, "1_prepare_ramdisk"),
        os.path.join(LITE_DIR, "2_ssh_ramdisk"),
        os.path.join(cache, "lite", "1_prepare_ramdisk"),
        os.path.join(cache, "lite", "2_ssh_ramdisk"),
    ):
        shutil.rmtree(d, ignore_errors=True)


def resolve_node(token):
    t = (token or "").strip()
    for n in NODES:
        if n["out"] == t or n["ios"] == t or t in (n.get("alts") or []):
            return n
    return {"out": t, "ios": t, "alts": [], "coverage": "custom"}


def build_one(device, node, force_apfs, dry_run, retries=2):
    device = norm_device(device)
    ios_ver, build, out_ver = resolve_ios_build(device, node)
    if not ios_ver:
        log("[skip] no IPSW %s node=%s" % (device, node["out"]))
        append_list(SKIP_LIST, "%s %s no-ipsw" % (device, node["out"]))
        return "skip"

    if zip_exists(device, out_ver):
        log("[skip] exists %s @%s" % (device, out_ver))
        append_list(SKIP_LIST, "%s %s exists" % (device, out_ver))
        return "skip"

    if node_needs_apfs(node, ios_ver) and not force_apfs:
        log("[skip] %s @%s needs APFS (Linux)" % (device, out_ver))
        append_list(SKIP_LIST, "%s %s apfs-linux" % (device, out_ver))
        return "skip"

    if dry_run:
        log("[dry] would build %s ios=%s out=%s build=%s" % (device, ios_ver, out_ver, build))
        return "dry"

    if not ensure_keys(device, build, ios_ver):
        log("[skip] no keys %s %s @%s" % (device, build, ios_ver))
        append_list(SKIP_LIST, "%s %s no-keys" % (device, out_ver))
        return "skip"

    if disk_free_gb() < 8:
        cleanup_temp()
        if disk_free_gb() < 6:
            append_list(FAIL_LIST, "%s %s disk" % (device, out_ver))
            return "fail"

    last_err = "build"
    for attempt in range(1, retries + 2):
        try:
            ok = run_docker_build(device, ios_ver, out_ver, buildid=build)
        except subprocess.TimeoutExpired:
            last_err = "timeout"
            ok = False
        except Exception as e:
            last_err = str(e)
            ok = False
        cleanup_temp()
        if ok:
            log("[ok] %s @%s (ios=%s build %s attempt=%d)" % (device, out_ver, ios_ver, build, attempt))
            append_list(OK_LIST, "%s %s" % (device, out_ver))
            refresh_default(device)
            write_manifest()
            return "ok"
        log("[retry] %s @%s attempt=%d failed (%s)" % (device, out_ver, attempt, last_err))
        time.sleep(3)

    log("[fail] %s @%s" % (device, out_ver))
    append_list(FAIL_LIST, "%s %s %s" % (device, out_ver, last_err))
    return "fail"


def main():
    ap = argparse.ArgumentParser(description="A7-A11 checkm8 ramdisk coverage builder (iOS 7-16)")
    ap.add_argument("--only", nargs="*", help="仅机型")
    ap.add_argument("--ios", nargs="*", help="仅节点 out 名，如 11.4.1 13.7")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force-apfs", action="store_true")
    ap.add_argument("--skip-patch", action="store_true")
    ap.add_argument("--manifest-only", action="store_true")
    ap.add_argument("--clean-lists", action="store_true")
    ap.add_argument("--phones-only", action="store_true", help="仅 iPhone（跳过 iPad/iPod）")
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(KEYS_DIR, exist_ok=True)

    if args.manifest_only:
        for d in DEVICES:
            if os.path.isdir(os.path.join(OUT_DIR, d)):
                refresh_default(d)
        purge_dot_dirs()
        write_manifest()
        return 0

    if args.clean_lists:
        for p in (OK_LIST, FAIL_LIST, SKIP_LIST):
            open(p, "w").close()

    if not args.skip_patch:
        log("[patch] applying boot-args + ifirmware_parser")
        if not apply_all_patches():
            log("[fatal] patch failed")
            return 2

    if not os.path.isfile(DOCKER_BUILDER):
        log("[fatal] missing %s" % DOCKER_BUILDER)
        return 2
    if not os.path.isfile(os.path.join(LITE_DIR, "sshrd_lite.sh")):
        log("[fatal] missing sshrd_lite.sh")
        return 2

    devices = DEVICES
    if args.phones_only:
        devices = [d for d in devices if d.startswith("iPhone")]
    if args.only:
        devices = [norm_device(x) for x in args.only]

    if args.ios:
        nodes = [resolve_node(x) for x in args.ios]
    else:
        nodes = list(NODES)

    for p in (OK_LIST, FAIL_LIST, SKIP_LIST):
        if not os.path.isfile(p):
            open(p, "a").close()

    log("======== build_checkm8_ramdisks start ========")
    log("devices=%d nodes=%s" % (len(devices), [n["out"] for n in nodes]))
    log("scope=A7-A11 iOS7-16 coverage; force_apfs=%s" % args.force_apfs)

    stats = {"ok": 0, "fail": 0, "skip": 0, "dry": 0}
    for device in devices:
        for node in nodes:
            st = build_one(device, node, args.force_apfs, args.dry_run)
            stats[st] = stats.get(st, 0) + 1
            time.sleep(0.2)
        refresh_default(device)

    purge_dot_dirs()
    write_manifest()
    log("======== done %s ========" % stats)
    return 0


if __name__ == "__main__":
    sys.exit(main())
