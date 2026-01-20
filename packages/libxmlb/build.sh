TERMUX_PKG_HOMEPAGE="https://github.com/hughsie/libxmlb"
TERMUX_PKG_DESCRIPTION="Library to help create and query binary XML blobs"
TERMUX_PKG_LICENSE="LGPL-2.1"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="0.3.24"
TERMUX_PKG_SRCURL=https://github.com/hughsie/libxmlb/releases/download/${TERMUX_PKG_VERSION}/libxmlb-${TERMUX_PKG_VERSION}.tar.xz
TERMUX_PKG_SHA256=ded52667aac942bb1ff4d1e977e8274a9432d99033d86918feb82ade82b8e001
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_DEPENDS="glib, liblzma, libstemmer, zstd"
# libxmlb enables GObject Introspection in TERMUX_PKG_EXTRA_CONFIGURE_ARGS,
# so we need the gobject-introspection pkg-config files available at build time.
# Meson may also try CMake as a fallback for some deps.
TERMUX_PKG_BUILD_DEPENDS="cmake, g-ir-scanner, glib-cross, gobject-introspection"
TERMUX_PKG_VERSIONED_GIR=false
TERMUX_PKG_DISABLE_GIR=false
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-Dgtkdoc=false
-Dintrospection=true
-Dstemmer=true
-Dtests=false
"

termux_step_pre_configure() {
	termux_setup_gir
}
