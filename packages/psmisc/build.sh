TERMUX_PKG_HOMEPAGE=https://gitlab.com/psmisc/psmisc
TERMUX_PKG_DESCRIPTION="Some small useful utilities that use the proc filesystem"
TERMUX_PKG_LICENSE="GPL-2.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=23.7
TERMUX_PKG_REVISION=1
# Use the official release tarball which ships pre-generated ./configure.
# Git tag archives (e.g. GitLab) often omit autotools output, which breaks the build.
TERMUX_PKG_SRCURL=https://downloads.sourceforge.net/project/psmisc/psmisc/psmisc-${TERMUX_PKG_VERSION}.tar.xz
TERMUX_PKG_SHA256=58c55d9c1402474065adae669511c191de374b0871eec781239ab400b907c327
TERMUX_PKG_DEPENDS="ncurses"
TERMUX_PKG_ESSENTIAL=true
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_RM_AFTER_INSTALL="bin/pstree.x11"

termux_step_pre_configure() {
	# Only run autotools generation if upstream tarball didn't ship ./configure.
	# (Our preferred source tarball includes it, so this should normally be skipped.)
	if [ ! -f ./configure ]; then
		if [ -x ./autogen.sh ]; then
			./autogen.sh
		else
			autoreconf -fi
		fi
	fi
}
