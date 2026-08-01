#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
A11 全机型 × 全系统 SSH Ramdisk 主控（Docker + SSHRD_Script_Lite）

目录约定（仅逗号 ProductType，禁止点号目录）：
  $ROOT/ramdisks/{iPhone10,2}/{16.0}.zip
  $ROOT/ramdisks/{iPhone10,2}/default.zip   ← 最新稳定版软链/复制
  $ROOT/manifest.json
  $ROOT/build/SSHRD_Script_Lite/misc/firmware_keys/{device}_{build}.json

用法：
  cd /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
  python3 Scripts/baota/build_all_a11.py
  python3 Scripts/baota/build_all_a11.py --only iPhone10,2 --max 3
  python3 Scripts/baota/build_all_a11.py --include-apfs   # 尝试 16.1+（Linux 通常失败）
  nohup python3 -u Scripts/baota/build_all_a11.py >> build_all_a11.log 2>&1 &
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
import urllib.error
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
OK_LIST = os.path.join(ROOT, "build_all_a11.ok.list")
FAIL_LIST = os.path.join(ROOT, "build_all_a11.fail.list")
SKIP_LIST = os.path.join(ROOT, "build_all_a11.skip.list")
BASE_URL = "https://tool.a-cheng.cn/ramdisk/checkm8-down/"

A11_DEVICES = [
    "iPhone10,1",
    "iPhone10,2",
    "iPhone10,3",
    "iPhone10,4",
    "iPhone10,5",
    "iPhone10,6",
]

# dkxuanye/SSHRD 推荐：优先作 default（若该版本已成功构建）
PREFERRED_DEFAULT = {
    "iPhone10,1": "16.4",
    "iPhone10,2": "16.4",
    "iPhone10,4": "16.4",
    "iPhone10,5": "16.4",
    "iPhone10,3": "16.7.16",
    "iPhone10,6": "16.7.16",
}

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

# Firmware Keys 列表页缓存：major -> wikitext
_FWKEYS_CACHE = {}


def log(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("[%s] %s" % (ts, msg), flush=True)


def norm_device(s):
    """强制逗号 ProductType；禁止点号目录名。"""
    d = (s or "").strip().replace(".", ",")
    if not re.match(r"^iPhone\d+,\d+$", d):
        raise ValueError("invalid productType: %r" % s)
    return d


def http_json(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def http_bytes(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def parse_ios_tuple(ver):
    """'16.7.10' -> (16,7,10)；无法解析返回 None。"""
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?", (ver or "").strip())
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0))


def is_release_version(ver):
    """排除 beta / RC 字符串（ipsw.me 正式版一般是纯数字段）。"""
    return bool(re.match(r"^\d+(\.\d+){0,3}$", (ver or "").strip()))


def ios_in_range(ver, min_ios=(11, 0, 0), max_ios=(16, 99, 99)):
    t = parse_ios_tuple(ver)
    if not t:
        return False
    return min_ios <= t <= max_ios


def needs_apfs(ver):
    """iOS 16.1+ ramdisk 为 APFS，Linux/hfsplus 无法处理。"""
    t = parse_ios_tuple(ver)
    return t is not None and t >= (16, 1, 0)


def fetch_firmwares(device):
    """api.ipsw.me → [{version, buildid, ...}, ...] 正式版，11.0–16.7.x。"""
    url = "https://api.ipsw.me/v4/device/%s?type=ipsw" % urllib.parse.quote(device)
    data = http_json(url)
    out = []
    seen = set()
    for fw in data.get("firmwares") or []:
        ver = (fw.get("version") or "").strip()
        build = (fw.get("buildid") or "").strip()
        if not ver or not build:
            continue
        if not is_release_version(ver):
            continue
        if not ios_in_range(ver, (11, 0, 0), (16, 99, 99)):
            continue
        key = (ver, build)
        if key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "version": ver,
                "buildid": build,
                "url": fw.get("url") or "",
                "signed": bool(fw.get("signed")),
            }
        )
    # 版本升序构建（先旧后新，便于先出可用包）
    out.sort(key=lambda x: (parse_ios_tuple(x["version"]) or (0, 0, 0), x["buildid"]))
    return out


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
        log("[keys] Firmware Keys page fail %s: %s" % (page, e))
        wt = ""
    _FWKEYS_CACHE[major] = wt
    return wt


def resolve_keys_page_title(device, build, version):
    """
    从 Firmware Keys/{major}.x 找到 Keys:Codename Build (device) 标题。
    例：[[Keys:Sydney 20A362 (iPhone10,2)|iPhone10,2]]
    """
    t = parse_ios_tuple(version)
    majors = []
    if t:
        majors.append(t[0])
    # 偶发跨大版本列表，多试相邻
    for m in (16, 15, 14, 13, 12, 11):
        if m not in majors:
            majors.append(m)

    pat = re.compile(
        r"\[\[(Keys:[^\|\]]+\(%s\))\|" % re.escape(device),
        re.I,
    )
    for major in majors:
        wt = firmware_keys_wikitext(major)
        if not wt:
            continue
        for m in pat.finditer(wt):
            title = m.group(1).strip()
            # 标题里必须带 buildid
            if build in title.replace(" ", "_") or build in title:
                return title
    # opensearch 兜底（需已知 Codename 时才稳；仍试 build）
    try:
        d = wiki_api(
            action="opensearch",
            search="Keys: %s (%s)" % (build, device),
            limit=8,
        )
        if isinstance(d, list) and len(d) > 1:
            for title in d[1]:
                if device in title and build in title.replace(" ", ""):
                    return title
    except Exception:
        pass
    return None


def parse_keys_template(wt, device, build):
    """解析 {{keys ... | ibec=... | ibeciv=... | ibeckey=...}} → Lite JSON。"""
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
    """
    确保 misc/firmware_keys/{device}_{build}.json 存在。
    缺失则从 TheAppleWiki api.php 抓取。
    返回 True=可用，False=无密钥（构建大概率失败）。
    """
    os.makedirs(KEYS_DIR, exist_ok=True)
    dest = os.path.join(KEYS_DIR, "%s_%s.json" % (device, build))
    if os.path.isfile(dest) and os.path.getsize(dest) > 80:
        return True

    title = resolve_keys_page_title(device, build, version)
    if not title:
        log("[keys] not found on wiki: %s %s @%s" % (device, build, version))
        return False

    # MediaWiki 标题空格/下划线均可
    try:
        d = wiki_api(action="parse", page=title, prop="wikitext")
        wt = d.get("parse", {}).get("wikitext", {}).get("*", "") or ""
    except Exception as e:
        log("[keys] parse fail %s: %s" % (title, e))
        return False

    lite = parse_keys_template(wt, device, build)
    if len(lite) < 2:
        log("[keys] parse empty %s fields" % title)
        return False

    with open(dest, "w", encoding="utf-8") as f:
        json.dump(lite, f)
    log("[keys] saved %s (%d comps) from %s" % (dest, len(lite), title))
    return True


def zip_exists(device, version, min_bytes=1_000_000):
    path = os.path.join(OUT_DIR, device, "%s.zip" % version)
    return os.path.isfile(path) and os.path.getsize(path) >= min_bytes


def append_list(path, line):
    with open(path, "a", encoding="utf-8") as f:
        f.write(line.rstrip() + "\n")


def run_docker_build(device, version, timeout=7200):
    """调用现有 docker-build-sshrd.sh {device} {version}。"""
    if not os.path.isfile(DOCKER_BUILDER):
        raise FileNotFoundError("missing %s" % DOCKER_BUILDER)
    # 规范：只传逗号机型
    device = norm_device(device)
    cmd = ["bash", DOCKER_BUILDER, device, version]
    log("[build] %s" % " ".join(cmd))
    env = os.environ.copy()
    env["CHECKM8_ROOT"] = ROOT
    p = subprocess.run(
        cmd,
        cwd=ROOT,
        env=env,
        timeout=timeout,
    )
    return p.returncode == 0 and zip_exists(device, version)


def purge_dot_dirs():
    """删除误建的点号目录（iPhone10.2 等）。"""
    if not os.path.isdir(OUT_DIR):
        return
    for name in os.listdir(OUT_DIR):
        if "." in name and "," not in name and name.startswith("iPhone"):
            path = os.path.join(OUT_DIR, name)
            log("[clean] remove dot-path %s" % path)
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
            elif os.path.isfile(path):
                try:
                    os.remove(path)
                except OSError:
                    pass


def version_sort_key(v):
    return parse_ios_tuple(v) or (0, 0, 0)


def pick_default_ios(device, versions):
    """优先 dkxuanye 推荐版，否则取最高正式版。"""
    if not versions:
        return None
    pref = PREFERRED_DEFAULT.get(device)
    if pref and pref in versions:
        return pref
    # 次选：同大版本最高非 APFS 友好（<=16.0.x）再否则最高
    le160 = [v for v in versions if parse_ios_tuple(v) and parse_ios_tuple(v) < (16, 1, 0)]
    pool = le160 or versions
    return sorted(pool, key=version_sort_key)[-1]


def refresh_default_link(device):
    ddir = os.path.join(OUT_DIR, device)
    if not os.path.isdir(ddir):
        return
    versions = []
    for fn in os.listdir(ddir):
        if not fn.endswith(".zip") or fn == "default.zip":
            continue
        ver = fn[:-4]
        if zip_exists(device, ver):
            versions.append(ver)
    default_ver = pick_default_ios(device, versions)
    if not default_ver:
        return
    src = os.path.join(ddir, "%s.zip" % default_ver)
    dst = os.path.join(ddir, "default.zip")
    try:
        if os.path.islink(dst) or os.path.isfile(dst):
            os.remove(dst)
    except OSError:
        pass
    try:
        os.symlink(os.path.basename(src), dst)
        log("[default] %s -> %s (symlink)" % (device, default_ver))
    except OSError:
        shutil.copy2(src, dst)
        log("[default] %s -> %s (copy)" % (device, default_ver))
    # 顶层兼容包（仅逗号名）
    top = os.path.join(OUT_DIR, "%s.zip" % device)
    try:
        shutil.copy2(src, top)
    except OSError as e:
        log("[default] top zip warn: %s" % e)


def write_manifest():
    """仅逗号设备节点。"""
    devices = {}
    if os.path.isdir(OUT_DIR):
        for name in sorted(os.listdir(OUT_DIR)):
            path = os.path.join(OUT_DIR, name)
            if not os.path.isdir(path):
                continue
            if "." in name and "," not in name:
                continue  # 跳过点号垃圾目录
            try:
                device = norm_device(name)
            except ValueError:
                continue
            versions = {}
            for fn in sorted(os.listdir(path)):
                if not fn.endswith(".zip") or fn == "default.zip":
                    continue
                ver = fn[:-4]
                z = os.path.join(path, fn)
                if os.path.isfile(z) and os.path.getsize(z) > 1000:
                    versions[ver] = "ramdisks/%s/%s.zip" % (device, ver)
            if not versions:
                continue
            default_ios = pick_default_ios(device, list(versions.keys()))
            devices[device] = {
                "defaultIos": default_ios,
                "versions": versions,
                "url": "ramdisks/%s/%s.zip" % (device, default_ios),
            }
    out = {
        "baseUrl": BASE_URL,
        "devices": devices,
        "updatedAt": datetime.datetime.utcnow().isoformat() + "Z",
        "note": "A11 batch via Docker+SSHRD_Script_Lite; comma ProductType only",
    }
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    log("[manifest] devices=%d -> %s" % (len(devices), MANIFEST))


def disk_free_gb():
    st = os.statvfs(ROOT)
    return (st.f_bavail * st.f_frsize) / (1024 ** 3)


def cleanup_temp():
    """省盘：清 IPSW / docker 悬空层。"""
    cache = os.path.join(ROOT, "build", "lite-cache")
    if os.path.isdir(cache):
        for root, _dirs, files in os.walk(cache):
            for fn in files:
                if fn.endswith(".ipsw"):
                    try:
                        os.remove(os.path.join(root, fn))
                    except OSError:
                        pass
    subprocess.run(
        ["docker", "system", "prune", "-f"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def build_one(device, fw, include_apfs, dry_run):
    version = fw["version"]
    build = fw["buildid"]
    device = norm_device(device)

    if zip_exists(device, version):
        log("[skip] exists %s @%s" % (device, version))
        append_list(SKIP_LIST, "%s %s exists" % (device, version))
        return "skip"

    if needs_apfs(version) and not include_apfs:
        log("[skip] APFS (Linux) %s @%s — 用 --include-apfs 强制尝试" % (device, version))
        append_list(SKIP_LIST, "%s %s apfs-linux" % (device, version))
        return "skip"

    if dry_run:
        log("[dry] would build %s @%s (%s)" % (device, version, build))
        return "dry"

    has_keys = ensure_keys(device, build, version)
    if not has_keys:
        log("[skip] no keys %s %s @%s" % (device, build, version))
        append_list(SKIP_LIST, "%s %s no-keys" % (device, version))
        return "skip"

    if disk_free_gb() < 8:
        log("[warn] disk < 8G, cleanup")
        cleanup_temp()
        if disk_free_gb() < 6:
            log("[fail] disk too low")
            append_list(FAIL_LIST, "%s %s disk" % (device, version))
            return "fail"

    try:
        ok = run_docker_build(device, version)
    except subprocess.TimeoutExpired:
        log("[fail] timeout %s @%s" % (device, version))
        append_list(FAIL_LIST, "%s %s timeout" % (device, version))
        return "fail"
    except Exception as e:
        log("[fail] %s @%s %s" % (device, version, e))
        append_list(FAIL_LIST, "%s %s %s" % (device, version, e))
        return "fail"

    # 禁止点号产物残留
    purge_dot_dirs()
    # 若 docker 脚本仍写了点号副本，删掉
    dot = device.replace(",", ".")
    for p in (
        os.path.join(OUT_DIR, dot),
        os.path.join(OUT_DIR, "%s.zip" % dot),
    ):
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
        elif os.path.isfile(p):
            try:
                os.remove(p)
            except OSError:
                pass

    if ok:
        log("[ok] %s @%s" % (device, version))
        append_list(OK_LIST, "%s %s" % (device, version))
        refresh_default_link(device)
        write_manifest()
        cleanup_temp()
        return "ok"

    log("[fail] build %s @%s" % (device, version))
    append_list(FAIL_LIST, "%s %s build" % (device, version))
    cleanup_temp()
    return "fail"


def main():
    ap = argparse.ArgumentParser(description="A11 batch SSHRD Lite builder")
    ap.add_argument(
        "--only",
        nargs="*",
        default=None,
        help="只构建指定机型，如 iPhone10,2 iPhone10.5",
    )
    ap.add_argument("--ios", nargs="*", default=None, help="只构建指定 iOS，如 16.0 15.7.8")
    ap.add_argument("--max", type=int, default=0, help="最多构建 N 个（调试用，0=不限）")
    ap.add_argument(
        "--include-apfs",
        action="store_true",
        help="包含 iOS 16.1+（Linux Docker 通常因 APFS 失败）",
    )
    ap.add_argument("--dry-run", action="store_true", help="只列任务不构建")
    ap.add_argument(
        "--manifest-only",
        action="store_true",
        help="只刷新 manifest / default.zip",
    )
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(KEYS_DIR, exist_ok=True)

    if args.manifest_only:
        for d in A11_DEVICES:
            if os.path.isdir(os.path.join(OUT_DIR, d)):
                refresh_default_link(d)
        purge_dot_dirs()
        write_manifest()
        return 0

    devices = A11_DEVICES
    if args.only:
        devices = [norm_device(x) for x in args.only]

    # 清空本次列表头（追加模式；若要全新可手动删）
    for p in (OK_LIST, FAIL_LIST, SKIP_LIST):
        if not os.path.isfile(p):
            open(p, "a").close()

    log("======== build_all_a11 start ROOT=%s ========" % ROOT)
    log("devices=%s include_apfs=%s dry=%s" % (devices, args.include_apfs, args.dry_run))
    if not os.path.isfile(DOCKER_BUILDER):
        log("[fatal] missing docker builder: %s" % DOCKER_BUILDER)
        return 2
    if not os.path.isfile(os.path.join(LITE_DIR, "sshrd_lite.sh")):
        log("[fatal] missing sshrd_lite.sh under %s" % LITE_DIR)
        return 2

    built = 0
    stats = {"ok": 0, "fail": 0, "skip": 0, "dry": 0}

    for device in devices:
        try:
            fws = fetch_firmwares(device)
        except Exception as e:
            log("[fail] ipsw.me %s: %s" % (device, e))
            append_list(FAIL_LIST, "%s ipsw %s" % (device, e))
            continue
        log("[ipsw] %s firmwares=%d" % (device, len(fws)))

        if args.ios:
            want = set(args.ios)
            fws = [f for f in fws if f["version"] in want]

        for fw in fws:
            if args.max and built >= args.max:
                log("[stop] reached --max %d" % args.max)
                write_manifest()
                log("stats=%s" % stats)
                return 0
            st = build_one(device, fw, args.include_apfs, args.dry_run)
            stats[st] = stats.get(st, 0) + 1
            if st in ("ok", "fail", "dry"):
                built += 1
            # 轻微节流，避免打爆 wiki / ipsw
            time.sleep(0.3)

        refresh_default_link(device)

    purge_dot_dirs()
    write_manifest()
    log("======== done stats=%s ========" % stats)
    log("ok -> %s" % OK_LIST)
    log("fail -> %s" % FAIL_LIST)
    log("skip -> %s" % SKIP_LIST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
