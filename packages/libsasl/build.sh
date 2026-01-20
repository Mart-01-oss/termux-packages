TERMUX_PKG_HOMEPAGE=https://www.cyrusimap.org/sasl/
TERMUX_PKG_DESCRIPTION="Cyrus SASL - authentication abstraction library"
TERMUX_PKG_LICENSE="BSD"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=2.1.28
TERMUX_PKG_REVISION=2
TERMUX_PKG_SRCURL=https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-${TERMUX_PKG_VERSION}/cyrus-sasl-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=7ccfc6abd01ed67c1a0924b353e526f1b766b21f42d4562ee635a8ebfc5bb38c
TERMUX_PKG_BREAKS="libsasl-dev"
TERMUX_PKG_REPLACES="libsasl-dev"
# Seems to be race issues in build (symlink creation)::
TERMUX_PKG_MAKE_PROCESSES=1
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
lt_cv_deplibs_check_method=pass_all
ac_cv_func_syslog=no
ac_cv_header_syslog_h=no
--disable-gssapi
--disable-otp
--sysconfdir=$TERMUX_PREFIX/etc
--with-dblib=none
--with-dbpath=$TERMUX_PREFIX/var/lib/sasldb
--without-des
--without-saslauthd
--with-plugindir=$TERMUX_PREFIX/lib/sasl2
--enable-login
"
TERMUX_PKG_RM_AFTER_INSTALL="bin/pluginviewer"

termux_step_pre_configure() {
	autoreconf -fi
}

termux_step_post_massage() {
	for sub in anonymous crammd5 digestmd5 plain login; do
		local base=lib/sasl2/lib${sub}
		if [ ! -f ${base}.so ]; then
			termux_error_exit "libsasl not packaged with $base"
		fi
	done
}
