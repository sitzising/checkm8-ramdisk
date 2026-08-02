#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
A11（iPhone 8 / 8 Plus / X）全系统覆盖节点 — SSHRD_Script_Lite 离线构建主控

环境：Docker Ubuntu 22.04 + SSHRD_Script_Lite
补丁：A11 boot-args / ifirmware_parser（kernel+ramdisk）/ trustcache(rtsc)+sshtar

每个设备生成覆盖节点 zip（非逐版本）：
  11.4.1.zip → iOS 11.0 ~ 11.4.1   （A11 最低可装 11；无 iOS 7–10）
  12.4.1.zip → iOS 12.0 ~ 12.4.1
  13.7.zip   → iOS 13.0 ~ 13.7
  14.0.zip   → iOS 14.0 ~ 14.8.1
  15.0.zip   → iOS 15.0 ~ 15.7.x
  16.0.zip   → iOS 16.0 ~ 16.3.1
  16.7.8.zip → iOS 16.4 ~ 16.7.x   （Linux 无 APFS，默认跳过；macOS 或 --force-apfs）

输出（仅逗号 ProductType，禁止点号目录）：
  $ROOT/ramdisks/{iPhone10,2}/{version}.zip
  $ROOT/ramdisks/{iPhone10,2}/default.zip  ← 优先 16.7.8，否则 16.0
  $ROOT/manifest.json

用法：
  cd /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
  python3 -u Scripts/baota/build_a11_ramdisks.py
  nohup python3 -u Scripts/baota/build_a11_ramdisks.py >> build_a11_ramdisks.log 2>&1 &

  # 仅某机 / 某版本
  python3 -u Scripts/baota/build_a11_ramdisks.py --only iPhone10,2 --ios 15.0 16.0
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
OK_LIST = os.path.join(ROOT, "build_a11_ramdisks.ok.list")
FAIL_LIST = os.path.join(ROOT, "build_a11_ramdisks.fail.list")
SKIP_LIST = os.path.join(ROOT, "build_a11_ramdisks.skip.list")
BASE_URL = "https://tool.a-cheng.cn/ramdisk/checkm8-down/"

A11_DEVICES = [
    "iPhone10,1",  # iPhone 8 GSM
    "iPhone10,2",  # iPhone 8 Plus GSM（国行）
    "iPhone10,3",  # iPhone X Global
    "iPhone10,4",  # iPhone 8 Global
    "iPhone10,5",  # iPhone 8 Plus Global（勿与 10,2 混用）
    "iPhone10,6",  # iPhone X GSM
]

# out = 发布 zip 名；ios = 传给 sshrd_lite -s；coverage = 该 zip 覆盖的系统区间
# 覆盖节点（不是 14.1/14.2… 逐版本）；顺序：最低 → 最高
# 注：A11（iPhone 8/X）出厂最低 iOS 11，无法构建/使用 iOS 7–10 ramdisk
NODES = [
    {
        "out": "11.4.1",
        "ios": "11.4.1",
        "coverage": "iOS 11.0 ~ 11.4.1",
    },
    {
        "out": "12.4.1",
        "ios": "12.4.1",
        "coverage": "iOS 12.0 ~ 12.4.1",
    },
    {
        "out": "13.7",
        "ios": "13.7",
        "coverage": "iOS 13.0 ~ 13.7",
    },
    {
        "out": "14.0",
        "ios": "14.0",
        "coverage": "iOS 14.0 ~ 14.8.1",
    },
    {
        "out": "15.0",
        "ios": "15.0",
        "coverage": "iOS 15.0 ~ 15.7.x",
    },
    {
        "out": "16.0",
        "ios": "16.0",
        "coverage": "iOS 16.0 ~ 16.3.1",
    },
    {
        "out": "16.7.8",
        "ios": "16.7.8",
        "coverage": "iOS 16.4 ~ 16.7.x",
        "needs_apfs": True,
    },
]

COVERAGE_MAP = {n["out"]: n["coverage"] for n in NODES}
NODE_BY_OUT = {n["out"]: n for n in NODES}
NODE_VERSIONS = [n["out"] for n in NODES]

DEFAULT_PREFER = "16.7.8"
FALLBACK_DEFAULT = "16.0"

# A11 boot-args（与用户规范一致；不含 -n）
A11_BOOT_ARGS = "rd=md0 -v wdt=-1 cs_enforcement=0 amfi=0xff keepsyms=1"

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
_FWKEYS_CACHE = {}


def log(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("[%s] %s" % (ts, msg), flush=True)


def norm_device(s):
    d = (s or "").strip().replace(".", ",")
    if not re.match(r"^iPhone\d+,\d+$", d):
        raise ValueError("invalid productType: %r (use comma form e.g. iPhone10,2)" % s)
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


def node_needs_apfs(node):
    if node.get("needs_apfs"):
        return True
    t = parse_ios_tuple(node.get("ios") or node.get("out"))
    return t is not None and t >= (16, 1, 0)


def append_list(path, line):
    with open(path, "a", encoding="utf-8") as f:
        f.write(line.rstrip() + "\n")


def zip_path(device, version):
    return os.path.join(OUT_DIR, device, "%s.zip" % version)


def zip_exists(device, version, min_bytes=1_000_000):
    p = zip_path(device, version)
    return os.path.isfile(p) and os.path.getsize(p) >= min_bytes


def fetch_buildid(device, version):
    url = "https://api.ipsw.me/v4/device/%s?type=ipsw" % urllib.parse.quote(device)
    data = http_json(url)
    for fw in data.get("firmwares") or []:
        if (fw.get("version") or "").strip() == version:
            return (fw.get("buildid") or "").strip()
    return ""


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
    for m in (16, 15, 14, 13, 12, 11):
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
    ok = True
    ok = run_patch(PATCH_BOOTARGS, "A11 boot-args") and ok
    ok = run_patch(PATCH_PARSER, "ifirmware_parser kernel/ramdisk") and ok
    return ok


def purge_dot_dirs():
    if not os.path.isdir(OUT_DIR):
        return
    for name in list(os.listdir(OUT_DIR)):
        if name.startswith("iPhone") and "." in name and "," not in name:
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
    """ios_ver 传给 Lite；out_ver 为发布 zip 名（可相同）。"""
    device = norm_device(device)
    cmd = ["bash", DOCKER_BUILDER, device, ios_ver]
    if buildid:
        cmd.append(buildid)
    else:
        cmd.append("")
    if out_ver and out_ver != ios_ver:
        cmd.append(out_ver)
    elif out_ver:
        cmd.append(out_ver)
    log("[build] %s" % " ".join(cmd))
    env = os.environ.copy()
    env["CHECKM8_ROOT"] = ROOT
    p = subprocess.run(cmd, cwd=ROOT, env=env, timeout=timeout)
    purge_dot_dirs()
    # docker 可能仍写成 ios_ver.zip：兼容重命名
    want = zip_path(device, out_ver)
    alt = zip_path(device, ios_ver)
    if out_ver != ios_ver and (not os.path.isfile(want)) and os.path.isfile(alt):
        os.makedirs(os.path.dirname(want), exist_ok=True)
        shutil.move(alt, want)
        log("[rename] %s -> %s" % (alt, want))
    return p.returncode == 0 and zip_exists(device, out_ver)


def pick_default(device):
    if zip_exists(device, DEFAULT_PREFER):
        return DEFAULT_PREFER
    if zip_exists(device, FALLBACK_DEFAULT):
        return FALLBACK_DEFAULT
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
                "nodes": list(NODE_VERSIONS),
            }
    out = {
        "baseUrl": BASE_URL,
        "devices": devices,
        "nodes": [
            {
                "version": n["out"],
                "coverage": n["coverage"],
                "needsApfs": bool(n.get("needs_apfs") or node_needs_apfs(n)),
            }
            for n in NODES
        ],
        "a11": {
            "bootArgs": A11_BOOT_ARGS,
            "patches": [
                "iBEC boot-args (cpid 0x8015)",
                "KPlooshFinder kernel patch",
                "trustcache pack -T rtsc",
                "sshtar: dropbear / sftp-server / bash",
            ],
        },
        "updatedAt": datetime.datetime.utcnow().isoformat() + "Z",
        "note": (
            "A11 coverage nodes 11.4.1/12.4.1/13.7/14.0/15.0/16.0/16.7.8; "
            "A11 has no iOS 7-10; comma ProductType only; always -b buildid; "
            "16.7.8 requires Darwin/APFS on Linux hosts"
        ),
    }
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    log("[manifest] devices=%d -> %s" % (len(devices), MANIFEST))


def disk_free_gb():
    st = os.statvfs(ROOT)
    return (st.f_bavail * st.f_frsize) / (1024 ** 3)


def cleanup_temp():
    """只清构建临时文件，绝不碰 ramdisks/ 成品。"""
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
    # 禁止 docker system prune：曾导致 bind-mount 成品目录被掏空


def resolve_node(version_token):
    """接受 out 名或 ios 名。"""
    t = (version_token or "").strip()
    if t in NODE_BY_OUT:
        return NODE_BY_OUT[t]
    for n in NODES:
        if n["ios"] == t:
            return n
    # 自定义临时节点
    return {"out": t, "ios": t, "coverage": "custom", "needs_apfs": needs_apfs_ver(t)}


def needs_apfs_ver(ver):
    t = parse_ios_tuple(ver)
    return t is not None and t >= (16, 1, 0)


def build_one(device, node, force_apfs, dry_run):
    device = norm_device(device)
    out_ver = node["out"]
    ios_ver = node.get("ios") or out_ver

    if zip_exists(device, out_ver):
        log("[skip] exists %s @%s" % (device, out_ver))
        append_list(SKIP_LIST, "%s %s exists" % (device, out_ver))
        return "skip"

    if node_needs_apfs(node) and not force_apfs:
        log(
            "[skip] %s @%s needs APFS — Linux Docker 无法制作 16.1+；"
            "使用 --force-apfs 强制尝试，或在 macOS 构建后上传到 "
            "ramdisks/%s/%s.zip" % (device, out_ver, device, out_ver)
        )
        append_list(SKIP_LIST, "%s %s apfs-linux" % (device, out_ver))
        return "skip"

    if dry_run:
        log("[dry] would build %s ios=%s out=%s" % (device, ios_ver, out_ver))
        return "dry"

    try:
        build = fetch_buildid(device, ios_ver)
    except Exception as e:
        log("[fail] ipsw %s @%s: %s" % (device, ios_ver, e))
        append_list(FAIL_LIST, "%s %s ipsw" % (device, out_ver))
        return "fail"
    if not build:
        log("[skip] no IPSW %s @%s" % (device, ios_ver))
        append_list(SKIP_LIST, "%s %s no-ipsw" % (device, out_ver))
        return "skip"

    if not ensure_keys(device, build, ios_ver):
        log("[skip] no keys %s %s @%s" % (device, build, ios_ver))
        append_list(SKIP_LIST, "%s %s no-keys" % (device, out_ver))
        return "skip"

    if disk_free_gb() < 8:
        cleanup_temp()
        if disk_free_gb() < 6:
            append_list(FAIL_LIST, "%s %s disk" % (device, out_ver))
            return "fail"

    try:
        ok = run_docker_build(device, ios_ver, out_ver, buildid=build)
    except subprocess.TimeoutExpired:
        append_list(FAIL_LIST, "%s %s timeout" % (device, out_ver))
        return "fail"
    except Exception as e:
        append_list(FAIL_LIST, "%s %s %s" % (device, out_ver, e))
        return "fail"

    cleanup_temp()
    if ok:
        log("[ok] %s @%s (build %s)" % (device, out_ver, build))
        append_list(OK_LIST, "%s %s" % (device, out_ver))
        refresh_default(device)
        write_manifest()
        return "ok"

    log("[fail] %s @%s" % (device, out_ver))
    append_list(FAIL_LIST, "%s %s build" % (device, out_ver))
    return "fail"


def main():
    ap = argparse.ArgumentParser(
        description="A11 coverage-node SSHRD_Script_Lite offline builder"
    )
    ap.add_argument("--only", nargs="*", help="仅机型，如 iPhone10,2")
    ap.add_argument(
        "--ios",
        nargs="*",
        help="仅节点版本（zip 名），如 15.0 16.0 13.7",
    )
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--force-apfs",
        action="store_true",
        help="强制尝试 16.7.8（Linux 通常失败）",
    )
    ap.add_argument("--skip-patch", action="store_true", help="跳过补丁步骤")
    ap.add_argument("--manifest-only", action="store_true")
    ap.add_argument(
        "--clean-lists",
        action="store_true",
        help="启动前清空 ok/fail/skip 列表",
    )
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(KEYS_DIR, exist_ok=True)

    if args.manifest_only:
        for d in A11_DEVICES:
            if os.path.isdir(os.path.join(OUT_DIR, d)):
                refresh_default(d)
        purge_dot_dirs()
        write_manifest()
        return 0

    if args.clean_lists:
        for p in (OK_LIST, FAIL_LIST, SKIP_LIST):
            open(p, "w").close()

    if not args.skip_patch:
        log("[patch] applying A11 boot-args + ifirmware_parser fixes")
        if not apply_all_patches():
            log("[fatal] patch failed")
            return 2

    if not os.path.isfile(DOCKER_BUILDER):
        log("[fatal] missing %s" % DOCKER_BUILDER)
        return 2
    if not os.path.isfile(os.path.join(LITE_DIR, "sshrd_lite.sh")):
        log("[fatal] missing sshrd_lite.sh under %s" % LITE_DIR)
        return 2

    devices = A11_DEVICES
    if args.only:
        devices = [norm_device(x) for x in args.only]

    if args.ios:
        nodes = [resolve_node(x) for x in args.ios]
    else:
        nodes = list(NODES)

    for p in (OK_LIST, FAIL_LIST, SKIP_LIST):
        if not os.path.isfile(p):
            open(p, "a").close()

    log("======== build_a11_ramdisks start ========")
    log("devices=%s" % devices)
    log(
        "nodes=%s"
        % [{"out": n["out"], "ios": n["ios"], "coverage": n["coverage"]} for n in nodes]
    )
    log("force_apfs=%s" % args.force_apfs)
    log("A11 boot-args: %s" % A11_BOOT_ARGS)
    log(
        "Patches: KPlooshFinder kernel + trustcache(rtsc) + "
        "sshtar(dropbear/sftp/bash) + SEP/passcode bypass via boot-args"
    )

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
    log("lists: %s | %s | %s" % (OK_LIST, FAIL_LIST, SKIP_LIST))
    return 0


if __name__ == "__main__":
    sys.exit(main())
