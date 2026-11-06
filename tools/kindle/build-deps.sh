#!/usr/bin/env bash
# Cross-builds the client's dependencies as static libraries for one
# koxtoolchain target. Only glibc stays dynamic: the toolchain targets the
# device's glibc, and a static glibc cannot resolve DNS reliably.
#
# Usage: build-deps.sh <target-triplet> <prefix>
set -euo pipefail

TC=$1
PREFIX=$2
WORK=$(mktemp -d)
JOBS=$(nproc)

fetch() { # url sha256 -> extracted directory in $WORK
  local name
  name=$(basename "$1")
  curl -fsSL --retry 3 -o "$WORK/$name" "$1"
  echo "$2  $WORK/$name" | sha256sum -c -
  tar -xf "$WORK/$name" -C "$WORK"
}

mkdir -p "$PREFIX"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export CC="$TC-gcc" AR="$TC-gcc-ar" RANLIB="$TC-gcc-ranlib" STRIP="$TC-strip"
export CFLAGS="-O2 -ffunction-sections -fdata-sections"

fetch https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz \
  bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
(cd "$WORK/zlib-1.3.2" && CHOST="$TC" ./configure --static --prefix="$PREFIX" \
  && make -j"$JOBS" install)

fetch https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz \
  603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
(cd "$WORK/openssl-3.5.9" && env -u CC -u AR -u RANLIB ./Configure linux-armv4 \
  --cross-compile-prefix="$TC-" --prefix="$PREFIX" --libdir=lib \
  no-shared no-tests no-apps no-docs no-module no-dso no-engine no-quic \
  && make -j"$JOBS" build_libs && make install_dev)

fetch https://github.com/curl/curl/releases/download/curl-8_23_0/curl-8.23.0.tar.xz \
  8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
(cd "$WORK/curl-8.23.0" && ./configure --host="$TC" --prefix="$PREFIX" \
  --disable-shared --enable-static --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
  --without-ca-bundle --without-ca-path --without-libpsl --without-nghttp2 \
  --without-brotli --without-zstd --without-libidn2 --disable-ldap --disable-manual \
  --disable-docs --disable-dict --disable-file --disable-ftp --disable-gopher \
  --disable-imap --disable-mqtt --disable-pop3 --disable-rtsp --disable-smb \
  --disable-smtp --disable-telnet --disable-tftp --disable-ws \
  && make -j"$JOBS" -C lib && make -C lib install && make install-pkgconfigDATA \
  && make -C include install)

fetch https://github.com/DaveGamble/cJSON/archive/refs/tags/v1.7.19.tar.gz \
  7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562
cmake -S "$WORK/cJSON-1.7.19" -B "$WORK/cjson-build" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$(command -v "$AR")" -DCMAKE_RANLIB="$(command -v "$RANLIB")" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_CJSON_TEST=OFF -DENABLE_CUSTOM_COMPILER_FLAGS=OFF
cmake --build "$WORK/cjson-build" -j"$JOBS" --target install

fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz \
  36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
(cd "$WORK/freetype-2.14.3" && ./configure --host="$TC" --prefix="$PREFIX" \
  --disable-shared --enable-static --with-zlib=no --with-bzip2=no --with-png=no \
  --with-harfbuzz=no --with-brotli=no && make -j"$JOBS" install)

# FBInk v1.25.0, with only the raw image path: all text comes from our renderer.
git clone --quiet --recurse-submodules --shallow-submodules --depth 1 --branch v1.25.0 \
  https://github.com/NiLuJe/FBInk.git "$WORK/FBInk"
test "$(git -C "$WORK/FBInk" rev-parse HEAD)" = f562bc15a606524694a6d885bed5d83d03c7eb23
(cd "$WORK/FBInk" && env -u CC -u AR -u RANLIB -u STRIP -u CFLAGS make -j"$JOBS" \
  CROSS_TC="$TC" KINDLE=true MINIMAL=true IMAGE=true staticlib)
install -m 644 "$WORK/FBInk/Release/libfbink.a" "$PREFIX/lib/"
install -m 644 "$WORK/FBInk/fbink.h" "$PREFIX/include/"
cat > "$PREFIX/lib/pkgconfig/fbink.pc" <<PC
Name: fbink
Description: FrameBuffer eInker
Version: 1.25.0
Cflags: -I$PREFIX/include
Libs: -L$PREFIX/lib -lfbink -lm
PC

rm -rf "$WORK"
