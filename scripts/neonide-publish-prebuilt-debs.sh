#!/usr/bin/env bash
set -euo pipefail

# Publish prebuilt .deb files into the NeonIDE pages APT repo and regenerate
# Packages/Packages.gz and dists/<dist>/Release (optionally sign).
#
# Intended to run in GitHub Actions (or locally) with:
# - PAGES_REPO_DIR pointing to a checked-out pages git repo
# - dpkg-scanpackages (dpkg-dev), gzip, sha*sum available
#
# Environment variables:
#   PAGES_REPO_DIR            (required) path to pages repo
#   DEBS_DIR                  (required) directory containing *.deb files
#   APT_DIST                  (default: stable)
#   APT_COMPONENT             (default: main)
#   APT_ARCH                  (default: aarch64)
#   FORCE_OVERWRITE           (default: false) overwrite existing debs
#   NEONIDE_GPG_KEY_ID        (optional) key id to sign Release/InRelease
#   NEONIDE_GPG_PASSPHRASE    (optional) passphrase for loopback signing

: "${PAGES_REPO_DIR:?PAGES_REPO_DIR is required}"

# Either provide a directory of debs (DEBS_DIR) or a single deb file (DEB_FILE).
: "${DEBS_DIR:=}"
: "${DEB_FILE:=}"

if [[ -z "$DEBS_DIR" && -n "$DEB_FILE" ]]; then
  DEBS_DIR="$(cd "$(dirname "$DEB_FILE")" && pwd)"
fi

: "${DEBS_DIR:?DEBS_DIR is required (or set DEB_FILE)}"

: "${APT_DIST:=stable}"
: "${APT_COMPONENT:=main}"
: "${APT_ARCH:=aarch64}"
: "${FORCE_OVERWRITE:=false}"

if [[ ! -d "$PAGES_REPO_DIR/.git" ]]; then
  echo "ERROR: PAGES_REPO_DIR is not a git repo: $PAGES_REPO_DIR" >&2
  exit 1
fi

if [[ ! -d "$DEBS_DIR" ]]; then
  echo "ERROR: DEBS_DIR not found: $DEBS_DIR" >&2
  exit 1
fi

pool_group_for_pkg() {
  local name="$1"
  if [[ "$name" == lib* && ${#name} -ge 4 ]]; then
    echo "${name:0:4}"
  else
    echo "${name:0:1}"
  fi
}

get_pkg_name_from_deb() {
  local deb="$1"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -f "$deb" Package 2>/dev/null || true
  fi
}

copied=0
shopt -s nullglob
for deb in "$DEBS_DIR"/*.deb; do
  pkg="$(get_pkg_name_from_deb "$deb")"
  if [[ -z "$pkg" ]]; then
    # fallback to filename prefix
    pkg="$(basename "$deb" | sed -E 's/^([^_]+)_.*/\1/')"
  fi

  if [[ -z "$pkg" ]]; then
    echo "WARN: Could not determine package name for $deb, skipping" >&2
    continue
  fi

  group="$(pool_group_for_pkg "$pkg")"
  dest_dir="$PAGES_REPO_DIR/pool/${APT_COMPONENT}/$group/$pkg"
  mkdir -p "$dest_dir"

  dest_path="$dest_dir/$(basename "$deb")"

  if [[ -f "$dest_path" && "$FORCE_OVERWRITE" != "true" ]]; then
    # If same checksum, skip; otherwise overwrite.
    src_sha="$(sha256sum "$deb" | awk '{print $1}')"
    dst_sha="$(sha256sum "$dest_path" | awk '{print $1}')"
    if [[ "$src_sha" == "$dst_sha" ]]; then
      echo "[=] Already published (same sha256): $(basename "$deb")"
      continue
    fi
  fi

  cp -f "$deb" "$dest_dir/"
  echo "[+] Published: $(basename "$deb") -> pool/${APT_COMPONENT}/$group/$pkg/"
  copied=1

done
shopt -u nullglob

if [[ $copied -ne 1 ]]; then
  echo "WARN: No .deb files were published from $DEBS_DIR" >&2
fi

echo "[*] Regenerating Packages and Packages.gz from pool..."
(
  cd "$PAGES_REPO_DIR"
  mkdir -p "dists/${APT_DIST}/${APT_COMPONENT}/binary-${APT_ARCH}"
  dpkg-scanpackages -m pool /dev/null > "dists/${APT_DIST}/${APT_COMPONENT}/binary-${APT_ARCH}/Packages"

  # Keep output identical to scripts/neonide-build-and-publish-pages.sh
  gzip -9 -c "dists/${APT_DIST}/${APT_COMPONENT}/binary-${APT_ARCH}/Packages" > "dists/${APT_DIST}/${APT_COMPONENT}/binary-${APT_ARCH}/Packages.gz"
)

echo "[*] Regenerating dists/${APT_DIST}/Release metadata (hashes + sizes)..."
(
  cd "$PAGES_REPO_DIR/dists/${APT_DIST}"

  # Base fields for apt Release (match neonide-build-and-publish-pages.sh)
  DATE_RFC2822="$(date -Ru)"
  cat > Release <<EOF
Origin: com.neonide.studio
Label: com.neonide.studio
Suite: ${APT_DIST}
Codename: ${APT_DIST}
Date: ${DATE_RFC2822}
Architectures: ${APT_ARCH}
Components: ${APT_COMPONENT}
Description: NeonIDE APT repo
EOF

  add_section() {
    local title="$1"
    local cmd="$2"
    echo "${title}:" >> Release
    for f in Release "${APT_COMPONENT}/binary-${APT_ARCH}/Packages" "${APT_COMPONENT}/binary-${APT_ARCH}/Packages.gz"; do
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

if command -v gpg >/dev/null 2>&1 && [[ -n "${NEONIDE_GPG_KEY_ID:-}" ]]; then
  echo "[*] Signing Release (key: $NEONIDE_GPG_KEY_ID)..."
  (
    cd "$PAGES_REPO_DIR/dists/${APT_DIST}"

    gpg_args=(--batch --yes --local-user "$NEONIDE_GPG_KEY_ID")
    if [[ -n "${NEONIDE_GPG_PASSPHRASE:-}" ]]; then
      gpg_args+=(--pinentry-mode loopback --passphrase "$NEONIDE_GPG_PASSPHRASE")
    fi

    rm -f InRelease Release.gpg || true

    gpg "${gpg_args[@]}" --clearsign -o InRelease Release
    gpg "${gpg_args[@]}" --armor --detach-sign -o Release.gpg Release || true
  )

  echo "[*] Exporting public key -> $PAGES_REPO_DIR/neonide.gpg"
  gpg --batch --yes --export "$NEONIDE_GPG_KEY_ID" > "$PAGES_REPO_DIR/neonide.gpg"
else
  echo "[*] Skipping signing (set NEONIDE_GPG_KEY_ID and ensure gpg is installed)."
fi

echo "[*] Done. Pages repo status:"
(
  cd "$PAGES_REPO_DIR"
  git status --porcelain=v1 || true
)
