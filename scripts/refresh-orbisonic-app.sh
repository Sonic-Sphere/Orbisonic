#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

app_name="Orbisonic"
app_version="${1:-1.3.1}"
bundle_identifier="${ORBISONIC_BUNDLE_IDENTIFIER:-audio.orbisonic.app.current}"
bundle_path="$repo_root/${app_name}.app"
binary_path="$repo_root/.build/arm64-apple-macosx/debug/${app_name}"
resource_bundle_path="$repo_root/.build/arm64-apple-macosx/debug/${app_name}_${app_name}.bundle"
icon_path="$repo_root/Sources/Orbisonic/Resources/AppIcon/${app_name}.icns"
tools_src_dir="$repo_root/Sources/Orbisonic/Resources/Tools"
build_home="$repo_root/.build/dev-home"
module_cache_path="$repo_root/.build/module-cache"
plist_path="$bundle_path/Contents/Info.plist"
plist_buddy="/usr/libexec/PlistBuddy"

# Stable code-signing identity. A dedicated keychain (created once, headless)
# keeps the cdhash / Designated Requirement constant across rebuilds, so macOS
# TCC permissions (mic, files) persist instead of resetting on every build.
# Falls back to ad-hoc signing if the keychain/identity is absent.
sign_id="${ORBISONIC_SIGN_IDENTITY:-Orbisonic Local Signing}"
sign_kc="${ORBISONIC_SIGN_KEYCHAIN:-$HOME/Library/Keychains/orbisonic-signing.keychain-db}"
sign_kc_pass="${ORBISONIC_SIGN_KEYCHAIN_PASSWORD:-orbisonic-signing}"
if [ -f "$sign_kc" ] \
   && security unlock-keychain -p "$sign_kc_pass" "$sign_kc" 2>/dev/null \
   && security find-identity "$sign_kc" 2>/dev/null | grep -qF "$sign_id"; then
  codesign_sign=(--sign "$sign_id" --keychain "$sign_kc")
  echo "Signing with stable identity: $sign_id"
else
  codesign_sign=(--sign -)
  echo "Stable signing identity not found; using ad-hoc signing (TCC permissions will reset)." >&2
fi

set_plist_string() {
  local key="$1"
  local value="$2"

  if ! "$plist_buddy" -c "Set :$key $value" "$plist_path" >/dev/null 2>&1; then
    "$plist_buddy" -c "Add :$key string $value" "$plist_path" >/dev/null
  fi
}

ensure_resource_bundle_info() {
  local bundle_dir="$1"
  local bundle_plist="$bundle_dir/Info.plist"

  if [ ! -d "$bundle_dir" ]; then
    return 0
  fi

  if [ ! -f "$bundle_plist" ]; then
    /usr/bin/plutil -create xml1 "$bundle_plist"
  fi

  if ! "$plist_buddy" -c "Print :CFBundleIdentifier" "$bundle_plist" >/dev/null 2>&1; then
    "$plist_buddy" -c "Add :CFBundleIdentifier string audio.orbisonic.resources" "$bundle_plist" >/dev/null
  fi
  if ! "$plist_buddy" -c "Print :CFBundleName" "$bundle_plist" >/dev/null 2>&1; then
    "$plist_buddy" -c "Add :CFBundleName string Orbisonic Resources" "$bundle_plist" >/dev/null
  fi
  if ! "$plist_buddy" -c "Print :CFBundlePackageType" "$bundle_plist" >/dev/null 2>&1; then
    "$plist_buddy" -c "Add :CFBundlePackageType string BNDL" "$bundle_plist" >/dev/null
  fi
  if ! "$plist_buddy" -c "Print :CFBundleShortVersionString" "$bundle_plist" >/dev/null 2>&1; then
    "$plist_buddy" -c "Add :CFBundleShortVersionString string $app_version" "$bundle_plist" >/dev/null
  fi
  if ! "$plist_buddy" -c "Print :CFBundleVersion" "$bundle_plist" >/dev/null 2>&1; then
    "$plist_buddy" -c "Add :CFBundleVersion string $app_version" "$bundle_plist" >/dev/null
  fi
  plutil -lint "$bundle_plist" >/dev/null
}

if [ ! -d "$bundle_path" ]; then
  echo "Missing app bundle: $bundle_path" >&2
  exit 1
fi

mkdir -p "$build_home" "$module_cache_path"

env \
  DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  HOME="$build_home" \
  CLANG_MODULE_CACHE_PATH="$module_cache_path" \
  swift build

if [ ! -x "$binary_path" ]; then
  echo "Missing built executable: $binary_path" >&2
  exit 1
fi

cp "$binary_path" "$bundle_path/Contents/MacOS/$app_name"
chmod +x "$bundle_path/Contents/MacOS/$app_name"

if [ -d "$resource_bundle_path" ]; then
  resource_bundle_name="$(basename "$resource_bundle_path")"
  resource_bundle_target="$bundle_path/Contents/Resources/$resource_bundle_name"
  rm -rf "$resource_bundle_target"
  cp -R "$resource_bundle_path" "$bundle_path/Contents/Resources/"
  ensure_resource_bundle_info "$resource_bundle_target"
fi

if [ -f "$icon_path" ]; then
  cp "$icon_path" "$bundle_path/Contents/Resources/${app_name}.icns"
fi

# Bundle the FFmpeg/FFprobe helper tools so MKV/MKA (AC3/Atmos/Auro) sources
# can be probed and demuxed. The binaries must be self-contained (no Homebrew
# dylibs); verify-ffmpeg-tools.sh enforces that. Ad-hoc sign each tool before
# the app-level codesign so the bundle signature stays valid.
tools_target_dir="$bundle_path/Contents/Resources/Tools"
mkdir -p "$tools_target_dir"
for tool in ffmpeg ffprobe; do
  if [ -x "$tools_src_dir/$tool" ]; then
    cp "$tools_src_dir/$tool" "$tools_target_dir/$tool"
    chmod +x "$tools_target_dir/$tool"
    codesign --force "${codesign_sign[@]}" "$tools_target_dir/$tool"
  else
    echo "Warning: missing helper tool $tools_src_dir/$tool; MKV/MKA playback will fail." >&2
  fi
done

git_commit="$(git rev-parse --short HEAD 2>/dev/null || printf 'not-available')"
if ! git diff --quiet --ignore-submodules -- 2>/dev/null || ! git diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
  git_commit="${git_commit}-dirty"
fi
git_branch="$(git branch --show-current 2>/dev/null || true)"
if [ -n "$git_branch" ]; then
  set_plist_string "OrbisonicGitRefKind" "branch"
  set_plist_string "OrbisonicGitRefName" "$git_branch"
  set_plist_string "OrbisonicGitBranch" "$git_branch"
else
  set_plist_string "OrbisonicGitRefKind" "commit"
  set_plist_string "OrbisonicGitRefName" "$git_commit"
  set_plist_string "OrbisonicGitBranch" "detached"
fi
set_plist_string "OrbisonicGitCommit" "$git_commit"
set_plist_string "CFBundleIdentifier" "$bundle_identifier"
set_plist_string "CFBundleShortVersionString" "$app_version"
set_plist_string "CFBundleVersion" "$app_version"
set_plist_string "NSMicrophoneUsageDescription" "macOS labels all audio input access as Microphone permission. Orbisonic uses it to capture Orbisonic Roon Input or Orbisonic Aux Cable for live sources, not the Mac mic unless you choose it."

# Work around a Swift 6 concurrency runtime crash: when a SwiftUI context-menu
# Button action fires through an AppKit menu-item callback, SwiftUI calls
# MainActor.assumeIsolated -> swift_task_isCurrentExecutorWithFlagsImpl, whose
# executor check segfaults (EXC_BAD_ACCESS). The legacy override restores the
# old non-crashing executor check. `open` launches via LaunchServices, which
# honors LSEnvironment, so the variable is set at process start.
if ! "$plist_buddy" -c "Print :LSEnvironment" "$plist_path" >/dev/null 2>&1; then
  "$plist_buddy" -c "Add :LSEnvironment dict" "$plist_path" >/dev/null
fi
if ! "$plist_buddy" -c "Set :LSEnvironment:SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE legacy" "$plist_path" >/dev/null 2>&1; then
  "$plist_buddy" -c "Add :LSEnvironment:SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE string legacy" "$plist_path" >/dev/null
fi

xattr -cr "$bundle_path"
codesign --force --deep "${codesign_sign[@]}" "$bundle_path"
codesign --verify --deep --strict --verbose=2 "$bundle_path"
plutil -lint "$plist_path"

echo "Refreshed $bundle_path"
