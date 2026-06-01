#!/usr/bin/env bash
# Verifies the bundled ffmpeg/ffprobe tools are present, self-contained
# (no non-system dynamic library dependencies), runnable, and able to
# probe a Matroska container. Acts as a build-dependency gate so packaged
# Orbisonic builds can decode MKV/MKA/AC3/Atmos sources on any Mac.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="${ORBISONIC_APP_BUNDLE:-$repo_root/Orbisonic.app}"
src_tools="$repo_root/Sources/Orbisonic/Resources/Tools"
bundle_tools="$app_bundle/Contents/Resources/Tools"

fail=0
pass() { printf '  ok   %s\n' "$1"; }
err()  { printf '  FAIL %s\n' "$1"; fail=1; }

# A self-contained binary may only link system libraries: /usr/lib/* and
# /System/*. Anything under /opt, /usr/local, @rpath, or a Cellar path means
# the binary depends on tools that will not exist on a clean Mac.
check_self_contained() {
  local bin="$1"
  local bad
  bad="$(otool -L "$bin" 2>/dev/null | tail -n +2 \
    | awk '{print $1}' \
    | grep -vE '^/usr/lib/|^/System/' || true)"
  if [ -n "$bad" ]; then
    err "$bin links non-system libraries:"
    printf '         %s\n' $bad
  else
    pass "$bin is self-contained (system libs only)"
  fi
}

check_binary() {
  local label="$1" bin="$2"
  if [ ! -f "$bin" ]; then
    err "$label missing: $bin"
    return
  fi
  if [ ! -x "$bin" ]; then
    err "$label not executable: $bin"
    return
  fi
  pass "$label present and executable"
  if ! file "$bin" | grep -q 'arm64'; then
    err "$label is not an arm64 Mach-O binary"
  else
    pass "$label is arm64 Mach-O"
  fi
  check_self_contained "$bin"
  if "$bin" -version >/dev/null 2>&1; then
    pass "$label runs ($("$bin" -version 2>/dev/null | head -1))"
  else
    err "$label failed to execute -version (missing dylibs?)"
  fi
}

echo "== Source tree tools ($src_tools) =="
check_binary "src ffmpeg"  "$src_tools/ffmpeg"
check_binary "src ffprobe" "$src_tools/ffprobe"

echo "== Bundled tools ($bundle_tools) =="
check_binary "bundle ffmpeg"  "$bundle_tools/ffmpeg"
check_binary "bundle ffprobe" "$bundle_tools/ffprobe"

echo "== Matroska probe round-trip =="
ffmpeg_bin="$src_tools/ffmpeg"
ffprobe_bin="$src_tools/ffprobe"
if [ -x "$ffmpeg_bin" ] && [ -x "$ffprobe_bin" ]; then
  tmp_mka="$(mktemp -t orbisonic_probe).mka"
  if "$ffmpeg_bin" -y -f lavfi -i "sine=frequency=440:duration=1" \
       -c:a flac "$tmp_mka" >/dev/null 2>&1; then
    pass "synthesized test Matroska file"
    if "$ffprobe_bin" -v error -select_streams a:0 \
         -show_entries stream=codec_name -of csv=p=0 "$tmp_mka" \
         2>/dev/null | grep -q flac; then
      pass "ffprobe decoded Matroska audio stream"
    else
      err "ffprobe could not read the Matroska audio stream"
    fi
  else
    err "ffmpeg could not synthesize a Matroska file"
  fi
  rm -f "$tmp_mka"
else
  err "cannot run Matroska round-trip: source tools not runnable"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "VERIFICATION FAILED"
  exit 1
fi
