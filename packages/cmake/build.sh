TERMUX_PKG_HOMEPAGE=https://cmake.org/
TERMUX_PKG_DESCRIPTION="Family of tools designed to build, test and package software"
TERMUX_PKG_LICENSE="BSD 3-Clause"
TERMUX_PKG_LICENSE_FILE="LICENSE.rst"
TERMUX_PKG_MAINTAINER="@termux"
# When updating version here, please update termux_setup_cmake.sh as well.
TERMUX_PKG_VERSION="4.2.2"
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=https://www.cmake.org/files/v${TERMUX_PKG_VERSION:0:3}/cmake-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=bbda94dd31636e89eb1cc18f8355f6b01d9193d7676549fba282057e8b730f58
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_DEPENDS="libarchive, libc++, libcurl, libexpat, jsoncpp, libuv, rhash, zlib"
TERMUX_PKG_RECOMMENDS="clang, make"
TERMUX_PKG_FORCE_CMAKE=true
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
# Ensure CMake searches Termux prefix first (avoid picking host /usr/include/json).
-DCMAKE_PREFIX_PATH=${TERMUX_PREFIX}
-DCMAKE_INCLUDE_PATH=${TERMUX_PREFIX}/include/uv
-DCMAKE_LIBRARY_PATH=${TERMUX_PREFIX}/lib
-DSPHINX_MAN=ON
-DCMAKE_MAN_DIR=share/man
-DCMAKE_DOC_DIR=share/doc/cmake
-DCMAKE_USE_SYSTEM_CURL=ON
-DCMAKE_USE_SYSTEM_EXPAT=ON
-DCMAKE_USE_SYSTEM_FORM=ON
-DCMAKE_USE_SYSTEM_JSONCPP=ON
# Help CMake's FindJsonCpp.cmake locate Termux-installed jsoncpp.
# jsoncpp installs headers as $PREFIX/include/json/*.h (e.g. <json/json.h>),
# so the include dir must be $PREFIX/include (not $PREFIX/include/json).
# CMake's built-in FindJsonCpp.cmake expects JsonCpp_INCLUDE_DIR to be the
# directory that contains json/json.h (so it can also read json/version.h).
-DJsonCpp_INCLUDE_DIR=${TERMUX_PREFIX}/include
-DJsonCpp_LIBRARY=${TERMUX_PREFIX}/lib/libjsoncpp.so
# Some FindJsonCpp variants use JSONCPP_* variables.
-DJSONCPP_INCLUDE_DIR=${TERMUX_PREFIX}/include
-DJSONCPP_LIBRARY=${TERMUX_PREFIX}/lib/libjsoncpp.so
-DCMAKE_USE_SYSTEM_LIBARCHIVE=ON
-DCMAKE_USE_SYSTEM_LIBRHASH=ON
# Help CMake's FindLibRHash.cmake locate Termux-installed librhash.
# RHash installs headers under $PREFIX/include/librhash/.
-DLibRHash_INCLUDE_DIR=${TERMUX_PREFIX}/include/librhash
-DLibRHash_LIBRARY=${TERMUX_PREFIX}/lib/librhash.so
-DCMAKE_USE_SYSTEM_LIBUV=ON
# Help CMake's FindLibUV.cmake locate Termux-installed libuv.
-DLibUV_INCLUDE_DIR=${TERMUX_PREFIX}/include
-DLibUV_LIBRARY=${TERMUX_PREFIX}/lib/libuv.so
-DLibUV_VERSION=1.51.0-1
-DCMAKE_USE_SYSTEM_ZLIB=ON
-DBUILD_CursesDialog=ON"

termux_step_pre_configure() {
	# CMake's own build uses find_package(LibUV <minver>) in
	# Source/Modules/CMakeBuildUtilities.cmake. That relies on FindLibUV.cmake
	# extracting a version from headers.
	#
	# On some environments we observed FindLibUV failing to extract the version
	# even when libuv is correctly installed, which makes the build fail with:
	#   CMAKE_USE_SYSTEM_LIBUV is ON but a libuv is not found!
	#
	# Pre-seed LibUV_VERSION from Termux-installed headers so the find module has
	# a reliable version value.
	local _uv_version_h="${TERMUX_PREFIX}/include/uv/version.h"
	if [ -f "${_uv_version_h}" ]; then
		local _uv_major _uv_minor _uv_patch
		_uv_major=$(grep -m1 -E '^#define[[:space:]]+UV_VERSION_MAJOR[[:space:]]+' "${_uv_version_h}" | awk '{print $3}')
		_uv_minor=$(grep -m1 -E '^#define[[:space:]]+UV_VERSION_MINOR[[:space:]]+' "${_uv_version_h}" | awk '{print $3}')
		_uv_patch=$(grep -m1 -E '^#define[[:space:]]+UV_VERSION_PATCH[[:space:]]+' "${_uv_version_h}" | awk '{print $3}')
		if [ -n "${_uv_major}" ] && [ -n "${_uv_minor}" ] && [ -n "${_uv_patch}" ]; then
			TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=" -DLibUV_VERSION=${_uv_major}.${_uv_minor}.${_uv_patch}"
		fi
	fi
}

termux_pkg_auto_update() {
	local TERMUX_SETUP_CMAKE="${TERMUX_SCRIPTDIR}/scripts/build/setup/termux_setup_cmake.sh"
	local TERMUX_REPOLOGY_DATA_FILE=$(mktemp)
	python3 "${TERMUX_SCRIPTDIR}"/scripts/updates/api/dump-repology-data \
		"${TERMUX_REPOLOGY_DATA_FILE}" "${TERMUX_PKG_NAME}" >/dev/null || \
		echo "{}" > "${TERMUX_REPOLOGY_DATA_FILE}"
	local latest_version=$(jq -r --arg packageName "${TERMUX_PKG_NAME}" '.[$packageName]' < "${TERMUX_REPOLOGY_DATA_FILE}")
	if [[ "${latest_version}" == "null" ]]; then
		latest_version="${TERMUX_PKG_VERSION}"
	fi
	if [[ "${latest_version}" == "${TERMUX_PKG_VERSION}" ]]; then
		echo "INFO: No update needed. Already at version '${TERMUX_PKG_VERSION}'."
		rm -f "${TERMUX_REPOLOGY_DATA_FILE}"
		return
	fi
	rm -f "${TERMUX_REPOLOGY_DATA_FILE}"

	local TERMUX_CMAKE_TARNAME="cmake-${latest_version}-linux-x86_64.tar.gz"
	local TERMUX_CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${latest_version}/${TERMUX_CMAKE_TARNAME}"
	local TERMUX_CMAKE_TARFILE=$(mktemp)
	curl -Ls "${TERMUX_CMAKE_URL}" -o "${TERMUX_CMAKE_TARFILE}"
	local TERMUX_CMAKE_SHA256=$(sha256sum "${TERMUX_CMAKE_TARFILE}" | cut -d" " -f1)
	sed \
		-e "s|local TERMUX_CMAKE_VERSION=.*|local TERMUX_CMAKE_VERSION=${latest_version}|" \
		-e "s|local TERMUX_CMAKE_SHA256=.*|local TERMUX_CMAKE_SHA256=${TERMUX_CMAKE_SHA256}|" \
		-i "${TERMUX_SETUP_CMAKE}"
	rm -f "${TERMUX_CMAKE_TARFILE}"

	termux_pkg_upgrade_version "${latest_version}"
}
