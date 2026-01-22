TERMUX_PKG_HOMEPAGE=https://www.freedesktop.org/wiki/Software/HarfBuzz/
TERMUX_PKG_DESCRIPTION="OpenType text shaping engine"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="11.5.1"
TERMUX_PKG_SRCURL=https://github.com/harfbuzz/harfbuzz/archive/refs/tags/${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=624ddaa8211a57b538360555f7358dac9fa7a9e6000b65de06a91dbb392882ca
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_DEPENDS="freetype, glib, libcairo, libgraphite"
TERMUX_PKG_BUILD_DEPENDS="glib-cross"
TERMUX_PKG_BREAKS="harfbuzz-dev"
TERMUX_PKG_REPLACES="harfbuzz-dev"

# NOTE: Introspection and some optional deps (e.g. graphite2) often cause CI
# failures in cross builds when the corresponding .pc files are not available.
# Keep the build reproducible by disabling them.
TERMUX_PKG_DISABLE_GIR=true
TERMUX_PKG_VERSIONED_GIR=false

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-Dcpp_std=c++17
-Ddocs=disabled
-Dgobject=enabled
-Dgraphite=disabled
-Dgraphite2=disabled
-Dintrospection=disabled
-Dtests=disabled
"
TERMUX_PKG_RM_AFTER_INSTALL="
share/gtk-doc
"

termux_step_post_get_source() {
	mv CMakeLists.txt CMakeLists.txt.unused

	# Do not forget to bump revision of reverse dependencies and rebuild them
	# after SOVERSION is changed.
	local _SOVERSION=0

	local e=$(grep -oP "hb_so_version = '\K\d+" src/meson.build | uniq)
	if [ ! "${e}" ] || [ "${_SOVERSION}" != "${e}" ]; then
		termux_error_exit "SOVERSION guard check failed."
	fi
}

termux_step_pre_configure() {
	termux_setup_glib_cross_pkg_config_wrapper
}

termux_step_post_make_install() {
	install -Dm600 "$TERMUX_PKG_BUILDER_DIR"/hb-info.1 "$TERMUX_PREFIX"/share/man/man1/hb-info.1
	install -Dm600 "$TERMUX_PKG_BUILDER_DIR"/hb-shape.1 "$TERMUX_PREFIX"/share/man/man1/hb-shape.1
	install -Dm600 "$TERMUX_PKG_BUILDER_DIR"/hb-subset.1 "$TERMUX_PREFIX"/share/man/man1/hb-subset.1
	install -Dm600 "$TERMUX_PKG_BUILDER_DIR"/hb-view.1 "$TERMUX_PREFIX"/share/man/man1/hb-view.1
}
