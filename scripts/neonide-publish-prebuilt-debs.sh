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
#
# Large deb handling (to avoid bloating the Pages repo):
#   NEONIDE_LARGE_DEB_PUBLISH_MODE
#     - pages   (default): publish debs into pages repo pool/ as usual
#     - release: do NOT store large debs in pages repo; instead reference them by URL
#                directly in Packages (and Packages.gz). To keep large packages
#                available across runs, this script extracts previously-published
#                URL-based stanzas from the existing Packages file and merges them
#                back when regenerating Packages.
#   NEONIDE_LARGE_DEB_THRESHOLD_MB   (default: 99) size threshold in MiB
#   NEONIDE_LARGE_DEB_RELEASE_BASE_URL
#     Base URL for release assets, e.g.
#       https://github.com/<owner>/<repo>/releases/download/<tag>
#     The deb filename will be appended (e.g. .../cmake_1.2.3_aarch64.deb).
#
# Packages Filename formatting:
#   NEONIDE_PACKAGES_PREFIX_DOTSLASH (default: true)
#     If true, prefix relative Filename entries with "./" (e.g. ./pool/...).
#     Absolute URLs (https://...) are left untouched and are used only for
#     release-hosted large debs.

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

: "${NEONIDE_LARGE_DEB_PUBLISH_MODE:=pages}"
: "${NEONIDE_LARGE_DEB_THRESHOLD_MB:=99}"
: "${NEONIDE_LARGE_DEB_RELEASE_BASE_URL:=}"
: "${NEONIDE_PACKAGES_PREFIX_DOTSLASH:=true}"

# Optional validation/selection
: "${EXPECTED_PACKAGES:=}"           # space/newline separated list of package names expected
: "${FAIL_ON_RECIPE_MISMATCH:=false}" # if true, abort when metadata mismatches are found

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

is_large_deb() {
  local deb="$1"
  local bytes
  bytes="$(stat -c%s "$deb" 2>/dev/null || wc -c < "$deb")"
  # MiB threshold
  local thresh_bytes=$((NEONIDE_LARGE_DEB_THRESHOLD_MB * 1024 * 1024))
  [[ "$bytes" -ge "$thresh_bytes" ]]
}

# Remove any existing stanza for a binary package from a Packages-like file.
# We keep only one stanza per Package: to avoid accumulating old versions.
remove_pkg_stanza() {
  local pkg="$1" file="$2"
  [[ ! -f "$file" ]] && return 0
  local tmp
  tmp="$(mktemp)"
  awk -v pkg="$pkg" 'BEGIN{RS=""; ORS="\n\n"; FS="\n"}
    {
      keep=1
      for(i=1;i<=NF;i++){
        if($i=="Package: "pkg){keep=0; break}
      }
      if(keep){print $0}
    }' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

# Generate a Packages stanza for a single deb by running dpkg-scanpackages on a temp pool.
# Prints the stanza to stdout.
generate_packages_stanza_for_deb() {
  local deb="$1" pkg="$2" apt_component="$3"
  local group="$(pool_group_for_pkg "$pkg")"

  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/pool/${apt_component}/$group/$pkg"
  cp -f "$deb" "$tmpdir/pool/${apt_component}/$group/$pkg/"

  (
    cd "$tmpdir"
    dpkg-scanpackages -m pool /dev/null
  )
  rm -rf "$tmpdir"
}

# Normalize Filename: fields for apt Packages files.
# - Keep absolute URLs as-is (https://...)
# - Prefix relative paths with "./" if enabled.
normalize_packages_filenames_inplace() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  [[ "$NEONIDE_PACKAGES_PREFIX_DOTSLASH" == "true" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  awk 'BEGIN{OFS=""}
    {
      if ($0 ~ /^Filename: /) {
        fn=$0
        sub(/^Filename: /, "", fn)
        if (fn ~ /^https?:\/\//) { print $0; next }
        if (fn ~ /^\.\//) { print $0; next }
        print "Filename: ./", fn; next
      }
      print $0
    }' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

get_pkg_name_from_deb() {
  local deb="$1"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -f "$deb" Package 2>/dev/null || true
  fi
}

normalize_ws_list() {
  tr ' \t\r\n' '\n' | sed '/^$/d' | sort -u
}

EXPECTED_PACKAGES_NL=""
if [[ -n "$EXPECTED_PACKAGES" ]]; then
  EXPECTED_PACKAGES_NL="$(normalize_ws_list <<<"$EXPECTED_PACKAGES")"
  echo "[*] EXPECTED_PACKAGES set:"
  echo "$EXPECTED_PACKAGES_NL" | sed 's/^/  - /'
fi

expected_set_contains() {
  local name="$1"
  [[ -z "$EXPECTED_PACKAGES_NL" ]] && return 0
  grep -qx -- "$name" <<<"$EXPECTED_PACKAGES_NL"
}

# Extract a few key fields from a recipe build.sh by sourcing it.
# NOTE: Build scripts are trusted code in this repo. We only read variables.
recipe_field() {
  local pkg="$1" field="$2"
  local script=""
  for d in packages x11-packages root-packages disabled-packages; do
    if [[ -f "$PWD/$d/$pkg/build.sh" ]]; then
      script="$PWD/$d/$pkg/build.sh"
      break
    fi
  done
  [[ -z "$script" ]] && return 0

  # shellcheck disable=SC1090
  (
    # Package recipes sometimes reference TERMUX_PREFIX/TERMUX_SCRIPTDIR etc.
    # When this script runs in GitHub Actions, those are not set. Also, this
    # script uses 'set -u', so we must provide safe defaults.
    set +u
    : "${TERMUX_PREFIX:=/data/data/com.neonide.studio/files/usr}"
    : "${TERMUX_SCRIPTDIR:=$PWD}"
    source "$script"
    set -u

    case "$field" in
      homepage) echo "${TERMUX_PKG_HOMEPAGE:-}";;
      description) echo "${TERMUX_PKG_DESCRIPTION:-}";;
      maintainer) echo "${TERMUX_PKG_MAINTAINER:-}";;
      depends) echo "${TERMUX_PKG_DEPENDS:-}";;
      recommends) echo "${TERMUX_PKG_RECOMMENDS:-}";;
      *) echo "";;
    esac
  )
}

deb_field() {
  local deb="$1" field="$2"
  dpkg-deb -f "$deb" "$field" 2>/dev/null || true
}

mismatch=0
copied=0
external_added=0

PACKAGES_DIR_REL="dists/${APT_DIST}/${APT_COMPONENT}/binary-${APT_ARCH}"
PACKAGES_PATH="$PAGES_REPO_DIR/${PACKAGES_DIR_REL}/Packages"
mkdir -p "$PAGES_REPO_DIR/${PACKAGES_DIR_REL}"

# NOTE:
# We intentionally do NOT use a separate Packages.external file.
# APT will only ever read Packages (and Packages.gz), so we keep all stanzas there.
# For "release-hosted" large debs, we preserve their stanzas by extracting them from
# the previous Packages file and merging them back on each run.
EXISTING_RELEASE_STANZAS_FILE="$(mktemp)"
NEW_RELEASE_STANZAS_FILE="$(mktemp)"
: > "$EXISTING_RELEASE_STANZAS_FILE"
: > "$NEW_RELEASE_STANZAS_FILE"

extract_release_hosted_stanzas() {
  local packages_file="$1"
  local out_file="$2"
  : > "$out_file"
  [[ -f "$packages_file" ]] || return 0

  # Extract only paragraph stanzas whose Filename is an absolute URL.
  # (We specifically use this for large debs hosted outside the Pages git repo.)
  awk 'BEGIN{RS=""; ORS="\n\n"; FS="\n"}
    {
      keep=0
      for(i=1;i<=NF;i++){
        if($i ~ /^Filename: https?:\/\//){ keep=1; break }
      }
      if(keep){ print $0 }
    }' "$packages_file" >> "$out_file"
}

# Seed EXISTING_RELEASE_STANZAS_FILE from the currently published Packages file (if any).
extract_release_hosted_stanzas "$PACKAGES_PATH" "$EXISTING_RELEASE_STANZAS_FILE"

# If an older workflow run created Packages.external, delete it to avoid confusing tooling/users.
rm -f "$PAGES_REPO_DIR/${PACKAGES_DIR_REL}/Packages.external" 2>/dev/null || true

if [[ "$NEONIDE_LARGE_DEB_PUBLISH_MODE" == "release" && -z "$NEONIDE_LARGE_DEB_RELEASE_BASE_URL" ]]; then
  echo "ERROR: NEONIDE_LARGE_DEB_PUBLISH_MODE=release requires NEONIDE_LARGE_DEB_RELEASE_BASE_URL" >&2
  exit 1
fi

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

  if ! expected_set_contains "$pkg"; then
    echo "[=] Skipping $pkg (not in EXPECTED_PACKAGES)"
    continue
  fi

  # Validate deb control metadata vs recipe metadata (best-effort).
  recipe_homepage="$(recipe_field "$pkg" homepage)"
  recipe_maint="$(recipe_field "$pkg" maintainer)"
  recipe_depends="$(recipe_field "$pkg" depends)"
  recipe_recommends="$(recipe_field "$pkg" recommends)"

  deb_maint="$(deb_field "$deb" Maintainer)"
  deb_homepage="$(deb_field "$deb" Homepage)"
  deb_depends="$(deb_field "$deb" Depends)"
  deb_recommends="$(deb_field "$deb" Recommends)"

  # TERMUX_PKG_MAINTAINER is often a GitHub handle like "@termux".
  # Debian control Maintainer is typically an email/name. Treat mismatches as informational
  # unless the recipe maintainer looks like an email.
  if [[ -n "$recipe_maint" && -n "$deb_maint" ]]; then
    if [[ "$recipe_maint" == *"@"* && "$deb_maint" != *"$recipe_maint"* ]]; then
      echo "[!] MISMATCH $pkg: Maintainer\n    recipe: $recipe_maint\n    deb:    $deb_maint" >&2
      mismatch=1
    else
      :
    fi
  fi
  if [[ -n "$recipe_homepage" && -n "$deb_homepage" && "$deb_homepage" != "$recipe_homepage" ]]; then
    echo "[!] MISMATCH $pkg: Homepage\n    recipe: $recipe_homepage\n    deb:    $deb_homepage" >&2
    mismatch=1
  fi
  # Loose checks for depends/recommends because formats differ between recipe and control.
  if [[ -n "$recipe_depends" && -n "$deb_depends" ]]; then
    : # (informational only)
  fi
  if [[ -n "$recipe_recommends" && -n "$deb_recommends" ]]; then
    : # (informational only)
  fi

  # Large deb handling: keep deb out of pages repo, but keep its stanza in Packages
  # and set Filename to the GitHub Release asset URL.
  if [[ "$NEONIDE_LARGE_DEB_PUBLISH_MODE" == "release" ]] && is_large_deb "$deb"; then
    echo "[*] Large deb detected (>=${NEONIDE_LARGE_DEB_THRESHOLD_MB}MiB): $(basename "$deb")"

    # Generate package stanza using dpkg-scanpackages on a temporary pool.
    stanza="$(generate_packages_stanza_for_deb "$deb" "$pkg" "$APT_COMPONENT")"

    # Replace Filename: with absolute URL pointing at release asset.
    # dpkg-scanpackages emits: Filename: pool/<component>/<group>/<pkg>/<file>
    release_url="${NEONIDE_LARGE_DEB_RELEASE_BASE_URL%/}/$(basename "$deb")"
    stanza="$(sed -E "s|^Filename: .*|Filename: ${release_url}|" <<<"$stanza")"

    # If an existing release-hosted stanza already matches (same Filename + SHA256), skip updating.
    want_sha="$(awk -F': ' '$1=="SHA256"{print $2; exit}' <<<"$stanza")"
    want_fn="$(awk -F': ' '$1=="Filename"{print $2; exit}' <<<"$stanza")"
    if awk -v pkg="$pkg" -v sha="$want_sha" -v fn="$want_fn" 'BEGIN{RS="";FS="\n"}
        {
          p=""; s=""; f="";
          for(i=1;i<=NF;i++){
            if($i=="Package: "pkg){p=1}
            else if($i=="SHA256: "sha){s=1}
            else if($i=="Filename: "fn){f=1}
          }
          if(p && s && f){found=1}
        }
        END{exit(found?0:1)}' "$EXISTING_RELEASE_STANZAS_FILE"; then
      echo "[=] Release-hosted stanza already up-to-date for $pkg"
      continue
    fi

    # Remove old stanza for this Package from existing release-hosted set (if present)
    # and append the updated stanza to the new set.
    remove_pkg_stanza "$pkg" "$EXISTING_RELEASE_STANZAS_FILE"
    {
      if [[ -s "$NEW_RELEASE_STANZAS_FILE" ]]; then
        printf '\n'
      fi
      printf '%s\n' "$stanza" | sed -e '${/^$/d;}'
      printf '\n'
    } >> "$NEW_RELEASE_STANZAS_FILE"

    echo "[+] Added/updated release-hosted package stanza for $pkg -> $release_url"
    external_added=1
    continue
  fi

  group="$(pool_group_for_pkg "$pkg")"
  dest_dir="$PAGES_REPO_DIR/pool/${APT_COMPONENT}/$group/$pkg"
  mkdir -p "$dest_dir"

  dest_path="$dest_dir/$(basename "$deb")"

  if [[ "$FORCE_OVERWRITE" == "true" ]]; then
    # Force mode: remove older debs for this package so the pool doesn't
    # accumulate multiple versions and so metadata updates clearly.
    rm -f "$dest_dir/${pkg}_"*.deb 2>/dev/null || true
  elif [[ -f "$dest_path" ]]; then
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

if [[ "$FAIL_ON_RECIPE_MISMATCH" == "true" && $mismatch -ne 0 ]]; then
  echo "ERROR: Recipe/deb metadata mismatches detected and FAIL_ON_RECIPE_MISMATCH=true" >&2
  exit 1
fi

if [[ $copied -ne 1 ]]; then
  echo "WARN: No .deb files were published from $DEBS_DIR" >&2
fi

echo "[*] Regenerating Packages and Packages.gz from pool (+ release-hosted URL stanzas if present)..."
(
  cd "$PAGES_REPO_DIR"
  mkdir -p "$PACKAGES_DIR_REL"

  tmp_packages="${PACKAGES_DIR_REL}/Packages.tmp"
  dpkg-scanpackages -m pool /dev/null > "$tmp_packages"

  # Merge in release-hosted package stanzas (large debs stored in GitHub Releases).
  #
  # - EXISTING_RELEASE_STANZAS_FILE contains stanzas extracted from the *previous* Packages file.
  #   We keep these so large packages remain installable even if they were not part of this run.
  # - NEW_RELEASE_STANZAS_FILE contains stanzas for large debs from this run.
  if [[ -s "$EXISTING_RELEASE_STANZAS_FILE" || -s "$NEW_RELEASE_STANZAS_FILE" ]]; then
    printf '\n' >> "$tmp_packages"
    [[ -s "$EXISTING_RELEASE_STANZAS_FILE" ]] && cat "$EXISTING_RELEASE_STANZAS_FILE" >> "$tmp_packages"
    [[ -s "$NEW_RELEASE_STANZAS_FILE" ]] && cat "$NEW_RELEASE_STANZAS_FILE" >> "$tmp_packages"
  fi

  mv -f "$tmp_packages" "$PACKAGES_DIR_REL/Packages"

  # Ensure relative filenames have the expected ./ prefix (URLs untouched).
  normalize_packages_filenames_inplace "$PACKAGES_DIR_REL/Packages"

  # Keep output identical to scripts/neonide-build-and-publish-pages.sh
  gzip -9 -c "$PACKAGES_DIR_REL/Packages" > "$PACKAGES_DIR_REL/Packages.gz"
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
