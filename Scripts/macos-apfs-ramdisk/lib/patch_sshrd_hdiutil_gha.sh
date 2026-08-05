#!/usr/bin/env bash
# Patch SSHRD_Script_Lite Darwin iOS>=16.1 ramdisk packing to avoid GHA hdiutil hang.
# Root cause: `hdiutil create -srcfolder` on a *live attached* APFS DMG often stalls
# forever on GitHub macos runners (XProtect / diskimagesd). Fix: ditto to a staging
# directory, detach, then create from the staging folder; wrap with retries + timeout.
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
text = path.read_text(encoding="utf-8", errors="ignore")
bak = path.with_suffix(path.suffix + ".bak_pre_hdiutil_gha")
if not bak.exists():
    bak.write_text(text, encoding="utf-8")

marker = "AC_HDIUTIL_GHA_PATCH"
if marker in text:
    print("[ok] already patched", path)
    raise SystemExit(0)

old = r"""	elif [ "$platform" = 'Darwin' ] && [ "$check_ios" -ge '161' ]; then
		hdiutil attach -mountpoint '/tmp/SSHRD' "$temp_folder"'/ramdisk.dmg'
		hdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage -format UDZO -fs HFS+ -layout NONE -srcfolder '/tmp/SSHRD' -copyuid root "$temp_folder"'/reassigned_ramdisk.dmg'
        hdiutil detach -force '/tmp/SSHRD'
        hdiutil attach -mountpoint '/tmp/SSHRD' "$temp_folder"'/reassigned_ramdisk.dmg'
		./tools/Darwin/gtar -x --no-overwrite-dir -f 'misc/sshtars/ssh.tar.gz' -C '/tmp/SSHRD/'
		hdiutil detach -force '/tmp/SSHRD'
		hdiutil resize -sectors min "$temp_folder"'/reassigned_ramdisk.dmg'"""

# Tolerate mixed tabs/spaces on detach lines from upstream
old_re = re.compile(
    r"""\telif \[ \"\$platform\" = 'Darwin' \] && \[ \"\$check_ios\" -ge '161' \]; then\r?\n"""
    r"""\t\thdiutil attach -mountpoint '/tmp/SSHRD' \"\$temp_folder\"'/ramdisk\.dmg'\r?\n"""
    r"""\t\thdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage -format UDZO -fs HFS\+ -layout NONE -srcfolder '/tmp/SSHRD' -copyuid root \"\$temp_folder\"'/reassigned_ramdisk\.dmg'\r?\n"""
    r"""[ \t]*hdiutil detach -force '/tmp/SSHRD'\r?\n"""
    r"""[ \t]*hdiutil attach -mountpoint '/tmp/SSHRD' \"\$temp_folder\"'/reassigned_ramdisk\.dmg'\r?\n"""
    r"""\t\t\./tools/Darwin/gtar -x --no-overwrite-dir -f 'misc/sshtars/ssh\.tar\.gz' -C '/tmp/SSHRD/'\r?\n"""
    r"""\t\thdiutil detach -force '/tmp/SSHRD'\r?\n"""
    r"""\t\thdiutil resize -sectors min \"\$temp_folder\"'/reassigned_ramdisk\.dmg'""",
    re.M,
)

new = r"""	elif [ "$platform" = 'Darwin' ] && [ "$check_ios" -ge '161' ]; then
		# """ + marker + r"""
		# GHA-safe APFS→HFS reassign: never hdiutil create -srcfolder a live mount.
		_ac_mp='/private/tmp/SSHRD'
		_ac_stage='/private/tmp/SSHRD_STAGE'
		_ac_run() {
			# usage: _ac_run <sec> <cmd...>
			_ac_to="$1"; shift
			echo "[AC-hdiutil] RUN($*) timeout=${_ac_to}s"
			perl -e 'alarm shift @ARGV; exec @ARGV' "$_ac_to" "$@"
		}
		_ac_retry() {
			_ac_n=0
			_ac_max=4
			_ac_to="$1"; shift
			until _ac_run "$_ac_to" "$@"; do
				_ac_n=$((_ac_n+1))
				echo "[AC-hdiutil] fail attempt $_ac_n/$_ac_max: $*"
				if [ "$_ac_n" -ge "$_ac_max" ]; then
					echo "[AC-hdiutil] FATAL after $_ac_max attempts"
					return 1
				fi
				sync || true
				sleep $((5 * _ac_n))
				# clear stuck diskimages helpers
				killall -9 hdiutil diskimages-helper 2>/dev/null || true
				sleep 2
			done
		}
		rm -rf "$_ac_mp" "$_ac_stage" 2>/dev/null || true
		mkdir -p "$_ac_mp" "$_ac_stage"
		hdiutil detach -force "$_ac_mp" 2>/dev/null || true
		hdiutil detach -force '/tmp/SSHRD' 2>/dev/null || true
		echo '[AC-hdiutil] attach original APFS ramdisk.dmg'
		_ac_retry 120 hdiutil attach -nobrowse -owners off -noverify -mountpoint "$_ac_mp" "$temp_folder"'/ramdisk.dmg'
		echo '[AC-hdiutil] ditto mount -> stage (avoid create -srcfolder live mount)'
		rm -rf "$_ac_stage"
		mkdir -p "$_ac_stage"
		_ac_retry 300 ditto "$_ac_mp" "$_ac_stage"
		sync || true
		echo '[AC-hdiutil] detach APFS mount'
		_ac_retry 60 hdiutil detach -force "$_ac_mp" || true
		sleep 2
		rm -f "$temp_folder"'/reassigned_ramdisk.dmg'
		echo '[AC-hdiutil] create HFS reassigned from STAGE'
		_ac_retry 600 hdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage -format UDZO -fs HFS+ -layout NONE -srcfolder "$_ac_stage" -copyuid root "$temp_folder"'/reassigned_ramdisk.dmg'
		rm -rf "$_ac_stage"
		mkdir -p "$_ac_mp"
		echo '[AC-hdiutil] attach reassigned HFS'
		_ac_retry 120 hdiutil attach -nobrowse -owners off -noverify -mountpoint "$_ac_mp" "$temp_folder"'/reassigned_ramdisk.dmg'
		echo '[AC-hdiutil] extract ssh.tar.gz'
		./tools/Darwin/gtar -x --no-overwrite-dir -f 'misc/sshtars/ssh.tar.gz' -C "$_ac_mp/"
		sync || true
		echo '[AC-hdiutil] detach HFS'
		_ac_retry 60 hdiutil detach -force "$_ac_mp"
		echo '[AC-hdiutil] resize min (best-effort)'
		_ac_run 120 hdiutil resize -sectors min "$temp_folder"'/reassigned_ramdisk.dmg' || echo '[AC-hdiutil] resize skipped/failed (ok)'
"""

m = old_re.search(text)
if not m:
    # fallback: looser search around the create -srcfolder line
    if "hdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage" not in text:
        raise SystemExit("Darwin>=161 hdiutil block not found")
    raise SystemExit("regex miss; sshrd_lite.sh layout changed — inspect manually")

text = text[: m.start()] + new + text[m.end() :]
path.write_text(text, encoding="utf-8")
print("[ok] patched", path, "marker=", marker)
PY
