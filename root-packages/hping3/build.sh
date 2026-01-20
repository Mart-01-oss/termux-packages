TERMUX_PKG_HOMEPAGE=http://www.hping.org/
TERMUX_PKG_DESCRIPTION="hping is a command-line oriented TCP/IP packet assembler/analyzer."
# Same versioning as archlinux:
TERMUX_PKG_LICENSE="GPL-2.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=3.0.0
TERMUX_PKG_REVISION=4
# Original upstream site (hping.org) is often unavailable.
# Use Debian orig tarball mirror.
TERMUX_PKG_SRCURL=https://deb.debian.org/debian/pool/main/h/hping3/hping3_3.a2.ds2.orig.tar.gz
TERMUX_PKG_SHA256=be027ed1bc1ebebd2a91c48936493024c3895e789c8490830e273ee7fe6fc09d
TERMUX_PKG_DEPENDS="libandroid-shmem, libpcap, tcl"
TERMUX_PKG_BUILD_IN_SRC=true

termux_step_post_configure () {
	LDFLAGS+=" -Wl,-z,muldefs"
	export LDFLAGS+=" -landroid-shmem"
	mkdir -p ${TERMUX_PREFIX}/share/man/man8
}
