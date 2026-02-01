# shellcheck shell=bash
# This provides an utility to run binaries under termux environment via proot.
termux_setup_proot() {
	local TERMUX_PROOT_VERSION=5.3.0
	local TERMUX_QEMU_VERSION=7.2.0-1
	local TERMUX_PROOT_BIN="$TERMUX_COMMON_CACHEDIR/proot-bin-$TERMUX_ARCH"
	local TERMUX_PROOT_QEMU=""
	local TERMUX_PROOT_BIN_NAME="termux-proot-run"

	export PATH="$TERMUX_PROOT_BIN:$PATH"

	# If the proot cache directory already exists from a previous run, we still
	# want to (re)generate the wrapper script (termux-proot-run), since its
	# behavior can change over time (e.g. extra bind mounts for /system).
	mkdir -p "$TERMUX_PROOT_BIN"

	if ! [[ -d "$TERMUX_PREFIX/opt/aosp" ]]; then
		echo "ERROR: Add 'aosp-libs' to TERMUX_PKG_BUILD_DEPENDS. 'proot' cannot run without it."
		exit 1
	fi

	if [[ ! -x "$TERMUX_PROOT_BIN/proot" ]]; then
		termux_download https://github.com/proot-me/proot/releases/download/v"$TERMUX_PROOT_VERSION"/proot-v"$TERMUX_PROOT_VERSION"-x86_64-static \
			"$TERMUX_PROOT_BIN/proot" \
			d1eb20cb201e6df08d707023efb000623ff7c10d6574839d7bb42d0adba6b4da
		chmod +x "$TERMUX_PROOT_BIN"/proot
	fi

	declare -A checksums=(
		["aarch64"]="dce64b2dc6b005485c7aa735a7ea39cb0006bf7e5badc28b324b2cd0c73d883f"
		["arm"]="9f07762a3cd0f8a199cb5471a92402a4765f8e2fcb7fe91a87ee75da9616a806"
	)
	if [[ "$TERMUX_ARCH" == "aarch64" ]] || [[ "$TERMUX_ARCH" == "arm" ]]; then
		if [[ ! -x "$TERMUX_PROOT_BIN/qemu-$TERMUX_ARCH" ]]; then
			termux_download https://github.com/multiarch/qemu-user-static/releases/download/v"$TERMUX_QEMU_VERSION"/qemu-"${TERMUX_ARCH/i686/i386}"-static \
				"$TERMUX_PROOT_BIN"/qemu-"$TERMUX_ARCH" \
				"${checksums[$TERMUX_ARCH]}"
			chmod +x "$TERMUX_PROOT_BIN"/qemu-"$TERMUX_ARCH"
		fi
		TERMUX_PROOT_QEMU="-q $TERMUX_PROOT_BIN/qemu-$TERMUX_ARCH"
	fi

	# Bind a minimal Android filesystem layout for qemu/proot.
	#
	# Some cross build tools (notably GHC's external interpreter ghc-iserv) may
	# execute target binaries during compilation. qemu-user expects the Android
	# dynamic linker at /system/bin/linker{,64}.
	#
	# aosp-libs installs a bionic runtime under $TERMUX_PREFIX/opt/aosp.
	# We bind it to /system inside proot, and also set up QEMU_LD_PREFIX so qemu
	# can resolve /system/bin/linker{,64} even when the filesystem emulation layer
	# is bypassed by some tooling.
	local _proot_binds=""
	if [[ -d "$TERMUX_PREFIX/opt/aosp" ]]; then
		_proot_binds+=" -b $TERMUX_PREFIX/opt/aosp:/system"
	fi

	# QEMU_LD_PREFIX expects a directory prefix which contains the target's
	# interpreter + libraries at their absolute paths (e.g. $prefix/system/bin/linker64).
	# Create a small synthetic tree in the proot cache pointing to aosp-libs.
	local _qemu_ld_prefix="$TERMUX_PROOT_BIN/qemu-ld-prefix"
	mkdir -p "$_qemu_ld_prefix/system"
	ln -sfn "$TERMUX_PREFIX/opt/aosp/bin" "$_qemu_ld_prefix/system/bin"
	ln -sfn "$TERMUX_PREFIX/opt/aosp/lib" "$_qemu_ld_prefix/system/lib"
	ln -sfn "$TERMUX_PREFIX/opt/aosp/lib64" "$_qemu_ld_prefix/system/lib64"

	# Ensure qemu-user can resolve the target dynamic linker/libs even when target
	# executables are invoked outside termux-proot-run (e.g. by cabal build tools).
	export QEMU_LD_PREFIX="${QEMU_LD_PREFIX:-$_qemu_ld_prefix}"

	# Provide a minimal /data to satisfy ANDROID_DATA.
	#
	# NOTE: TERMUX_PREFIX (and most Termux runtime paths) live under
	#   $TERMUX_APP__DATA_DIR (typically /data/data/<appId>/...).
	#
	# We bind-mount an empty /data for the Android runtime, but must re-bind the
	# Termux app data directory back into /data so target binaries installed under
	# $TERMUX_PREFIX (e.g. libtasn1's asn1Parser) remain accessible.
	mkdir -p "$TERMUX_PROOT_BIN/proot-data"
	mkdir -p "$TERMUX_PROOT_BIN/proot-data/data"
	_proot_binds+=" -b $TERMUX_PROOT_BIN/proot-data:/data"
	if [[ -n "${TERMUX_APP__DATA_DIR:-}" && -d "${TERMUX_APP__DATA_DIR}" ]]; then
		_proot_binds+=" -b ${TERMUX_APP__DATA_DIR}:${TERMUX_APP__DATA_DIR}"
	fi

	# NOTE: We include current PATH too so that host binaries also become available under proot.
	cat <<-EOF >"$TERMUX_PROOT_BIN/$TERMUX_PROOT_BIN_NAME"
		#!/bin/bash
		env -i \
			PATH="$TERMUX_PREFIX/bin:$PATH" \
			ANDROID_DATA=/data \
			ANDROID_ROOT=/system \
			QEMU_LD_PREFIX="$_qemu_ld_prefix" \
			HOME=$TERMUX_ANDROID_HOME \
			LANG=en_US.UTF-8 \
			PREFIX=$TERMUX_PREFIX \
			TERM=$TERM \
			TZ=UTC \
			$TERMUX_PROOT_EXTRA_ENV_VARS \
			$TERMUX_PROOT_BIN/proot $TERMUX_PROOT_QEMU $_proot_binds -R / "\$@"
	EOF
	chmod +x "$TERMUX_PROOT_BIN/$TERMUX_PROOT_BIN_NAME"
}
