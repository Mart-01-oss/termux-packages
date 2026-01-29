TERMUX_PKG_HOMEPAGE=https://github.com/Mart-01-oss/pages
TERMUX_PKG_DESCRIPTION="GPG public keys for NeonIDE repositories"
TERMUX_PKG_LICENSE="Apache-2.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=3.13
TERMUX_PKG_AUTO_UPDATE=false
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_PLATFORM_INDEPENDENT=true
TERMUX_PKG_ESSENTIAL=true

NEONIDE_KEY_URL="https://github.com/Mart-01-oss/pages/releases/download/Package/neonide.gpg"
NEONIDE_KEY_SHA256="f68a9a51096bf4d7abdd263ee370db33883cf9fa15adebba7afa7a5ed155aef0"
# Fingerprint of neonide.gpg (used for pacman trusted file).
NEONIDE_KEY_FPR="C5973CF65781972D094B9DF10973F7EA602AA7D6"

termux_step_make_install() {
	local GPG_SHARE_DIR="$TERMUX_PREFIX/share/termux-keyring"

	# Delete all existing termux-keyring keys
	rm -rf "$GPG_SHARE_DIR"
	mkdir -p "$GPG_SHARE_DIR"

	# Download and install NeonIDE repository signing key.
	local key_tmp="$TERMUX_PKG_TMPDIR/neonide.gpg"
	termux_download "$NEONIDE_KEY_URL" "$key_tmp" "$NEONIDE_KEY_SHA256"
	install -Dm600 "$key_tmp" "$GPG_SHARE_DIR/neonide.gpg"

	# Create symlinks under all GPG_DIRs to key files under GPG_SHARE_DIR
	for GPG_DIR in "$TERMUX_PREFIX/etc/apt/trusted.gpg.d" "$TERMUX_PREFIX/share/pacman/keyrings"; do
		mkdir -p "$GPG_DIR"
		# Delete keys which have been removed in newer version and their symlink target does not exist
		find "$GPG_DIR" -xtype l -printf 'Deleting removed key: %p\n' -delete
		for GPG_FILE in "$GPG_SHARE_DIR"/*.gpg; do
			# Create or overwrite key symlink
			ln -sf "$GPG_FILE" "$GPG_DIR/$(basename "$GPG_FILE")"
		done
		# Creation of trusted files
		if [[ "$GPG_DIR" == *"/pacman/"* ]]; then
			echo "${NEONIDE_KEY_FPR}:4:" > "$GPG_DIR/termux-pacman-trusted"
		fi
	done
}

termux_step_create_debscripts() {
	if [ "$TERMUX_PACKAGE_FORMAT" = "pacman" ]; then
		echo "if [ ! -d $TERMUX_PREFIX/etc/pacman.d/gnupg/ ]; then" > postupg
		echo "  pacman-key --init" >> postupg
		echo "fi" >> postupg
		echo "pacman-key --populate" >> postupg
		echo "post_upgrade" > postinst
	fi
}
