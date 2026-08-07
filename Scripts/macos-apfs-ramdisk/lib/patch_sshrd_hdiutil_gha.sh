#!/usr/bin/env bash
# Patch SSHRD_Script_Lite Darwin iOS>=16.1 ramdisk packing for GitHub macos runners.
#
# Upstream hangs on GHA: hdiutil create -srcfolder <LIVE APFS mount>
# V7 strategy:
#   1) attach APFS ramdisk.dmg → ditto to STAGE (plain dir) → detach
#   2) hdiutil create -srcfolder STAGE  (NOT live mount — this does NOT hang)
#   3) attach → gtar ssh.tar.gz (overwrite) → verify root:/dropbear
#   4) soft detach → safe resize (limits-min + 32MiB padding) → remount-verify
#   Avoids: blank 256m (V6 iBoot OOM/panic), resize -sectors min (V5 lost SSH accounts)
set -eu
ROOT="${CHECKM8_ROOT:-}"
if [[ -z "$ROOT" ]]; then
  echo "[FAIL] CHECKM8_ROOT not set"
  exit 1
fi
path="${ROOT}/build/SSHRD_Script_Lite/sshrd_lite.sh"
[[ -f "$path" ]] || {
  echo "[FAIL] missing $path"
  exit 1
}

python3 - <<'PY'
import os
import re
from pathlib import Path

root = os.environ["CHECKM8_ROOT"]
path = Path(root) / "build/SSHRD_Script_Lite/sshrd_lite.sh"
bak = path.with_suffix(path.suffix + ".bak_pre_hdiutil_gha")

raw = path.read_text(encoding="utf-8", errors="ignore")
if not bak.exists():
    bak.write_text(raw, encoding="utf-8")

text = bak.read_text(encoding="utf-8", errors="ignore")
marker = "AC_HDIUTIL_GHA_PATCH_V7"

upstream = (
    "\telif [ \"$platform\" = 'Darwin' ] && [ \"$check_ios\" -ge '161' ]; then\n"
    "\t\thdiutil attach -mountpoint '/tmp/SSHRD' \"$temp_folder\"'/ramdisk.dmg'\n"
    "\t\thdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage -format UDZO -fs HFS+ -layout NONE -srcfolder '/tmp/SSHRD' -copyuid root \"$temp_folder\"'/reassigned_ramdisk.dmg'\n"
    "\t\thdiutil detach -force '/tmp/SSHRD'\n"
    "\t\thdiutil attach -mountpoint '/tmp/SSHRD' \"$temp_folder\"'/reassigned_ramdisk.dmg'\n"
    "\t\t./tools/Darwin/gtar -x --no-overwrite-dir -f 'misc/sshtars/ssh.tar.gz' -C '/tmp/SSHRD/'\n"
    "\t\thdiutil detach -force '/tmp/SSHRD'\n"
    "\t\thdiutil resize -sectors min \"$temp_folder\"'/reassigned_ramdisk.dmg'"
)

# Normalize any prior AC patch (V1–V6) back to upstream skeleton
if "AC_HDIUTIL_GHA_PATCH_" in text:
    ac_block = re.compile(
        r"\telif \[ \"\$platform\" = 'Darwin' \] && \[ \"\$check_ios\" -ge '161' \]; then\r?\n"
        r"(?:.*\n)*?"
        r"(?=\telif |\telse |fi\b)",
        re.M,
    )
    # Also try classic ending with resize min (upstream / early patches)
    ac_block2 = re.compile(
        r"\telif \[ \"\$platform\" = 'Darwin' \] && \[ \"\$check_ios\" -ge '161' \]; then\r?\n"
        r"(?:.*\n)*?"
        r"\t\thdiutil resize -sectors min \"\$temp_folder\"'/reassigned_ramdisk\.dmg'",
        re.M,
    )
    text2, n = ac_block2.subn(upstream, text, count=1)
    if not n:
        text2, n = ac_block.subn(upstream + "\n", text, count=1)
    if n:
        text = text2
        bak.write_text(text, encoding="utf-8")
        print("[ok] normalized bak from older AC patch → upstream skeleton")
    else:
        print("[WARN] bak has AC patch but could not normalize")

old_re = re.compile(
    r"\telif \[ \"\$platform\" = 'Darwin' \] && \[ \"\$check_ios\" -ge '161' \]; then\r?\n"
    r"\t\thdiutil attach -mountpoint '/tmp/SSHRD' \"\$temp_folder\"'/ramdisk\.dmg'\r?\n"
    r"\t\thdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage -format UDZO -fs HFS\+ -layout NONE -srcfolder '/tmp/SSHRD' -copyuid root \"\$temp_folder\"'/reassigned_ramdisk\.dmg'\r?\n"
    r"[ \t]*hdiutil detach -force '/tmp/SSHRD'\r?\n"
    r"[ \t]*hdiutil attach -mountpoint '/tmp/SSHRD' \"\$temp_folder\"'/reassigned_ramdisk\.dmg'\r?\n"
    r"\t\t\./tools/Darwin/gtar -x --no-overwrite-dir -f 'misc/sshtars/ssh\.tar\.gz' -C '/tmp/SSHRD/'\r?\n"
    r"\t\thdiutil detach -force '/tmp/SSHRD'\r?\n"
    r"\t\thdiutil resize -sectors min \"\$temp_folder\"'/reassigned_ramdisk\.dmg'",
    re.M,
)

new = r"""	elif [ "$platform" = 'Darwin' ] && [ "$check_ios" -ge '161' ]; then
		# """ + marker + r"""
		# GHA-safe: ditto APFS→STAGE, then create -srcfolder STAGE (not live mount).
		_ac_mp='/private/tmp/SSHRD'
		_ac_stage='/private/tmp/SSHRD_STAGE'
		_ac_out="$temp_folder"'/reassigned_ramdisk.dmg'
		_ac_run() {
			_ac_to="$1"; shift
			echo "[AC-hdiutil] RUN($*) timeout=${_ac_to}s"
			perl -e 'alarm shift @ARGV; exec @ARGV' "$_ac_to" "$@"
		}
		_ac_retry() {
			_ac_n=0
			_ac_max=5
			_ac_to="$1"; shift
			until _ac_run "$_ac_to" "$@"; do
				_ac_n=$((_ac_n+1))
				echo "[AC-hdiutil] fail attempt $_ac_n/$_ac_max: $*"
				if [ "$_ac_n" -ge "$_ac_max" ]; then
					echo "[AC-hdiutil] FATAL after $_ac_max attempts"
					return 1
				fi
				sync || true
				killall -9 hdiutil diskimages-helper 2>/dev/null || true
				sleep $((3 * _ac_n))
			done
		}
		_ac_must() {
			_ac_retry "$@" || { echo "[AC-hdiutil] abort"; exit 1; }
		}
		_ac_detach_soft() {
			sync || true
			sleep 2
			sync || true
			if ! _ac_run 90 hdiutil detach "$_ac_mp"; then
				echo '[AC-hdiutil] soft detach failed; retry force'
				_ac_run 90 hdiutil detach -force "$_ac_mp" || true
			fi
			sleep 1
			sync || true
		}
		_ac_verify_ssh() {
			_ac_mpw="$_ac_mp/etc/master.passwd"
			if [ ! -f "$_ac_mpw" ] || ! grep -q '^root:' "$_ac_mpw"; then
				echo "[AC-hdiutil] FATAL SSH accounts missing ($1)"
				ls -la "$_ac_mp/etc" 2>/dev/null || true
				head -n 20 "$_ac_mpw" 2>/dev/null || true
				return 1
			fi
			if ! grep -E '^root:[^:]*:[0-9]+:[0-9]+:' "$_ac_mpw" >/dev/null; then
				echo "[AC-hdiutil] FATAL root: malformed ($1)"
				return 1
			fi
			test -x "$_ac_mp/usr/local/bin/dropbear" || {
				echo "[AC-hdiutil] FATAL dropbear missing ($1)"
				return 1
			}
			echo "[AC-hdiutil] SSH OK ($1):"
			grep '^root:' "$_ac_mpw" | head -n 1 || true
			return 0
		}
		rm -rf "$_ac_mp" "$_ac_stage" 2>/dev/null || true
		mkdir -p "$_ac_mp" "$_ac_stage"
		hdiutil detach -force "$_ac_mp" 2>/dev/null || true
		hdiutil detach -force '/tmp/SSHRD' 2>/dev/null || true
		echo '[AC-hdiutil] attach original APFS ramdisk.dmg'
		_ac_must 180 hdiutil attach -nobrowse -owners off -noverify -mountpoint "$_ac_mp" "$temp_folder"'/ramdisk.dmg'
		echo '[AC-hdiutil] ditto APFS -> STAGE'
		rm -rf "$_ac_stage"
		mkdir -p "$_ac_stage"
		_ac_must 300 ditto "$_ac_mp" "$_ac_stage"
		sync || true
		du -sh "$_ac_stage" || true
		echo '[AC-hdiutil] detach APFS'
		_ac_detach_soft
		sleep 2
		rm -f "$_ac_out"
		# IMPORTANT: -srcfolder on a plain directory (STAGE), NOT the live APFS mount.
		echo '[AC-hdiutil] create HFS from STAGE (-srcfolder, with -format)'
		_ac_must 300 hdiutil create -srcfolder "$_ac_stage" -format UDIF -fs HFS+ -layout NONE -volname SSHRD -ov "$_ac_out"
		ls -lah "$_ac_out" || true
		mkdir -p "$_ac_mp"
		echo '[AC-hdiutil] attach HFS for ssh.tar.gz'
		_ac_must 180 hdiutil attach -nobrowse -owners off -noverify -mountpoint "$_ac_mp" "$_ac_out"
		echo '[AC-hdiutil] extract ssh.tar.gz (overwrite)'
		./tools/Darwin/gtar -x -f 'misc/sshtars/ssh.tar.gz' -C "$_ac_mp/" || { echo '[AC-hdiutil] gtar failed'; exit 1; }
		sync || true
		sleep 1
		sync || true
		_ac_verify_ssh 'after-gtar' || exit 1
		rm -rf "$_ac_stage"
		echo '[AC-hdiutil] soft detach before resize'
		_ac_detach_soft
		# Safe shrink: min from -limits + 32MiB padding (not bare -sectors min)
		echo '[AC-hdiutil] safe resize (min+32MiB)'
		_ac_limits="$(hdiutil resize -limits "$_ac_out" 2>/dev/null | tail -n 1 | tr -s '[:space:]' ' ')"
		echo "[AC-hdiutil] resize -limits: $_ac_limits"
		_ac_min="$(echo "$_ac_limits" | awk '{print $1}')"
		if [[ -n "$_ac_min" && "$_ac_min" -gt 0 ]]; then
			_ac_pad=$((32 * 1024 * 1024 / 512))
			_ac_target=$((_ac_min + _ac_pad))
			echo "[AC-hdiutil] resize -sectors $_ac_target (min=$_ac_min pad=$_ac_pad)"
			_ac_run 180 hdiutil resize -sectors "$_ac_target" "$_ac_out" || echo '[AC-hdiutil] resize skipped (ok)'
		else
			echo '[AC-hdiutil] WARN could not parse limits; leave size as-is'
		fi
		echo '[AC-hdiutil] final remount verify'
		mkdir -p "$_ac_mp"
		_ac_must 120 hdiutil attach -readonly -nobrowse -noverify -mountpoint "$_ac_mp" "$_ac_out"
		_ac_verify_ssh 'after-resize' || { _ac_detach_soft; exit 1; }
		_ac_detach_soft
		echo '[AC-hdiutil] ready' "$_ac_out"
		ls -lah "$_ac_out" || { echo '[AC-hdiutil] missing output'; exit 1; }
"""

m = old_re.search(text)
if not m:
    if marker in text:
        path.write_text(text, encoding="utf-8")
        print("[ok] already", marker)
        raise SystemExit(0)
    raise SystemExit("Darwin>=161 hdiutil block not found in bak; inspect sshrd_lite.sh")

text = text[: m.start()] + new + text[m.end() :]
path.write_text(text, encoding="utf-8")
print("[ok] patched", path, "marker=", marker)
PY
