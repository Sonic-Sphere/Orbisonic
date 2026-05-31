#!/usr/bin/env bash
# Fetches self-contained (static) arm64 ffmpeg/ffprobe helper tools and installs
# them into Sources/Orbisonic/Resources/Tools so packaged builds can probe and
# demux MKV/MKA (AC3/Atmos/Auro) sources on any Apple Silicon Mac.
#
# The binaries are intentionally NOT committed to git (they are ~50 MB each and
# gitignored). Run this once after cloning, or whenever the Tools directory is
# empty. The downloads are integrity-checked against pinned SHA256 hashes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest_dir="$repo_root/Sources/Orbisonic/Resources/Tools"
mkdir -p "$dest_dir"

# osxexperts.net FFmpeg 8.1 static builds, Apple Silicon (arm64).
# Hashes are the SHA256 of the extracted binary (not the .zip).
ffmpeg_url="https://www.osxexperts.net/ffmpeg81arm.zip"
ffprobe_url="https://www.osxexperts.net/ffprobe81arm.zip"
ffmpeg_sha="9a08d61f9328e8164ba560ee7a79958e357307fcfeea6fe626b7d66cdc287028"
ffprobe_sha="aab17ac7379c1178aaf400c3ef36cdb67db0b75b1a23eeef2cb9f658be8844e6"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

install_tool() {
  local name="$1" url="$2" want_sha="$3"
  echo "Fetching $name ..."
  curl -fsSL -o "$work_dir/$name.zip" "$url"
  ( cd "$work_dir" && unzip -oq "$name.zip" )
  local bin="$work_dir/$name"
  if [ ! -f "$bin" ]; then
    echo "Error: $name not found in archive from $url" >&2
    exit 1
  fi
  local got_sha
  got_sha="$(shasum -a 256 "$bin" | awk '{print $1}')"
  if [ "$got_sha" != "$want_sha" ]; then
    echo "Error: $name checksum mismatch" >&2
    echo "  expected $want_sha" >&2
    echo "  got      $got_sha" >&2
    exit 1
  fi
  xattr -dr com.apple.quarantine "$bin" 2>/dev/null || true
  codesign --force --sign - "$bin"
  chmod +x "$bin"
  mv "$bin" "$dest_dir/$name"
  echo "Installed $name ($want_sha)"
}

install_tool ffmpeg  "$ffmpeg_url"  "$ffmpeg_sha"
install_tool ffprobe "$ffprobe_url" "$ffprobe_sha"

echo "Done. Tools installed in $dest_dir"
