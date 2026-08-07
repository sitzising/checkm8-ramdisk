#!/usr/bin/env bash
# Patch SSHRD_Script_Lite Darwin iOS>=16.1 ramdisk packing for GitHub macos runners.
#
# GHA cannot reliably run: hdiutil create -srcfolder ... (hangs until alarm).
# V2 strategy:
#   1) attach APFS ramdisk.dmg → ditto to STAGE → detach
#   2) create blank UDRW HFS+ image (NO -srcfolder)
#   3) attach blank → ditto STAGE in → extract ssh.tar.gz → detach
#   4) use that dmg as reassigned_ramdisk.dmg for img4 pack
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
    # Prefer upstream pristine; if already V1-patched, still snapshot current once.
    bak.write_text(raw, encoding="utf-8")

# Always re-apply from bak so V1→V2 upgrades work on cached runners.
text = bak.read_text(encoding="utf-8", errors="ignore")
marker = "AC_HDIUTIL_GHA_PATCH_V4"

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
		# GHA-safe: blank UDIF HFS + ditto (never create -srcfolder/-format).
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
		_ac_retry 90 hdiutil detach -force "$_ac_mp" || true
		sleep 2
		rm -f "$_ac_out"
		# Blank HFS+ (no -srcfolder — that path hangs on GHA)
		echo '[AC-hdiutil] create blank UDIF HFS+ 256m (-type only, no -format)'
		_ac_must 180 hdiutil create -size 256m -fs HFS+ -volname SSHRD -layout NONE -type UDIF -ov "$_ac_out"
		mkdir -p "$_ac_mp"
		echo '[AC-hdiutil] attach blank HFS'
		_ac_must 180 hdiutil attach -nobrowse -owners off -noverify -mountpoint "$_ac_mp" "$_ac_out"
		echo '[AC-hdiutil] ditto STAGE -> HFS'
		_ac_must 300 ditto "$_ac_stage" "$_ac_mp"
		echo '[AC-hdiutil] extract ssh.tar.gz'
		./tools/Darwin/gtar -x --no-overwrite-dir -f 'misc/sshtars/ssh.tar.gz' -C "$_ac_mp/" || { echo '[AC-hdiutil] gtar failed'; exit 1; }
		sync || true
		rm -rf "$_ac_stage"
		echo '[AC-hdiutil] detach HFS'
		_ac_must 120 hdiutil detach -force "$_ac_mp"
		echo '[AC-hdiutil] resize min (best-effort)'
		_ac_run 120 hdiutil resize -sectors min "$_ac_out" || echo '[AC-hdiutil] resize skipped (ok)'
		echo '[AC-hdiutil] ready' "$_ac_out"
		ls -lah "$_ac_out" || { echo '[AC-hdiutil] missing output'; exit 1; }
"""

m = old_re.search(text)
if not m:
    if "hdiutil create -size 210m -imagekey diskimage-class=CRawDiskImage" not in text and marker not in text:
        # already something else?
        raise SystemExit("Darwin>=161 upstream hdiutil block not found in bak")
    if marker in text:
        path.write_text(text, encoding="utf-8")
        print("[ok] bak already has", marker)
        raise SystemExit(0)
    raise SystemExit("regex miss on bak; inspect sshrd_lite.sh")

text = text[: m.start()] + new + text[m.end() :]
path.write_text(text, encoding="utf-8")
print("[ok] patched", path, "marker=", marker)
PY
