TERMUX_PKG_HOMEPAGE="https://www.ode.org"
TERMUX_PKG_DESCRIPTION="An open source, high performance library for simulating rigid body dynamics"
TERMUX_PKG_GROUPS="science"
TERMUX_PKG_LICENSE="BSD 3-Clause, LGPL-2.1"
TERMUX_PKG_MAINTAINER="Pooya Moradi <pvonmoradi@gmail.com>"
TERMUX_PKG_VERSION="0.16.6"
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL="https://bitbucket.org/odedevs/ode/downloads/ode-$TERMUX_PKG_VERSION.tar.gz"
TERMUX_PKG_SHA256=c91a28c6ff2650284784a79c726a380d6afec87ecf7a35c32a6be0c5b74513e8
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_FORCE_CMAKE=true
TERMUX_PKG_DEPENDS="libc++, libccd"
# NOTE: ODE exports a CMake target (ODE::ODE). When CMAKE_INSTALL_INCLUDEDIR is absolute,
# some upstream config templates build include dirs as ${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_INCLUDEDIR},
# producing a duplicated prefix like: /data/.../usr//data/.../usr/include.
# We force relative install dirs (lib/include) to keep exported targets valid.
TERMUX_PKG_EXTRA_CONFIGURE_ARGS='
-DBUILD_SHARED_LIBS=ON
-DCMAKE_POLICY_VERSION_MINIMUM=3.5
-DCMAKE_INSTALL_LIBDIR=lib
-DCMAKE_INSTALL_INCLUDEDIR=include
-DODE_WITH_DEMOS=OFF
-DODE_WITH_TESTS=OFF
-DODE_WITH_LIBCCD=ON
-DODE_WITH_LIBCCD_SYSTEM=ON
'

termux_step_pre_configure() {
	# Use double-precision for 64-bit archs, otherwise use single-precision
	case "$TERMUX_ARCH" in
		"aarch64" |  "x86_64")
			TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=' -DODE_DOUBLE_PRECISION=ON'
			;;
		"arm" | "i686")
			TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=' -DODE_DOUBLE_PRECISION=OFF'
			;;
		*)
			TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=' -DODE_DOUBLE_PRECISION=OFF'
			;;
	esac
}
