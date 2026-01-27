TERMUX_PKG_HOMEPAGE=https://www.nongnu.org/icoutils/
TERMUX_PKG_DESCRIPTION="Extracts and converts images in MS Windows(R) icon and cursor files"
TERMUX_PKG_LICENSE="GPL-3.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=0.32.3
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=https://savannah.nongnu.org/download/icoutils/icoutils-$TERMUX_PKG_VERSION.tar.bz2
TERMUX_PKG_SHA256=ad3d792389750ceabf099fac99a5966393b1fc28f3270bf5ad789b5eaef25e03
TERMUX_PKG_DEPENDS="libpng, perl"

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
--mandir=$TERMUX_PREFIX/share/man
"
