#!/usr/bin/env bash
set -euo pipefail

# Build Termux packages (aarch64 only) inside the Termux docker builder and publish
# resulting .deb files into the NeonIDE pages APT repo, then regenerate Packages/Packages.gz.
#
# Intended to run in GitHub Actions from the termux-packages repository.
#
# Requirements (in runner):
# - docker
# - dpkg-scanpackages (dpkg-dev)
# - gzip, sha256sum
#
# Environment variables:
#   PAGES_REPO_DIR                 Path to checked-out pages repo (required)
#   DESIRED_PACKAGES_SOURCE        Where to get the desired build list from:
#                                  - recipes (default): all directories under ./packages/
#                                  - file: read from DESIRED_PACKAGES_FILE (newline/space separated)
#                                  - pages_packages: parse from the pages Packages index (not recommended)
#   DESIRED_PACKAGES_FILE          Used when DESIRED_PACKAGES_SOURCE=file
#   PAGES_PACKAGES_INDEX_PATH      Pages Packages index used as current published state for skip checks
#                                  (default: $PAGES_REPO_DIR/dists/stable/main/binary-aarch64/Packages)
#   EXCLUDE_BOOTSTRAP_LIST         Space/newline-separated package names to exclude (bootstrap/core)
#                                  (default: scripts/neonide-bootstrap-packages.txt)
#   BATCH_SIZE                     Max number of *source packages* to build per run (default: 25)
#   FORCE_REBUILD                  If 'true', ignore skip checks and rebuild (default: false)
#   TERMUX_ARCH                    Target arch (default: aarch64)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${PAGES_REPO_DIR:?PAGES_REPO_DIR is required}"
: "${TERMUX_ARCH:=aarch64}"
: "${BATCH_SIZE:=25}"
: "${FORCE_REBUILD:=false}"

: "${DESIRED_PACKAGES_SOURCE:=recipes}"
: "${DESIRED_PACKAGES_FILE:=}"

PAGES_PACKAGES_INDEX_PATH_DEFAULT="$PAGES_REPO_DIR/dists/stable/main/binary-aarch64/Packages"
: "${PAGES_PACKAGES_INDEX_PATH:=$PAGES_PACKAGES_INDEX_PATH_DEFAULT}"

: "${EXCLUDE_BOOTSTRAP_LIST:=$REPO_ROOT/scripts/neonide-bootstrap-packages.txt}"

# The pages Packages index is used only for skip checks. If it doesn't exist yet
# (fresh pages repo), treat it as empty and build packages.
if [[ ! -f "$PAGES_PACKAGES_INDEX_PATH" ]]; then
  echo "[*] Pages Packages index not found yet: $PAGES_PACKAGES_INDEX_PATH (will treat as empty)"
fi

if [[ ! -d "$PAGES_REPO_DIR/.git" ]]; then
  echo "ERROR: PAGES_REPO_DIR does not look like a git repo: $PAGES_REPO_DIR" >&2
  exit 1
fi

# Load exclude list into a bash assoc set.
declare -A EXCLUDE=()
if [[ -f "$EXCLUDE_BOOTSTRAP_LIST" ]]; then
  # File is space-separated (in this repo). Convert to newline, ignore empties.
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    EXCLUDE["$p"]=1
  done < <(tr ' ' '\n' < "$EXCLUDE_BOOTSTRAP_LIST" | sed '/^$/d')
else
  echo "WARN: exclude list not found: $EXCLUDE_BOOTSTRAP_LIST (continuing without excludes)" >&2
fi

# Extract unique source package names from Filename: pool/main/<group>/<srcpkg>/...
# Use a field split that works with:
#   Filename: pool/main/libp/libpng/libpng_...
# by splitting on spaces, ':' and '/'.
# Desired build list
mapfile -t ALL_SRCPKGS < <(
  case "$DESIRED_PACKAGES_SOURCE" in
    recipes)
      find "$REPO_ROOT/packages" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -u
      ;;
    file)
      if [[ -z "$DESIRED_PACKAGES_FILE" || ! -f "$DESIRED_PACKAGES_FILE" ]]; then
        echo "ERROR: DESIRED_PACKAGES_SOURCE=file but DESIRED_PACKAGES_FILE is missing or not a file: '$DESIRED_PACKAGES_FILE'" >&2
        exit 1
      fi
      tr ' \t\r\n' '\n' < "$DESIRED_PACKAGES_FILE" | sed '/^$/d' | sort -u
      ;;
    pages_packages)
      if [[ ! -f "$PAGES_PACKAGES_INDEX_PATH" ]]; then
        echo "ERROR: DESIRED_PACKAGES_SOURCE=pages_packages but pages Packages index not found: $PAGES_PACKAGES_INDEX_PATH" >&2
        exit 1
      fi
      awk -F'[:/ ]+' '$1=="Filename" {print $5}' "$PAGES_PACKAGES_INDEX_PATH" | sort -u
      ;;
    *)
      echo "ERROR: Unknown DESIRED_PACKAGES_SOURCE='$DESIRED_PACKAGES_SOURCE'" >&2
      exit 1
      ;;
  esac
)

if [[ ${#ALL_SRCPKGS[@]} -eq 0 ]]; then
  echo "ERROR: Desired package list is empty (source=$DESIRED_PACKAGES_SOURCE)" >&2
  exit 1
fi

echo "[*] Desired packages (source=$DESIRED_PACKAGES_SOURCE): ${#ALL_SRCPKGS[@]}"

# Returns 0 (true) if for given srcpkg, all referenced .deb files exist and match SHA256 in Packages.
# If the srcpkg has no entries in Packages yet, returns 1.
all_files_exist_and_match() {
  local srcpkg="$1"

  local entries

  # If we don't have a state Packages index yet, nothing is built.
  if [[ ! -f "$PAGES_PACKAGES_INDEX_PATH" ]]; then
    return 1
  fi

  entries="$(awk -v pkg="$srcpkg" 'BEGIN{RS="";FS="\n"}
    {
      fn=""; sha="";
      for(i=1;i<=NF;i++){
        if($i ~ /^Filename: /){fn=substr($i,11)}
        else if($i ~ /^SHA256: /){sha=substr($i,9)}
      }
      if(fn=="" || sha=="") next;
      n=split(fn,a,"/");
      # pool/main/<group>/<srcpkg>/<deb>
      if(n>=5 && a[4]==pkg){print fn"\t"sha}
    }' "$PAGES_PACKAGES_INDEX_PATH")"

  if [[ -z "$entries" ]]; then
    return 1
  fi

  local ok=1
  while IFS=$'\t' read -r rel sha; do
    [[ -z "$rel" ]] && continue
    local path="$PAGES_REPO_DIR/$rel"
    if [[ ! -f "$path" ]]; then
      ok=0
      break
    fi
    local actual
    actual="$(sha256sum "$path" | awk '{print $1}')"
    if [[ "$actual" != "$sha" ]]; then
      ok=0
      break
    fi
  done <<< "$entries"

  [[ $ok -eq 1 ]]
}

pool_group_for_pkg() {
  local name="$1"
  if [[ "$name" == lib* && ${#name} -ge 4 ]]; then
    echo "${name:0:4}"
  else
    echo "${name:0:1}"
  fi
}

# Detect a working host LLVM base dir inside the docker builder image.
# Many builds expect "$TERMUX_HOST_LLVM_BASE_DIR/bin/clang" to exist.
# The builder image may have LLVM installed under /usr/lib/llvm-<ver>/.
HOST_LLVM_BASE_DIR_IN_CONTAINER="${HOST_LLVM_BASE_DIR_IN_CONTAINER:-}"
if [[ -z "$HOST_LLVM_BASE_DIR_IN_CONTAINER" ]]; then
  # Try to discover the newest /usr/lib/llvm-*/bin/clang inside the container.
  HOST_LLVM_BASE_DIR_IN_CONTAINER="$(./scripts/run-docker.sh bash -lc '
    set -e
    best=""
    for d in /usr/lib/llvm-*; do
      if [ -x "$d/bin/clang" ]; then best="$d"; fi
    done
    if [ -n "$best" ]; then echo "$best"; else echo "/usr"; fi
  ' | tail -n 1)"
  echo "[*] Using host LLVM base dir in container: $HOST_LLVM_BASE_DIR_IN_CONTAINER"
fi

# Build a termux recipe in docker and copy produced debs for that recipe into pages pool.
build_and_publish_srcpkg() {
  local srcpkg="$1"

  if [[ ! -d "packages/$srcpkg" ]]; then
    echo "[!] Skipping '$srcpkg': no recipe directory packages/$srcpkg" >&2
    return 0
  fi

  echo "[*] Building '$srcpkg' for arch '$TERMUX_ARCH'..."

  # Avoid copying stale debs from previous builds.
  mkdir -p output
  rm -f output/*.deb || true

  # Ensure TERMUX_HOST_LLVM_BASE_DIR points to a directory that has bin/clang inside the container.
  # Also force BUILD_CC to avoid configure failures caused by missing /usr/bin/clang in the builder image.
  # Enable dependency downloading (-i) from repositories when possible.
  # We set TERMUX_REPO_APP__PACKAGE_NAME to match TERMUX_APP_PACKAGE (com.neonide.studio)
  # so build-package.sh does not ignore -i. Repo URLs are taken from repo.json and can
  # include both NeonIDE pages (preferred) and official Termux (fallback).
  ./scripts/run-docker.sh env \
    TERMUX_HOST_LLVM_BASE_DIR="$HOST_LLVM_BASE_DIR_IN_CONTAINER" \
    BUILD_CC="$HOST_LLVM_BASE_DIR_IN_CONTAINER/bin/clang" \
    TERMUX_REPO_APP__PACKAGE_NAME="com.neonide.studio" \
    ./build-package.sh -i -a "$TERMUX_ARCH" "$srcpkg"

  # Upload ALL produced debs (including dependencies) from output/ into pages pool.
  # This speeds up later runs because build-package.sh -i can download these deps
  # instead of rebuilding them.
  local copied=0
  shopt -s nullglob
  for deb in output/*.deb; do
    # deb filename format: <pkgname>_<version>_<arch>.deb
    local pkgname
    pkgname="$(basename "$deb" | sed -E 's/^([^_]+)_.*/\1/')"
    if [[ -z "$pkgname" ]]; then
      continue
    fi

    local group dest
    group="$(pool_group_for_pkg "$pkgname")"
    dest="$PAGES_REPO_DIR/pool/main/$group/$pkgname"
    mkdir -p "$dest"

    cp -f "$deb" "$dest/"
    copied=1
  done
  shopt -u nullglob

  if [[ $copied -ne 1 ]]; then
    echo "WARN: No debs found in output/ to upload for '$srcpkg'." >&2
  fi
}

built=0
skipped=0
considered=0

for srcpkg in "${ALL_SRCPKGS[@]}"; do
  ((considered++)) || true

  # Exclude bootstrap packages ("termux core" per user) by name.
  if [[ -n "${EXCLUDE[$srcpkg]:-}" ]]; then
    ((skipped++)) || true
    continue
  fi

  if [[ "$FORCE_REBUILD" != "true" ]] && all_files_exist_and_match "$srcpkg"; then
    ((skipped++)) || true
    continue
  fi

  build_and_publish_srcpkg "$srcpkg"
  ((built++)) || true

  if [[ "$built" -ge "$BATCH_SIZE" ]]; then
    echo "[*] Reached BATCH_SIZE=$BATCH_SIZE; stopping early to keep workflow runtime manageable."
    break
  fi

done

echo "[*] Considered: $considered, built: $built, skipped: $skipped"

echo "[*] Regenerating Packages and Packages.gz from pool..."
(
  cd "$PAGES_REPO_DIR"
  mkdir -p dists/stable/main/binary-aarch64
  dpkg-scanpackages -m pool /dev/null > dists/stable/main/binary-aarch64/Packages
  gzip -9 -c dists/stable/main/binary-aarch64/Packages > dists/stable/main/binary-aarch64/Packages.gz
)

echo "[*] Regenerating dists/stable/Release metadata (hashes + sizes)..."
(
  cd "$PAGES_REPO_DIR/dists/stable"

  # Base fields for apt Release
  DATE_RFC2822="$(date -Ru)"
  cat > Release <<EOF
Origin: com.neonide.studio
Label: com.neonide.studio
Suite: stable
Codename: stable
Date: ${DATE_RFC2822}
Architectures: aarch64
Components: main
Description: NeonIDE APT repo
EOF

  add_section() {
    local title="$1"
    local cmd="$2"
    echo "${title}:" >> Release
    for f in Release main/binary-aarch64/Packages main/binary-aarch64/Packages.gz; do
      local hash size
      hash="$($cmd "$f" | awk '{print $1}')"
      size="$(wc -c < "$f" | tr -d ' ')"
      printf ' %s %16s %s\n' "$hash" "$size" "$f" >> Release
    done
  }

  add_section "MD5Sum" md5sum
  add_section "SHA1" sha1sum
  add_section "SHA256" sha256sum
  add_section "SHA512" sha512sum
)

# Optionally sign the repo metadata.
# If NEONIDE_GPG_KEY_ID is set and gpg is available, generate:
# - dists/stable/InRelease (clearsigned)
# - dists/stable/Release.gpg (detached)
if command -v gpg >/dev/null 2>&1 && [[ -n "${NEONIDE_GPG_KEY_ID:-}" ]]; then
  echo "[*] Signing Release (key: $NEONIDE_GPG_KEY_ID)..."
  (
    cd "$PAGES_REPO_DIR/dists/stable"
    # Clear-signed InRelease
    gpg --batch --yes --pinentry-mode loopback --local-user "$NEONIDE_GPG_KEY_ID" --clearsign -o InRelease Release
    # Detached signature
    gpg --batch --yes --pinentry-mode loopback --local-user "$NEONIDE_GPG_KEY_ID" --armor --detach-sign -o Release.gpg Release
  )
else
  echo "[*] Skipping signing (set NEONIDE_GPG_KEY_ID and ensure gpg is installed)."
fi

# Show changes summary
(
  cd "$PAGES_REPO_DIR"
  git status --porcelain=v1 || true
)
