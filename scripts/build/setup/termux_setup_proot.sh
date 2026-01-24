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
	# aosp-libs installs a bionic runtime under $TERMUX_PREFIX/opt/aosp, so bind
	# that directory to /system inside proot.
	local _proot_binds=""
	if [[ -d "$TERMUX_PREFIX/opt/aosp" ]]; then
		_proot_binds+=" -b $TERMUX_PREFIX/opt/aosp:/system"
	fi
	# Provide an empty /data to satisfy ANDROID_DATA.
	mkdir -p "$TERMUX_PROOT_BIN/proot-data"
	_proot_binds+=" -b $TERMUX_PROOT_BIN/proot-data:/data"

	# NOTE: We include current PATH too so that host binaries also become available under proot.
	cat <<-EOF >"$TERMUX_PROOT_BIN/$TERMUX_PROOT_BIN_NAME"
		#!/bin/bash
		env -i \
			PATH="$TERMUX_PREFIX/bin:$PATH" \
			ANDROID_DATA=/data \
			ANDROID_ROOT=/system \
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
