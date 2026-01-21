TERMUX_PKG_HOMEPAGE=https://github.com/open-source-parsers/jsoncpp
TERMUX_PKG_DESCRIPTION="C++ library for interacting with JSON"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=1.9.6
TERMUX_PKG_REVISION=3
TERMUX_PKG_SRCURL=https://github.com/open-source-parsers/jsoncpp/archive/refs/tags/${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=f93b6dd7ce796b13d02c108bc9f79812245a82e577581c4c9aabe57075c90ea2
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_DEPENDS="libc++"
TERMUX_PKG_BREAKS="jsoncpp-dev"
TERMUX_PKG_REPLACES="jsoncpp-dev"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-DBUILD_SHARED_LIBS=ON
-DBUILD_OBJECT_LIBS=OFF
-DJSONCPP_WITH_TESTS=OFF
-DCCACHE_FOUND=OFF
"

termux_step_post_get_source() {
	# Do not forget to bump revision of reverse dependencies and rebuild them
	# after SOVERSION is changed.
	local _SOVERSION=26

	local v=$(sed -En 's/^set\(PROJECT_SOVERSION\s+([0-9]+).*/\1/p' \
			CMakeLists.txt)
	if [ "${v}" != "${_SOVERSION}" ]; then
		termux_error_exit "SOVERSION guard check failed."
	fi
}

termux_step_pre_configure() {
	# Certain packages are not safe to build on device because their
	# build.sh script deletes specific files in $TERMUX_PREFIX.
	if $TERMUX_ON_DEVICE_BUILD; then
		termux_error_exit "Package '$TERMUX_PKG_NAME' is not safe for on-device builds."
	fi

	# The installation does not overwrite symlinks such as libjsoncpp.so.1,
	# so if rebuilding these are not detected as modified. Fix that:
	rm -f $TERMUX_PREFIX/lib/libjsoncpp.so*
}

# CMake's FindJsonCpp.cmake varies across projects/distros.
# Some expect headers under:
#   $PREFIX/include/json/json.h
# while others expect Debian-style:
#   $PREFIX/include/jsoncpp/json/json.h
#
# Provide a compatibility include tree so builds (notably cmake itself with
# -DCMAKE_USE_SYSTEM_JSONCPP=ON) can reliably locate JsonCpp headers.
termux_step_post_make_install() {
	local src_dir="$TERMUX_PREFIX/include/json"
	local compat_dir="$TERMUX_PREFIX/include/jsoncpp/json"

	if [ -d "$src_dir" ]; then
		# Some CMake find modules look specifically for json/features.h.
		# Newer jsoncpp installs json_features.h instead, so provide a compat symlink.
		if [ -f "$src_dir/json_features.h" ] && [ ! -e "$src_dir/features.h" ]; then
			ln -sf "json_features.h" "$src_dir/features.h"
		fi

		mkdir -p "$compat_dir"
		for header in "$src_dir"/*.h; do
			[ -e "$header" ] || continue
			ln -sf "../../json/$(basename "$header")" "$compat_dir/$(basename "$header")"
		done
	fi
}
