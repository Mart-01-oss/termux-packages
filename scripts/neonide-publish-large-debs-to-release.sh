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

newdir="$workdir/new"
mkdir -p "$newdir"

# Copy the *new* large debs into newdir/ (these will be uploaded as assets).
for f in "${large_debs[@]}"; do
  cp -f "$f" "$newdir/"
done

(
  cd "$workdir"

  # If the release already has a Packages/Packages.gz, merge it with the new packages
  # instead of overwriting to only the debs uploaded in this run.
  existing_packages="$workdir/Packages.existing"
  tmp_download="$workdir/.gh_download"
  mkdir -p "$tmp_download"

  if gh release download "$RELEASE_TAG" --repo "$RELEASE_REPO" --pattern "Packages" --dir "$tmp_download" >/dev/null 2>&1; then
    cp -f "$tmp_download/Packages" "$existing_packages"
  elif gh release download "$RELEASE_TAG" --repo "$RELEASE_REPO" --pattern "Packages.gz" --dir "$tmp_download" >/dev/null 2>&1; then
    gzip -dc "$tmp_download/Packages.gz" > "$existing_packages" || true
  else
    : > "$existing_packages"
  fi

  # Build Packages entries for the new debs only.
  (cd "$newdir" && dpkg-scanpackages -m . /dev/null) > "$workdir/Packages.new"

  # Remove stanzas from existing Packages that would be overwritten by uploading a deb with the same filename.
  # (Filename is typically "./<deb>" in a flat repo.)
  ls -1 "$newdir"/*.deb 2>/dev/null | xargs -n1 basename > "$workdir/skip-filenames.txt" || true

  awk -v skipfile="$workdir/skip-filenames.txt" '
    BEGIN {
      RS=""; FS="\n"; ORS="\n\n";
      while ((getline < skipfile) > 0) {
        if ($0 != "") skip[$0]=1;
      }
    }
    {
      fn="";
      for (i=1; i<=NF; i++) {
        if ($i ~ /^Filename: /) {
          fn=$i;
          sub(/^Filename: /,"",fn);
          sub(/^\.[\/]/,"",fn);
        }
      }
      if (fn != "" && (fn in skip)) next;
      print $0;
    }
  ' "$existing_packages" > "$workdir/Packages.merged"

  cat "$workdir/Packages.new" >> "$workdir/Packages.merged"

  # Normalize trailing newlines
  printf '\n' >> "$workdir/Packages.merged"

  mv -f "$workdir/Packages.merged" "$workdir/Packages"
  gzip -9 -c "$workdir/Packages" > "$workdir/Packages.gz"

  # Minimal Release file for flat repo.
  DATE_RFC2822="$(date -Ru)"
  cat > "$workdir/Release" <<EOF
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
    echo "${title}:" >> "$workdir/Release"
    for f in Packages Packages.gz; do
      local hash size
      hash="$($cmd "$workdir/$f" | awk '{print $1}')"
      size="$(wc -c < "$workdir/$f" | tr -d ' ')"
      printf ' %s %16s %s\n' "$hash" "$size" "$f" >> "$workdir/Release"
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
    rm -f "$workdir/InRelease" "$workdir/Release.gpg" || true
    gpg "${gpg_args[@]}" --clearsign -o "$workdir/InRelease" "$workdir/Release"
    gpg "${gpg_args[@]}" --armor --detach-sign -o "$workdir/Release.gpg" "$workdir/Release" || true
  else
    echo "[*] Skipping signing (NEONIDE_GPG_KEY_ID not set or gpg missing)."
  fi
)

# Upload index + metadata first
assets=("$workdir/Packages" "$workdir/Packages.gz" "$workdir/Release")
[ -f "$workdir/InRelease" ] && assets+=("$workdir/InRelease")
[ -f "$workdir/Release.gpg" ] && assets+=("$workdir/Release.gpg")

# Upload *new* debs too (previous debs remain as existing release assets)
for f in "$newdir"/*.deb; do
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
