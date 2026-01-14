#!/usr/bin/env bash
set -euo pipefail

# Build Termux bootstrap zip for a forked app package name.
# Default: com.neonide.studio, aarch64, Android 10+
#
# This script will:
# 1. Patch scripts/properties.sh -> TERMUX_APP__PACKAGE_NAME
# 2. Run: ./scripts/run-docker.sh ./scripts/build-bootstraps.sh --android10 --architectures aarch64 -f
# 3. Restore scripts/properties.sh (unless KEEP_CHANGES=1)

APP_PACKAGE="com.neonide.studio"
ARCH="aarch64"
ANDROID10=1
FORCE=1
KEEP_CHANGES="${KEEP_CHANGES:-0}"
DRY_RUN=0
SETUP_ANDROID_SDK=1

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --app-package <pkg>   Android applicationId/package name to build bootstrap for.
                        Default: ${APP_PACKAGE}
  --arch <arch>         Architecture to build. Default: ${ARCH}
  --no-android10        Build legacy (Android <10) bootstrap (disables --android10).
  --no-force            Don't pass -f (force rebuild).
  --dry-run             Patch properties.sh and print the docker command, but do not run it.
  --no-setup-android-sdk Skip automatic Android SDK/NDK setup inside docker.
  -h, --help            Show this help.

Environment:
  KEEP_CHANGES=1        Don't restore scripts/properties.sh after build.

Examples:
  $0
  $0 --app-package com.neonide.studio --arch aarch64
  KEEP_CHANGES=1 $0
EOF
}

while (($# > 0)); do
  case "$1" in
    --app-package)
      APP_PACKAGE="${2:?Missing value for --app-package}"; shift 2;;
    --arch)
      ARCH="${2:?Missing value for --arch}"; shift 2;;
    --no-android10)
      ANDROID10=0; shift 1;;
    --no-force)
      FORCE=0; shift 1;;
    --dry-run)
      DRY_RUN=1; shift 1;;
    --no-setup-android-sdk)
      SETUP_ANDROID_SDK=0; shift 1;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2
      usage; exit 1;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if [[ ! -f "scripts/properties.sh" ]]; then
  echo "ERROR: scripts/properties.sh not found. Are you in termux-packages repo root?" >&2
  exit 1
fi

# Patch TERMUX_APP__PACKAGE_NAME in scripts/properties.sh safely.
PROPS="scripts/properties.sh"
BACKUP="$(mktemp -t termux-properties.sh.XXXXXX)"
cp -f "$PROPS" "$BACKUP"

restore_props() {
  if [[ "$KEEP_CHANGES" == "1" ]]; then
    echo "[*] KEEP_CHANGES=1: not restoring $PROPS"
    return 0
  fi
  cp -f "$BACKUP" "$PROPS"
}
trap restore_props EXIT

# Replace the first occurrence of TERMUX_APP__PACKAGE_NAME="..."
# (matches the default assignment line in properties.sh)
perl -0777 -i -pe 's/TERMUX_APP__PACKAGE_NAME="[^"]+"/TERMUX_APP__PACKAGE_NAME="'"$APP_PACKAGE"'"/s' "$PROPS"

# Sanity check
if ! grep -q "TERMUX_APP__PACKAGE_NAME=\"$APP_PACKAGE\"" "$PROPS"; then
  echo "ERROR: Failed to set TERMUX_APP__PACKAGE_NAME to '$APP_PACKAGE'" >&2
  exit 1
fi

echo "[*] Building bootstrap for app package: $APP_PACKAGE"
echo "[*] Architecture: $ARCH"

args=("./scripts/build-bootstraps.sh" "--architectures" "$ARCH")
if [[ "$ANDROID10" == "1" ]]; then
  args+=("--android10")
fi
if [[ "$FORCE" == "1" ]]; then
  args+=("-f")
fi

# Run inside docker builder.
# NOTE: This can take a long time on the first run (image pull + builds).
if [[ "$DRY_RUN" == "1" ]]; then
  echo "[*] DRY RUN: would execute:"
  printf '  %q' ./scripts/run-docker.sh "${args[@]}"; echo
  exit 0
fi

if [[ "$SETUP_ANDROID_SDK" == "1" ]]; then
  echo "[*] Ensuring Android SDK/NDK exist inside docker builder (may download on first run)..."
  # properties.sh defaults to:
  #   ANDROID_HOME=$HOME/lib/android-sdk-<rev>
  #   NDK=$HOME/lib/android-ndk-r<ver>
  # so ensure NDK exists, otherwise run setup.
  ./scripts/run-docker.sh bash -lc 'set -e; cd "$HOME/termux-packages"; . ./scripts/properties.sh; if [ ! -d "$NDK" ]; then ./scripts/setup-android-sdk.sh; fi'
fi

./scripts/run-docker.sh "${args[@]}"

echo "[*] Done. Look for bootstrap zip under the repo root or output directory depending on docker bind mounts."
