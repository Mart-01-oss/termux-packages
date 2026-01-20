TERMUX_PKG_HOMEPAGE=https://www.tcpdump.org
TERMUX_PKG_DESCRIPTION="Library for network traffic capture"
TERMUX_PKG_LICENSE="BSD 3-Clause"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=1.10.5
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=https://www.tcpdump.org/release/libpcap-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=37ced90a19a302a7f32e458224a00c365c117905c2cd35ac544b6880a81488f0
TERMUX_PKG_BREAKS="libpcap-dev"
TERMUX_PKG_REPLACES="libpcap-dev"
TERMUX_PKG_BUILD_IN_SRC=true

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="--with-pcap=linux --without-libnl"
TERMUX_PKG_RM_AFTER_INSTALL="bin/pcap-config share/man/man1/pcap-config.1"
