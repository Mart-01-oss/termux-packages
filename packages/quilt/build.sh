TERMUX_PKG_HOMEPAGE=https://savannah.nongnu.org/projects/quilt
TERMUX_PKG_DESCRIPTION="Allows you to easily manage large numbers of patches"
TERMUX_PKG_LICENSE="GPL-2.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="0.69"
TERMUX_PKG_SRCURL=https://savannah.nongnu.org/download/quilt/quilt-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=96000cd9fe0ab4ade999b0be31c8ac53fffbd4f9f541241b5d324544545fa8d0
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_DEPENDS="coreutils, diffstat, gawk, graphviz, perl"
TERMUX_PKG_PLATFORM_INDEPENDENT=true
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
--with-diffstat=$TERMUX_PREFIX/bin/diffstat
--without-7z
--without-rpmbuild
--without-sendmail
"

termux_step_post_make_install() {
	ln -sf $TERMUX_PREFIX/bin/gawk $TERMUX_PREFIX/share/quilt/compat/awk
}
