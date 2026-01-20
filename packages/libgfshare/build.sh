TERMUX_PKG_HOMEPAGE=https://github.com/kinnison/libgfshare
TERMUX_PKG_DESCRIPTION="Utilities for multi-way secret-sharing"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=2.0.0
TERMUX_PKG_REVISION=8
# Original upstream site (digital-scurf.org) is frequently unavailable.
# Use Debian's orig tarball mirror which tracks upstream releases.
TERMUX_PKG_SRCURL=http://deb.debian.org/debian/pool/main/libg/libgfshare/libgfshare_${TERMUX_PKG_VERSION}.orig.tar.gz
TERMUX_PKG_SHA256=04442efb602a5fc8d79604845816811ab2d970e07e9aa5c8962b86b88e284838
TERMUX_PKG_BREAKS="libgfshare-dev"
TERMUX_PKG_REPLACES="libgfshare-dev"

termux_step_post_configure() {
	gcc -DHAVE_CONFIG_H \
		-I. \
		-I"$TERMUX_PKG_SRCDIR" \
		-I"$TERMUX_PKG_SRCDIR"/include \
		"$TERMUX_PKG_SRCDIR"/src/gfshare_maketable.c \
		-o gfshare_maketable
	touch -d "next hour" gfshare_maketable
}
