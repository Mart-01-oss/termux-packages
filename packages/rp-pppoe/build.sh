TERMUX_PKG_HOMEPAGE=https://dianne.skoll.ca/projects/rp-pppoe/
TERMUX_PKG_DESCRIPTION="A PPP-over-Ethernet redirector for pppd"
TERMUX_PKG_LICENSE="GPL-2.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=4.0
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=https://dianne.skoll.ca/projects/rp-pppoe/download.php?file=rp-pppoe-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=b64f7e4d5d83e67b6769397cf05acb0fd9913b4edd8e5c5dfb27884e07c4b0e2
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
--disable-static
"

termux_step_pre_configure() {
	TERMUX_PKG_SRCDIR=$TERMUX_PKG_SRCDIR/src
	TERMUX_PKG_BUILDDIR=$TERMUX_PKG_SRCDIR
}
