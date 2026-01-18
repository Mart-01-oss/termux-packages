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
#   PAGES_REPO_DIR            Path to checked-out pages repo (required)
#   PACKAGES_INDEX_PATH       Path to Packages file to drive the build list
#                             (default: $PAGES_REPO_DIR/dists/stable/main/binary-aarch64/Packages)
#   EXCLUDE_BOOTSTRAP_LIST    Space/newline-separated package names to exclude (bootstrap/core)
#                             (default: scripts/neonide-bootstrap-packages.txt)
#   BATCH_SIZE                Max number of *source packages* to build per run (default: 25)
#   FORCE_REBUILD             If 'true', ignore skip checks and rebuild (default: false)
#   TERMUX_ARCH               Target arch (default: aarch64)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${PAGES_REPO_DIR:?PAGES_REPO_DIR is required}"
: "${TERMUX_ARCH:=aarch64}"
: "${BATCH_SIZE:=25}"
: "${FORCE_REBUILD:=false}"

PACKAGES_INDEX_PATH_DEFAULT="$PAGES_REPO_DIR/dists/stable/main/binary-aarch64/Packages"
: "${PACKAGES_INDEX_PATH:=$PACKAGES_INDEX_PATH_DEFAULT}"

: "${EXCLUDE_BOOTSTRAP_LIST:=$REPO_ROOT/scripts/neonide-bootstrap-packages.txt}"

if [[ ! -f "$PACKAGES_INDEX_PATH" ]]; then
  echo "ERROR: Packages index not found: $PACKAGES_INDEX_PATH" >&2
  exit 1
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
mapfile -t ALL_SRCPKGS < <(
  awk -F'[:/ ]+' '$1=="Filename" {print $5}' "$PACKAGES_INDEX_PATH" | sort -u
)

if [[ ${#ALL_SRCPKGS[@]} -eq 0 ]]; then
  echo "ERROR: No packages found in $PACKAGES_INDEX_PATH" >&2
  exit 1
fi

# Returns 0 (true) if for given srcpkg, all referenced .deb files exist and match SHA256 in Packages.
# If the srcpkg has no entries in Packages yet, returns 1.
all_files_exist_and_match() {
  local srcpkg="$1"

  local entries
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
    }' "$PACKAGES_INDEX_PATH")"

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

  ./scripts/run-docker.sh ./build-package.sh -a "$TERMUX_ARCH" "$srcpkg"

  # Determine which .debs belong to this recipe: main package + subpackages.
  declare -a names=("$srcpkg")
  for f in "packages/$srcpkg"/*.subpackage.sh; do
    [[ -f "$f" ]] || continue
    names+=("$(basename "${f%.subpackage.sh}")")
  done

  local group dest
  group="$(pool_group_for_pkg "$srcpkg")"
  dest="$PAGES_REPO_DIR/pool/main/$group/$srcpkg"
  mkdir -p "$dest"

  local copied=0
  for n in "${names[@]}"; do
    for deb in output/"${n}"_*_"${TERMUX_ARCH}".deb output/"${n}"_*_all.deb; do
      [[ -f "$deb" ]] || continue
      cp -f "$deb" "$dest/"
      copied=1
    done
  done

  if [[ $copied -ne 1 ]]; then
    echo "WARN: No debs copied for '$srcpkg'. It may have produced differently named packages." >&2
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

# Show changes summary
(
  cd "$PAGES_REPO_DIR"
  git status --porcelain=v1 || true
)
