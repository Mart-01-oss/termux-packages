TERMUX_PKG_HOMEPAGE=https://en.wikipedia.org/wiki/Mathomatic
TERMUX_PKG_DESCRIPTION="Simple CAS and symbolic calculator"
TERMUX_PKG_LICENSE="LGPL-2.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=16.0.5
TERMUX_PKG_REVISION=7
# Upstream site redirects this URL to an HTML page (Cloudflare), which breaks
# non-interactive builds. Use a stable mirror instead.
TERMUX_PKG_SRCURL="http://download.openpkg.org/components/cache/mathomatic/mathomatic-${TERMUX_PKG_VERSION}.tar.bz2"
TERMUX_PKG_SHA256=976e6fed1014586bcd584e417c074fa86e4ca6a0fcc2950254da2efde99084ca
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXTRA_MAKE_ARGS="READLINE=1"
TERMUX_PKG_DEPENDS="readline"
TERMUX_PKG_RM_AFTER_INSTALL="share/applications/mathomatic.desktop share/pixmaps"

termux_step_pre_configure() {
	rm $TERMUX_PKG_SRCDIR/CMakeLists.txt
	CPPFLAGS+=" -DUSE_TGAMMA -DBOLD_COLOR"
}
