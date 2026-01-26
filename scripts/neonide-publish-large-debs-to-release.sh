#!/usr/bin/env bash
set -euo pipefail

# Publish *large* .deb files as a flat APT repository inside a GitHub Release.
#
# This is intended for an APT source line like:
#   deb [trusted=yes] https://github.com/<owner>/<repo>/releases/download/<tag>/ ./
#
# It will upload:
#   - the large .deb assets
#   - Packages + Packages.gz (flat repo index)
#   - Release + optionally InRelease/Release.gpg if signing is configured
#
# Env:
#   DEBS_DIR                   (required) directory containing .deb files (may be nested)
#   LARGE_DEB_THRESHOLD_MB     (default: 99) size threshold in MiB
#   RELEASE_REPO               (default: Mart-01-oss/pages) target repo for GitHub Release
#   RELEASE_TAG                (default: Package) tag name
#   RELEASE_TITLE              (default: Package)
#   RELEASE_NOTES              (default: Large .deb assets + flat APT index)
#   APT_ARCH                   (default: aarch64) written to Release file metadata
#   NEONIDE_GPG_KEY_ID         (optional) gpg key id for signing
#   NEONIDE_GPG_PASSPHRASE     (optional) passphrase for loopback signing
#
# Requires: gh, dpkg-scanpackages, gzip, sha*sum, gpg (optional).

: "${DEBS_DIR:?DEBS_DIR is required}"

: "${LARGE_DEB_THRESHOLD_MB:=99}"
: "${RELEASE_REPO:=Mart-01-oss/pages}"
: "${RELEASE_TAG:=Package}"
: "${RELEASE_TITLE:=Package}"
: "${RELEASE_NOTES:=Large .deb assets and flat APT repo index.}"
: "${APT_ARCH:=aarch64}"

threshold_bytes=$((LARGE_DEB_THRESHOLD_MB * 1024 * 1024))

mapfile -d '' all_debs < <(find "$DEBS_DIR" -type f -name '*.deb' -print0 2>/dev/null || true)
if [ "${#all_debs[@]}" -eq 0 ]; then
  echo "No .deb files found under DEBS_DIR='$DEBS_DIR'. Nothing to publish to Release."
  exit 0
fi

large_debs=()
for f in "${all_debs[@]}"; do
  size="$(stat -c%s "$f" 2>/dev/null || wc -c < "$f")"
  if [ "$size" -ge "$threshold_bytes" ]; then
    large_debs+=("$f")
  fi
done

if [ "${#large_debs[@]}" -eq 0 ]; then
  echo "No large debs (>=${LARGE_DEB_THRESHOLD_MB}MiB). Skipping Release publish."
  exit 0
fi

echo "Publishing ${#large_debs[@]} large deb(s) to GitHub Release '$RELEASE_TAG' in '$RELEASE_REPO'..."

# Ensure the release exists
if gh release view "$RELEASE_TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  echo "[*] Release '$RELEASE_TAG' already exists"
else
  echo "[*] Creating release '$RELEASE_TAG'"
  gh release create "$RELEASE_TAG" --repo "$RELEASE_REPO" --title "$RELEASE_TITLE" --notes "$RELEASE_NOTES" --latest=false
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Build a flat repo index in workdir/
for f in "${large_debs[@]}"; do
  cp -f "$f" "$workdir/"
done

(
  cd "$workdir"
  dpkg-scanpackages -m . /dev/null > Packages
  gzip -9 -c Packages > Packages.gz

  # Minimal Release file for flat repo.
  DATE_RFC2822="$(date -Ru)"
  cat > Release <<EOF
Origin: com.neonide.studio
Label: com.neonide.studio
Suite: ${RELEASE_TAG}
Codename: ${RELEASE_TAG}
Date: ${DATE_RFC2822}
Architectures: ${APT_ARCH}
Components: ./
Description: NeonIDE flat APT repo (GitHub Release assets)
EOF

  add_section() {
    local title="$1" cmd="$2"
    echo "${title}:" >> Release
    for f in Release Packages Packages.gz; do
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

  if command -v gpg >/dev/null 2>&1 && [ -n "${NEONIDE_GPG_KEY_ID:-}" ]; then
    echo "[*] Signing Release (key: $NEONIDE_GPG_KEY_ID)..."
    gpg_args=(--batch --yes --local-user "$NEONIDE_GPG_KEY_ID")
    if [ -n "${NEONIDE_GPG_PASSPHRASE:-}" ]; then
      gpg_args+=(--pinentry-mode loopback --passphrase "$NEONIDE_GPG_PASSPHRASE")
    fi
    rm -f InRelease Release.gpg || true
    gpg "${gpg_args[@]}" --clearsign -o InRelease Release
    gpg "${gpg_args[@]}" --armor --detach-sign -o Release.gpg Release || true
  else
    echo "[*] Skipping signing (NEONIDE_GPG_KEY_ID not set or gpg missing)."
  fi
)

# Upload index + metadata first
assets=("$workdir/Packages" "$workdir/Packages.gz" "$workdir/Release")
[ -f "$workdir/InRelease" ] && assets+=("$workdir/InRelease")
[ -f "$workdir/Release.gpg" ] && assets+=("$workdir/Release.gpg")

# Upload debs too
for f in "$workdir"/*.deb; do
  assets+=("$f")
done

echo "[*] Uploading ${#assets[@]} asset(s) to release..."
# shellcheck disable=SC2048,SC2086
gh release upload "$RELEASE_TAG" ${assets[*]} --repo "$RELEASE_REPO" --clobber

# If signing is enabled, also upload public key as an asset for convenience.
if command -v gpg >/dev/null 2>&1 && [ -n "${NEONIDE_GPG_KEY_ID:-}" ]; then
  pub="$workdir/neonide.gpg"
  gpg --batch --yes --export "$NEONIDE_GPG_KEY_ID" > "$pub"
  gh release upload "$RELEASE_TAG" "$pub" --repo "$RELEASE_REPO" --clobber
fi

echo "[*] Done. APT source base URL should be:"
echo "    https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}/"
