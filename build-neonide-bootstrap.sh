#!/usr/bin/env bash
set -euo pipefail

# Build Termux bootstrap zip for a forked app package name.
# Default: com.neonide.studio, aarch64, Android 10+
#
# This script will:
# 1. Patch scripts/properties.sh -> TERMUX_APP__PACKAGE_NAME
# 2. Run: ./scripts/run-docker.sh ./scripts/build-bootstraps.sh --android10 --architectures aarch64
#    Optionally pass extra packages via --add (from a packages list file).
# 3. Restore scripts/properties.sh (unless KEEP_CHANGES=1)

APP_PACKAGE="com.neonide.studio"
ARCH="aarch64"
ANDROID10=1
# IMPORTANT: scripts/build-bootstraps.sh now defaults to forcing rebuilds for bootstrap
# generation (TERMUX_BOOTSTRAP_FORCE_REBUILD=true). Use TERMUX_BOOTSTRAP_FORCE_REBUILD=false
# to restore the old behavior. This flag (--force) still explicitly passes -f.
FORCE=0
KEEP_CHANGES="${KEEP_CHANGES:-0}"
DRY_RUN=0
SETUP_ANDROID_SDK=1
PACKAGES_FILE_DEFAULT="scripts/neonide-bootstrap-packages.txt"
# By default, build only the core bootstrap package set.
# Use --packages-file to include extra packages.
PACKAGES_FILE=""
# Optionally set TMPDIR for container-side temp files.
# Some environments (especially CI) may have more free space in /tmp.
TMPDIR_IN_CONTAINER="${TMPDIR_IN_CONTAINER:-}"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --app-package <pkg>   Android applicationId/package name to build bootstrap for.
                        Default: ${APP_PACKAGE}
  --arch <arch>         Architecture to build. Default: ${ARCH}
  --no-android10        Build legacy (Android <10) bootstrap (disables --android10).
  --force               Pass -f to scripts/build-bootstraps.sh (force rebuild).
                        (usually not needed since TERMUX_BOOTSTRAP_FORCE_REBUILD defaults to true)
  --packages-file <path> Newline-separated list of extra packages to include.
                        (comments/empty lines are ignored)
                        If not provided, builds ONLY the core bootstrap package set.
  --dry-run             Patch properties.sh and print the docker command, but do not run it.
  --no-setup-android-sdk Skip automatic Android SDK/NDK setup inside docker.
  --tmpdir-in-container <path> Set TMPDIR inside docker container (e.g. /tmp)
  -h, --help            Show this help.

Environment:
  KEEP_CHANGES=1                  Don't restore scripts/properties.sh after build.
  TERMUX_BOOTSTRAP_FORCE_REBUILD=false
                                 Don't force rebuilds inside scripts/build-bootstraps.sh.
                                 (Not recommended when changing app package name)

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
    --force)
      FORCE=1; shift 1;;
    --packages-file)
      PACKAGES_FILE="${2:?Missing value for --packages-file}"; shift 2;;
    --dry-run)
      DRY_RUN=1; shift 1;;
    --no-setup-android-sdk)
      SETUP_ANDROID_SDK=0; shift 1;;
    --tmpdir-in-container)
      TMPDIR_IN_CONTAINER="${2:?Missing value for --tmpdir-in-container}"; shift 2;;
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

# Replace TERMUX_APP__PACKAGE_NAME="..." in scripts/properties.sh.
# Use sed (avoid depending on perl being installed on the host).
# This is safe because properties.sh defines TERMUX_APP__PACKAGE_NAME once.
sed -i -E "s/^(TERMUX_APP__PACKAGE_NAME=)\"[^\"]*\"/\1\"${APP_PACKAGE//\//\\/}\"/" "$PROPS"

# Sanity check
if ! grep -q "TERMUX_APP__PACKAGE_NAME=\"$APP_PACKAGE\"" "$PROPS"; then
  echo "ERROR: Failed to set TERMUX_APP__PACKAGE_NAME to '$APP_PACKAGE'" >&2
  exit 1
fi

echo "[*] Building bootstrap for app package: $APP_PACKAGE"
echo "[*] Architecture: $ARCH"

# If a packages file was provided, pass it as --add.
# Note: scripts/build-bootstraps.sh will still build the minimal/core set;
# this only controls the additional packages.
PACKAGES_CSV=""
if [[ -n "$PACKAGES_FILE" ]]; then
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    echo "ERROR: packages file not found: $PACKAGES_FILE" >&2
    exit 1
  fi
  PACKAGES_CSV="$(grep -vE '^[[:space:]]*(#|$)' "$PACKAGES_FILE" | tr '\n' ',' | sed 's/,$//')"
  if [[ -z "$PACKAGES_CSV" ]]; then
    echo "ERROR: package list is empty (after filtering comments): $PACKAGES_FILE" >&2
    exit 1
  fi
  echo "[*] Additional packages loaded from: $PACKAGES_FILE"
fi

args=("./scripts/build-bootstraps.sh" "--architectures" "$ARCH")
if [[ "$ANDROID10" == "1" ]]; then
  args+=("--android10")
fi
if [[ -n "$PACKAGES_CSV" ]]; then
  args+=("--add" "$PACKAGES_CSV")
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

if [[ -n "$TMPDIR_IN_CONTAINER" ]]; then
  echo "[*] Using TMPDIR inside container: $TMPDIR_IN_CONTAINER"
  ./scripts/run-docker.sh env TMPDIR="$TMPDIR_IN_CONTAINER" "${args[@]}"
else
  ./scripts/run-docker.sh "${args[@]}"
fi

echo "[*] Done. Look for bootstrap zip under the repo root or output directory depending on docker bind mounts."
