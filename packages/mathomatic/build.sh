TERMUX_PKG_HOMEPAGE=https://en.wikipedia.org/wiki/Mathomatic
TERMUX_PKG_DESCRIPTION="Simple CAS and symbolic calculator"
TERMUX_PKG_LICENSE="LGPL-2.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=16.0.5
TERMUX_PKG_REVISION=7
TERMUX_PKG_SRCURL="https://www.mathomatic.org/mathomatic-${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=35a66f5cc47cfe55b71a49ba4ed424108212237799817f72ad547b77b9e6e577
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXTRA_MAKE_ARGS="READLINE=1"
TERMUX_PKG_DEPENDS="readline"
TERMUX_PKG_RM_AFTER_INSTALL="share/applications/mathomatic.desktop share/pixmaps"

termux_step_pre_configure() {
	rm $TERMUX_PKG_SRCDIR/CMakeLists.txt
	CPPFLAGS+=" -DUSE_TGAMMA -DBOLD_COLOR"
}
