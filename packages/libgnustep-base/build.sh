TERMUX_PKG_HOMEPAGE=https://www.gnustep.org
TERMUX_PKG_DESCRIPTION="A library of general-purpose, non-graphical Objective C objects"
TERMUX_PKG_LICENSE="GPL-2.0, LGPL-2.1"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="1.31.1"
TERMUX_PKG_REVISION=3
TERMUX_PKG_SRCURL=https://github.com/gnustep/libs-base/releases/download/base-${TERMUX_PKG_VERSION//./_}/gnustep-base-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=e7546f1c978a7c75b676953a360194a61e921cb45a4804497b4f346a460545cd
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_VERSION_REGEXP='(?<=-).+'
TERMUX_PKG_DEPENDS="gnustep-make, libcurl, libc++, libffi, libgmp, libgnutls, libiconv, libicu, libobjc2, libxml2, libxslt, zlib"
# Ensure Objective-C runtime is available in the build environment.
# Some build environments only install TERMUX_PKG_BUILD_DEPENDS.
TERMUX_PKG_BUILD_DEPENDS="libobjc2"
TERMUX_PKG_BUILD_IN_SRC=true

# Some build environments / GNUstep makefile setups may ignore env overrides;
# pass via make command line to ensure -lobjc is on the link line.
TERMUX_PKG_EXTRA_MAKE_ARGS="
ADDITIONAL_OBJC_LIBS=-lobjc
# clang may lower patterns like [[Foo alloc] init] into objc_alloc_init (not
# provided by libobjc2 on Android). Ensure this optimization is disabled even if
# GNUstep make ignores OBJCFLAGS from the environment.
CFLAGS+=-fno-objc-convert-messages-to-runtime-calls
OBJCFLAGS+=-fno-objc-convert-messages-to-runtime-calls
ADDITIONAL_OBJCFLAGS=-fno-objc-convert-messages-to-runtime-calls
"

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
--with-default-config=$TERMUX_PREFIX/etc/GNUstep/GNUstep.conf
--enable-procfs
--disable-procfs-psinfo
iswindows=no
cross_reuseaddr_ok=1
cross_gs_cv_objc_works=yes
cross_gs_cv_objc_compiler_supports_constant_string_class=yes
cross_gs_cv_objc_load_method_worked=yes
cross_have_poll=yes
cross_VSPRINTF_RETURNS_LENGTH=1
cross_VASPRINTF_RETURNS_LENGTH=1
cross_NEED_WORD_ALIGNMENT=1
cross_working_register_printf=0
cross_wide_register_printf=0
cross_gs_cv_program_invocation_name_worked=no
cross_CMDLINE_TERMINATED=1
cross_have_kvm_env=0
cross_ffi_ok=yes
cross_non_fragile=yes
cross_have_unexpected=yes
cross_safe_initialize=yes
cross_found_iconv_libc=no
cross_found_iconv_liconv=yes
cross_found_iconv_lgiconv=no
cross_objc2_runtime=1
ac_cv_func_setpgrp_void=yes
"

termux_step_pre_configure() {
	# GNUstep tools are Objective-C programs and need the Objective-C runtime.
	# Add -lobjc via GNUstep make variables so it ends up in ALL_LIBS (after
	# object files), avoiding --as-needed ordering issues.
	export ADDITIONAL_OBJC_LIBS="${ADDITIONAL_OBJC_LIBS:-} -lobjc"
	# clang may lower patterns like [[Foo alloc] init] into objc_alloc_init.
	# libobjc2 on Android does not provide objc_alloc_init, so ensure this
	# optimization is disabled for *all* Objective-C compilation.
	#
	# GNUstep make's makefiles don't consistently honor OBJCFLAGS in all build
	# modes, but they do honor the compiler's CFLAGS, so set both.
	export CFLAGS="${CFLAGS:-} -fno-objc-convert-messages-to-runtime-calls"
	export OBJCFLAGS="${OBJCFLAGS:-} -fno-objc-convert-messages-to-runtime-calls"
	export ADDITIONAL_OBJCFLAGS="${ADDITIONAL_OBJCFLAGS:-} -fno-objc-convert-messages-to-runtime-calls"
	export LDFLAGS="${LDFLAGS:-} -lobjc"

	local bin="$TERMUX_PKG_BUILDDIR/bin"
	mkdir -p "$bin"
	local sh="$(command -v sh)"
	for cmd in CC CPP CXX; do
		local wrapper="$bin/$(basename $(eval echo \${$cmd}))"
		cat > "$wrapper" <<-EOF
			#!${sh}
			unset LD_PRELOAD
			unset LD_LIBRARY_PATH
			exec $(command -v $(eval echo \${$cmd})) "\$@"
		EOF
		chmod 0700 "$wrapper"
	done
	export PATH="$bin":$PATH

	rm -f cross.config
	touch cross.config

	# In configure step, $TERMUX_PREFIX will be appended to PATH, and
	# it will break the build process. Rename these tools and recover
	# later if not on device.
	# See https://github.com/gnustep/libs-base/blob/5ea68724ff6b49d935101246de38ffd955d57f50/configure.ac#L1016
	if [ "$TERMUX_ON_DEVICE_BUILD" = false ]; then
		local _tool
		for _tool in awk bash cat chmod dirname expr grep mkdir mv rm sed sort tr; do
			if [ -e $TERMUX_PREFIX/bin/$_tool ]; then
				mv $TERMUX_PREFIX/bin/{$_tool,$_tool.gnustepbase}
			fi
		done
	fi
}

termux_step_post_make_install() {
	if [ "$TERMUX_ON_DEVICE_BUILD" = false ]; then
		local _tool
		for _tool in awk bash cat chmod dirname expr grep mkdir mv rm sed sort tr; do
			if [ -e $TERMUX_PREFIX/bin/"$_tool.gnustepbase" ]; then
				mv $TERMUX_PREFIX/bin/{$_tool.gnustepbase,$_tool}
			fi
		done
	fi
}

termux_step_post_massage() {
	if [ "$TERMUX_ON_DEVICE_BUILD" == true ]; then
		return
	fi

	cd "$TERMUX_PKG_MASSAGEDIR"/$TERMUX_PREFIX/bin || exit 1
	local _tool
	for _tool in awk bash cat chmod dirname expr grep mkdir mv rm sed sort tr; do
		rm -f $_tool
	done
}
