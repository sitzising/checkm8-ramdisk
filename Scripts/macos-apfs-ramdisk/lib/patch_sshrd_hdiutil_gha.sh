#!/usr/bin/env bash
# Patch SSHRD_Script_Lite Darwin iOS>=16.1 ramdisk packing for GitHub macos runners.
#
# GHA cannot reliably run: hdiutil create -srcfolder ... (hangs until alarm).
# V6 strategy:
#   1) attach APFS ramdisk.dmg → ditto to STAGE → detach
#   2) create blank UDIF HFS+ image (NO -srcfolder / NO -format)
#   3) attach blank → ditto STAGE in → extract ssh.tar.gz (overwrite)
#   4) VERIFY /etc/master.passwd has root: + dropbear
#   5) soft detach; NO resize -sectors min (that truncated SSH accounts in V5)
#   6) remount-verify → use as reassigned_ramdisk.dmg for img4 pack
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
marker = "AC_HDIUTIL_GHA_PATCH_V6"

# If bak itself was snapshotted after an older AC patch, recover upstream-ish block
# by stripping any prior AC_HDIUTIL block back to a placeholder that our replacer matches.
if "AC_HDIUTIL_GHA_PATCH_" in text and "hdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage" not in text:
    # Replace whole Darwin>=161 AC block with canonical upstream so regex below can match.
    ac_block = re.compile(
        r"\telif \[ \"\$platform\" = 'Darwin' \] && \[ \"\$check_ios\" -ge '161' \]; then\r?\n"
        r"(?:.*\n)*?"
        r"\t\thdiutil resize -sectors min \"\$temp_folder\"'/reassigned_ramdisk\.dmg'",
        re.M,
    )
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
    text2, n = ac_block.subn(upstream, text, count=1)
    if n:
        text = text2
        bak.write_text(text, encoding="utf-8")
        print("[ok] normalized bak from older AC patch → upstream skeleton")
    else:
        print("[WARN] bak has AC patch but could not normalize; trying direct replace")

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
		# GHA-safe: blank UDIF HFS + ditto; verify ssh accounts before soft detach.
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
			# Prefer clean unmount so gtar/ditto writes are not discarded.
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
		echo '[AC-hdiutil] detach APFS'
		_ac_detach_soft
		sleep 2
		rm -f "$_ac_out"
		echo '[AC-hdiutil] create blank UDIF HFS+ 256m (-type only, no -format)'
		_ac_must 180 hdiutil create -size 256m -fs HFS+ -volname SSHRD -layout NONE -type UDIF -ov "$_ac_out"
		mkdir -p "$_ac_mp"
		echo '[AC-hdiutil] attach blank HFS'
		_ac_must 180 hdiutil attach -nobrowse -owners off -noverify -mountpoint "$_ac_mp" "$_ac_out"
		echo '[AC-hdiutil] ditto STAGE -> HFS'
		_ac_must 300 ditto "$_ac_stage" "$_ac_mp"
		echo '[AC-hdiutil] extract ssh.tar.gz (allow overwrite)'
		# Drop --no-overwrite-dir so SSHRD account files always replace Apple stubs.
		./tools/Darwin/gtar -x -f 'misc/sshtars/ssh.tar.gz' -C "$_ac_mp/" || { echo '[AC-hdiutil] gtar failed'; exit 1; }
		sync || true
		sleep 1
		sync || true
		echo '[AC-hdiutil] verify SSH accounts on mount'
		_ac_mpw="$_ac_mp/etc/master.passwd"
		if [ ! -f "$_ac_mpw" ]; then
			echo "[AC-hdiutil] FATAL missing $_ac_mpw after gtar"
			ls -la "$_ac_mp/etc" 2>/dev/null || true
			exit 1
		fi
		if ! grep -q '^root:' "$_ac_mpw"; then
			echo "[AC-hdiutil] FATAL master.passwd has no root: line"
			head -n 20 "$_ac_mpw" || true
			exit 1
		fi
		echo '[AC-hdiutil] master.passwd root OK:'
		grep '^root:' "$_ac_mpw" | head -n 2 || true
		# Common SSHRD dropbear locations (best-effort)
		ls -la "$_ac_mp/usr/local/bin/dropbear" "$_ac_mp/bin/dropbear" "$_ac_mp/usr/sbin/sshd" 2>/dev/null || true
		rm -rf "$_ac_stage"
		echo '[AC-hdiutil] soft detach HFS'
		_ac_detach_soft
		# DO NOT hdiutil resize -sectors min here: it can truncate the HFS volume and
		# drop ssh.tar.gz account files that verified OK on the full 256m image.
		# (V5 bug: verify-before-resize produced logo-without-SSH packs.)
		echo '[AC-hdiutil] skip resize (keep 256m to preserve SSH accounts)'
		echo '[AC-hdiutil] final remount verify'
		mkdir -p "$_ac_mp"
		_ac_must 120 hdiutil attach -readonly -nobrowse -noverify -mountpoint "$_ac_mp" "$_ac_out"
		if ! grep -q '^root:' "$_ac_mp/etc/master.passwd"; then
			echo '[AC-hdiutil] FATAL root: missing after remount — writes were lost'
			_ac_detach_soft
			exit 1
		fi
		# Extra: require a real SSHRD-style root shell path (not empty/broken passwd)
		if ! grep -E '^root:[^:]*:[0-9]+:[0-9]+:' "$_ac_mp/etc/master.passwd" >/dev/null; then
			echo '[AC-hdiutil] FATAL root: line malformed'
			head -n 30 "$_ac_mp/etc/master.passwd" || true
			_ac_detach_soft
			exit 1
		fi
		grep '^root:' "$_ac_mp/etc/master.passwd" | head -n 2 || true
		test -x "$_ac_mp/usr/local/bin/dropbear" || { echo '[AC-hdiutil] FATAL dropbear missing'; _ac_detach_soft; exit 1; }
		echo '[AC-hdiutil] persisted root+dropbear OK'
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
