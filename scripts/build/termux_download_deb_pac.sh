#!/usr/bin/bash

termux_download_deb_pac() {
	local PACKAGE=$1
	local PACKAGE_ARCH=$2
	local VERSION=$3
	local VERSION_PACMAN=$4

	local PKG_FILE
	if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
		PKG_FILE="${PACKAGE}_${VERSION}_${PACKAGE_ARCH}.deb"
	elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
		PKG_FILE="${PACKAGE}-${VERSION_PACMAN}-${PACKAGE_ARCH}.pkg.tar.xz"
	fi
	PKG_HASH=""

	# Dependencies should be used from repo only if they are built for
	# same runtime paths as the current build environment.
	#
	# The data.tar.xz extraction by termux_step_get_dependencies extracts files
	# directly into /, so if repo packages were built for a different TERMUX_PREFIX
	# (e.g. /data/data/com.termux/files/usr vs /data/data/com.neonide.studio/files/usr),
	# builds will fail when searching headers/libs under $TERMUX_PREFIX.
	if [ "$TERMUX_REPO_APP__PACKAGE_NAME" != "$TERMUX_APP_PACKAGE" ]; then
		echo "Ignoring download of $PKG_FILE since repo package name ($TERMUX_REPO_APP__PACKAGE_NAME) does not equal app package name ($TERMUX_APP_PACKAGE)"
		return 1
	fi
	if [ "${TERMUX_REPO__PREFIX:-}" != "${TERMUX_PREFIX:-}" ]; then
		echo "Ignoring download of $PKG_FILE since repo prefix (${TERMUX_REPO__PREFIX:-<unset>}) does not equal build prefix (${TERMUX_PREFIX:-<unset>})"
		return 1
	fi

	if [ "$TERMUX_ON_DEVICE_BUILD" = "true" ]; then
		case "$TERMUX_APP_PACKAGE_MANAGER" in
			"apt") apt install -y "${PACKAGE}$(test ${TERMUX_WITHOUT_DEPVERSION_BINDING} != true && echo "=${VERSION}")";;
			"pacman") pacman -S "${PACKAGE}$(test ${TERMUX_WITHOUT_DEPVERSION_BINDING} != true && echo "=${VERSION_PACMAN}")" --needed --noconfirm;;
		esac
		return "$?"
	fi

	for idx in $(seq ${#TERMUX_REPO_URL[@]}); do
		local TERMUX_REPO_NAME=$(echo ${TERMUX_REPO_URL[$idx-1]} | sed -e 's%https://%%g' -e 's%http://%%g' -e 's%/%-%g')
		if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
			local PACKAGE_FILE_PATH="${TERMUX_REPO_NAME}-${TERMUX_REPO_DISTRIBUTION[$idx-1]}-${TERMUX_REPO_COMPONENT[$idx-1]}-Packages"
		elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
			local PACKAGE_FILE_PATH="${TERMUX_REPO_NAME}-json"
		fi
		if [ "${PACKAGE_ARCH}" = 'all' ]; then
			for arch in 'aarch64' 'arm' 'i686' 'x86_64'; do
				if [ -f "${TERMUX_COMMON_CACHEDIR}-${arch}/${PACKAGE_FILE_PATH}" ]; then
					if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
						read -d "\n" PKG_PATH PKG_HASH <<<$(./scripts/get_hash_from_file.py "${TERMUX_COMMON_CACHEDIR}-${arch}/$PACKAGE_FILE_PATH" $PACKAGE $VERSION)
					elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
						if [ "$TERMUX_WITHOUT_DEPVERSION_BINDING" = "true" ] || [ $(jq -r '."'$PACKAGE'"."VERSION"' "${TERMUX_COMMON_CACHEDIR}-${arch}/$PACKAGE_FILE_PATH") = "${VERSION_PACMAN}" ]; then
							PKG_HASH=$(jq -r '."'$PACKAGE'"."SHA256SUM"' "${TERMUX_COMMON_CACHEDIR}-${arch}/$PACKAGE_FILE_PATH")
							PKG_PATH=$(jq -r '."'$PACKAGE'"."FILENAME"' "${TERMUX_COMMON_CACHEDIR}-${arch}/$PACKAGE_FILE_PATH")
							# If Packages provides an absolute URL (e.g. GitHub Releases), don't prefix with arch.
							if [[ "$PKG_PATH" =~ ^https?:// ]]; then
								:
							else
								PKG_PATH="${arch}/${PKG_PATH}"
							fi
						fi
					fi
					if [ -n "$PKG_HASH" ] && [ "$PKG_HASH" != "null" ]; then
						if [ ! "$TERMUX_QUIET_BUILD" = true ]; then
							if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
								echo "Found $PACKAGE in ${TERMUX_REPO_URL[$idx-1]}/dists/${TERMUX_REPO_DISTRIBUTION[$idx-1]}"
							elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
								echo "Found $PACKAGE in ${TERMUX_REPO_URL[$idx-1]}"
							fi
						fi
						break 2
					fi
				fi
			done
		elif [ ! -f "${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/${PACKAGE_FILE_PATH}" ] && \
			[ -f "${TERMUX_COMMON_CACHEDIR}-aarch64/${PACKAGE_FILE_PATH}" ]; then
			# Packages file for $PACKAGE_ARCH did not
			# exist. Could be an aptly mirror where the
			# all arch is mixed into the other arches,
			# check for package in aarch64 Packages
			# instead.
			if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
				read -d "\n" PKG_PATH PKG_HASH <<<$(./scripts/get_hash_from_file.py "${TERMUX_COMMON_CACHEDIR}-aarch64/$PACKAGE_FILE_PATH" $PACKAGE $VERSION)
			elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
				if [ "$TERMUX_WITHOUT_DEPVERSION_BINDING" = "true" ] || [ $(jq -r '."'$PACKAGE'"."VERSION"' "${TERMUX_COMMON_CACHEDIR}-aarch64/$PACKAGE_FILE_PATH") = "${VERSION_PACMAN}"]; then
					PKG_HASH=$(jq -r '."'$PACKAGE'"."SHA256SUM"' "${TERMUX_COMMON_CACHEDIR}-aarch64/$PACKAGE_FILE_PATH")
					PKG_PATH=$(jq -r '."'$PACKAGE'"."FILENAME"' "${TERMUX_COMMON_CACHEDIR}-aarch64/$PACKAGE_FILE_PATH")
					if [[ "$PKG_PATH" =~ ^https?:// ]]; then
						:
					else
						PKG_PATH="aarch64/${PKG_PATH}"
					fi
				fi
			fi
			if [ -n "$PKG_HASH" ] && [ "$PKG_HASH" != "null" ]; then
				if [ ! "$TERMUX_QUIET_BUILD" = true ]; then
					if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
						echo "Found $PACKAGE in ${TERMUX_REPO_URL[$idx-1]}/dists/${TERMUX_REPO_DISTRIBUTION[$idx-1]}"
					elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
						echo "Found $PACKAGE in ${TERMUX_REPO_URL[$idx-1]}"
					fi
				fi
				break
			fi
		elif [ -f "${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/${PACKAGE_FILE_PATH}" ]; then
			if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
				read -d "\n" PKG_PATH PKG_HASH <<<$(./scripts/get_hash_from_file.py "${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/$PACKAGE_FILE_PATH" $PACKAGE $VERSION)
			elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
				if [ "$TERMUX_WITHOUT_DEPVERSION_BINDING" = "true" ] || [ $(jq -r '."'$PACKAGE'"."VERSION"' "${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/$PACKAGE_FILE_PATH") = "${VERSION_PACMAN}" ]; then
					PKG_HASH=$(jq -r '."'$PACKAGE'"."SHA256SUM"' "${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/$PACKAGE_FILE_PATH")
					PKG_PATH=$(jq -r '."'$PACKAGE'"."FILENAME"' "${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/$PACKAGE_FILE_PATH")
					if [[ "$PKG_PATH" =~ ^https?:// ]]; then
						:
					else
						PKG_PATH="${PACKAGE_ARCH}/${PKG_PATH}"
					fi
				fi
			fi
			if [ -n "$PKG_HASH" ] && [ "$PKG_HASH" != "null" ]; then
				if [ ! "$TERMUX_QUIET_BUILD" = true ]; then
					if [ "$TERMUX_REPO_PKG_FORMAT" = "debian" ]; then
						echo "Found $PACKAGE in ${TERMUX_REPO_URL[$idx-1]}/dists/${TERMUX_REPO_DISTRIBUTION[$idx-1]}"
					elif [ "$TERMUX_REPO_PKG_FORMAT" = "pacman" ]; then
						echo "Found $PACKAGE in ${TERMUX_REPO_URL[$idx-1]}"
					fi
				fi
				break
			fi
		fi
	done

	# If not found in standard repos, optionally fall back to a flat GitHub Release repo.
	# This allows reusing already-built *large* packages hosted as release assets.
	if [ "$PKG_HASH" = "" ] || [ "$PKG_HASH" = "null" ]; then
		if [[ -n "${TERMUX_RELEASE_DEB_REPO_URL:-}" ]]; then
			local release_base="${TERMUX_RELEASE_DEB_REPO_URL%/}"
			local release_packages_url="${TERMUX_RELEASE_DEB_REPO_PACKAGES_URL:-${release_base}/Packages}"
			local tmp_packages="${TERMUX_COMMON_CACHEDIR:-/tmp}/release-flat-Packages"

			# Best-effort fetch (no hash pinning here). We will still validate the .deb download via SHA256 from Packages.
			if curl -LfsS "$release_packages_url" -o "$tmp_packages" 2>/dev/null; then
				local found_line
				found_line="$(awk -v pkg="$PACKAGE" -v ver="$VERSION" 'BEGIN{RS="";FS="\n"}
					{
						p="";v="";fn="";sha="";
						for(i=1;i<=NF;i++){
							if($i ~ /^Package: /){sub(/^Package: /,"",$i); p=$i}
							else if($i ~ /^Version: /){sub(/^Version: /,"",$i); v=$i}
							else if($i ~ /^Filename: /){sub(/^Filename: /,"",$i); fn=$i}
							else if($i ~ /^SHA256: /){sub(/^SHA256: /,"",$i); sha=$i}
						}
						if(p==pkg && v==ver && fn!="" && sha!=""){print fn"|"sha; exit 0}
					}
				' "$tmp_packages" || true)"

				if [[ -n "$found_line" ]]; then
					PKG_PATH="${found_line%%|*}"
					PKG_HASH="${found_line#*|}"
					# Build URL from flat repo base + filename (strip leading ./)
					PKG_PATH="${PKG_PATH#./}"
					local url="${release_base}/${PKG_PATH}"
					[[ "$TERMUX_QUIET_BUILD" != true ]] && echo "Found $PACKAGE in release repo ${release_base}"
					termux_download "$url" \
							"${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/${PKG_FILE}" \
							"$PKG_HASH"
					return $?
				fi
			fi
		fi

		return 1
	fi

	# Packages 'Filename:' is usually a relative path under the repo base URL.
	# However, for externally-hosted packages we support absolute URLs (e.g. GitHub Releases).
	local url
	if [[ "$PKG_PATH" =~ ^https?:// ]]; then
		url="$PKG_PATH"
	else
		url="${TERMUX_REPO_URL[${idx}-1]}/${PKG_PATH}"
	fi

	termux_download "$url" \
				"${TERMUX_COMMON_CACHEDIR}-${PACKAGE_ARCH}/${PKG_FILE}" \
				"$PKG_HASH"
}

# Make script standalone executable as well as sourceable
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	termux_download "$@"
fi
