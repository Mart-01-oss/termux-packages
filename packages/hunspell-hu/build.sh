TERMUX_PKG_HOMEPAGE=https://magyarispell.sourceforge.net/
TERMUX_PKG_DESCRIPTION="Hungarian dictionary for hunspell"
TERMUX_PKG_LICENSE="MPL-2.0, LGPL-3.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=2024.03.28
TERMUX_PKG_AUTO_UPDATE=false
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_PLATFORM_INDEPENDENT=true

termux_step_post_get_source() {
	termux_download https://cgit.freedesktop.org/libreoffice/dictionaries/plain/hu_HU/README_hu_HU.txt \
			$TERMUX_PKG_SRCDIR/README_hu_HU.txt \
			52b17fc3d53b6935eab747a71894507d702f7f0fde379c819c16cc803005fc84
}

termux_step_make_install() {
	mkdir -p $TERMUX_PREFIX/share/hunspell/
	# On checksum mismatch the files may have been updated:
	#  https://cgit.freedesktop.org/libreoffice/dictionaries/log/hu_HU/hu_HU.aff
	#  https://cgit.freedesktop.org/libreoffice/dictionaries/log/hu_HU/hu_HU.dic
	# In which case we need to bump version and checksum used.
	termux_download https://cgit.freedesktop.org/libreoffice/dictionaries/plain/hu_HU/hu_HU.aff \
			$TERMUX_PREFIX/share/hunspell/hu_HU.aff \
			f3a2748dd535cfde2142ab17d0f7f8e4787b03fb25a60829c69ac8d493db4802
	termux_download https://cgit.freedesktop.org/libreoffice/dictionaries/plain/hu_HU/hu_HU.dic \
			$TERMUX_PREFIX/share/hunspell/hu_HU.dic \
			2ec787f2992a8affe82a9aa912a0a881b21dfa6a61dc8a35aa160e5e41565bda
	touch $TERMUX_PREFIX/share/hunspell/hu_HU.{aff,dic}

	install -Dm600 -t $TERMUX_PREFIX/share/doc/$TERMUX_PKG_NAME \
		$TERMUX_PKG_SRCDIR/README_hu_HU.txt
}
