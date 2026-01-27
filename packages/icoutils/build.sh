TERMUX_PKG_HOMEPAGE=https://www.nongnu.org/icoutils/
TERMUX_PKG_DESCRIPTION="Extracts and converts images in MS Windows(R) icon and cursor files"
TERMUX_PKG_LICENSE="GPL-3.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=0.32.3
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=https://savannah.nongnu.org/download/icoutils/icoutils-$TERMUX_PKG_VERSION.tar.bz2
TERMUX_PKG_SHA256=cf39d4b01eba02ba5856d40ca520e2f53f650e05006207eef72aace2dddddcfc
TERMUX_PKG_DEPENDS="libpng, perl"

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
--mandir=$TERMUX_PREFIX/share/man
"
