#!/usr/bin/env bash
#
# Builds libssh2 and the OpenSSL it needs for iOS, from source.
#
# The app reaches the guest's shell over SSH through SwiftSH, which used to ship
# a prebuilt libssh2 1.8.0 from 2016 inside its pod. That version speaks only
# SHA-1 key exchange (diffie-hellman-group14-sha1 and older) and only ssh-rsa and
# ssh-dss host keys. The dropbear in the 2026 guest image offers none of those:
# its key exchange is curve25519, ECDH and group14-sha256, and its host keys are
# ed25519, ECDSA and rsa-sha2-256. With no algorithm in common, every connection
# ended before authentication -- dropbear logged "No matching algo kex" and
# libssh2 reported it to the app as `authenticationFailed`, which is how it
# first looked like a password problem.
#
# Produces, in build-libssh2/out, the layout SwiftSH's podspec points at:
#
#     libssh2.a libssl.a libcrypto.a
#     libssh2/libssh2.h libssh2/libssh2_sftp.h libssh2/libssh2_publickey.h
#     module.modulemap
#
# Needs Xcode's iOS SDK and nothing from the devshell, but runs fine inside it:
#
#     ./build_libssh2.sh
#
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The versions we build, and what their tarballs must hash to. Bumping a version
# is these two lines and nothing else.
#
# OpenSSL is the 3.5 series because it is the LTS line, supported to April 2030.
# Its hash is the one OpenSSL publishes beside the release. libssh2 publishes a
# signature rather than a hash; this one is from a tarball whose signature
# verified against Daniel Stenberg's release key (27ED EAF2 2F3A BCEB 50DB 9A12
# 5CC9 08FD B71E 12C2), and which was byte-identical from libssh2.org and from
# the GitHub release.
OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"

LIBSSH2_VERSION="1.11.1"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
LIBSSH2_URL="https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz"

# Must track IPHONEOS_DEPLOYMENT_TARGET in tctiSH.xcodeproj, as in
# build_dependencies.sh. A library built for a newer iOS than the framework
# linking it produces a linker warning per object and a real risk of a symbol
# that is not there at runtime.
IOS_SDKMINVER="18.0"

BUILD_DIR="$BASEDIR/build-libssh2"
DOWNLOAD_DIR="$BUILD_DIR/downloads"
SOURCE_DIR="$BUILD_DIR/source"
PREFIX="$BUILD_DIR/prefix"
OUTPUT_DIR="$BUILD_DIR/out"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

die() {
    echo -e "${RED}$*${NC}" >&2
    exit 1
}

note() {
    echo -e "${GREEN}$*${NC}"
}

check_env() {
    command -v xcrun >/dev/null 2>&1 || die "'xcrun' not found; the iOS SDK cannot be located."
    command -v perl >/dev/null 2>&1 || die "'perl' not found; OpenSSL's Configure is a perl script."
    command -v curl >/dev/null 2>&1 || die "'curl' not found."
}

# Downloads a tarball once, and refuses it if it does not hash to what we pinned.
#
# Checked on every run rather than only after downloading, so that a cached file
# that has been truncated or swapped is caught too.
fetch() {
    local url="$1" sha256="$2"
    local file
    file="$DOWNLOAD_DIR/$(basename "$url")"

    mkdir -p "$DOWNLOAD_DIR"
    if [ ! -f "$file" ]; then
        echo "  downloading $(basename "$url")"
        curl -fsSL -o "$file.partial" "$url"
        mv "$file.partial" "$file"
    fi

    local actual
    actual="$(shasum -a 256 "$file" | cut -d ' ' -f 1)"
    if [ "$actual" != "$sha256" ]; then
        die "$(basename "$file") hashes to $actual, expected $sha256. Delete it to re-download."
    fi
}

# Unpacks fresh every time. Both builds write into their source trees, and a tree
# left over from an interrupted run is exactly the half-configured state that
# fails in confusing ways.
unpack() {
    local tarball="$1"
    local name
    name="$(basename "$tarball" .tar.gz)"

    rm -rf "${SOURCE_DIR:?}/$name"
    mkdir -p "$SOURCE_DIR"
    tar -xzf "$tarball" -C "$SOURCE_DIR"
    echo "$SOURCE_DIR/$name"
}

check_env

# The devshell exports this, and clang lets it override -mios-version-min, so
# leaving it set would quietly build for macOS 14 instead of iOS.
unset MACOSX_DEPLOYMENT_TARGET

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
TARGET_FLAGS="-arch arm64 -isysroot $SDK_PATH -mios-version-min=$IOS_SDKMINVER"

# Xcode's archiver rather than whatever is first on $PATH. Inside the devshell
# that is not Apple's, and an archive index written by a different ranlib is a
# thing Xcode's linker is entitled to disagree with.
AR="$(xcrun --sdk iphoneos --find ar)"
RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
export AR RANLIB

NCPU="$(sysctl -n hw.ncpu)"

note "Fetching sources..."
fetch "$OPENSSL_URL" "$OPENSSL_SHA256"
fetch "$LIBSSH2_URL" "$LIBSSH2_SHA256"

rm -rf "$PREFIX"

note "Building OpenSSL $OPENSSL_VERSION for iOS arm64..."
openssl_src="$(unpack "$DOWNLOAD_DIR/openssl-$OPENSSL_VERSION.tar.gz")"
(
    cd "$openssl_src"

    # ios64-xcrun is OpenSSL's own iOS arm64 target. It expects to find the
    # SDK by running the compiler through `xcrun -sdk iphoneos`, which setting
    # CC to Xcode's clang directly bypasses -- hence the explicit -isysroot,
    # without which the first #include <stdio.h> fails.
    #
    # Only libcrypto and libssl are wanted -- no command-line tool, no tests, no
    # docs, and no loadable modules, which iOS would not let a static library
    # load anyway.
    CC="$CLANG" ./Configure ios64-xcrun \
        --prefix="$PREFIX" \
        --libdir=lib \
        -isysroot "$SDK_PATH" \
        "-mios-version-min=$IOS_SDKMINVER" \
        no-shared no-module no-dso no-engine \
        no-apps no-tests no-docs

    make -j"$NCPU" build_libs
    make install_dev
)

note "Building libssh2 $LIBSSH2_VERSION for iOS arm64..."
libssh2_src="$(unpack "$DOWNLOAD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz")"
(
    cd "$libssh2_src"

    # No zlib: SwiftSH never asks for compression, and the guest is on the
    # other end of a loopback socket where compressing would only cost CPU.
    CC="$CLANG" CFLAGS="$TARGET_FLAGS -O2" LDFLAGS="$TARGET_FLAGS" \
        ./configure \
        --host=aarch64-apple-darwin \
        --prefix="$PREFIX" \
        --disable-shared \
        --enable-static \
        --with-crypto=openssl \
        --with-libssl-prefix="$PREFIX" \
        --without-libz \
        --disable-examples-build \
        --disable-docker-tests \
        --disable-sshd-tests

    # Only src/: the headers are plain files with no install rule of their own,
    # and are taken from the source tree below.
    make -j"$NCPU" -C src
    make -C src install
)

# The point of the exercise, checked against the library rather than assumed
# from the version number. These are the algorithms dropbear offers that 1.8.0
# lacked, and libssh2 compiles the curve25519 and ed25519 ones in only when the
# OpenSSL it was built against provides them -- so a build that linked the
# wrong OpenSSL would pass on version and fail here.
library_strings="$(strings "$PREFIX/lib/libssh2.a")"
for algorithm in curve25519-sha256 diffie-hellman-group14-sha256 ssh-ed25519 rsa-sha2-256; do
    if ! grep -qx "$algorithm" <<<"$library_strings"; then
        die "libssh2.a does not offer $algorithm, which the guest's dropbear needs."
    fi
done

# And that it is for the device. An archive built for macOS links into an iOS
# target with no more than a warning, and then fails at launch.
#
# otool's output is captured before awk reads it, for the reason build_idevice.sh
# gives at length: awk exits at the first match, otool dies of SIGPIPE, and
# pipefail reports that as failure -- so a pipe fails exactly when it finds what
# it was looking for, and set -e ends the script without a word. It did.
for library in libssh2.a libssl.a libcrypto.a; do
    load_commands="$(otool -l "$PREFIX/lib/$library")"
    platform="$(awk '/LC_BUILD_VERSION/ { found = 1 } found && /platform/ { print $2; exit }' <<<"$load_commands")"
    [ "$platform" = "2" ] || [ "$platform" = "IOS" ] ||
        die "$library is built for platform '$platform', not iOS."
done

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/libssh2"
cp "$PREFIX/lib/libssh2.a" "$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a" "$OUTPUT_DIR/"
cp "$libssh2_src/include/libssh2.h" "$libssh2_src/include/libssh2_sftp.h" \
    "$libssh2_src/include/libssh2_publickey.h" "$OUTPUT_DIR/libssh2/"

# The same module SwiftSH's prebuilt copy declared, so that its `import Libssh2`
# and `@import Libssh2` resolve unchanged. The link lines are what pull the three
# archives into SwiftSH.framework without anyone naming them to the linker.
cat >"$OUTPUT_DIR/module.modulemap" <<'MODULEMAP'
module Libssh2 {
    header "libssh2/libssh2.h"
    header "libssh2/libssh2_sftp.h"
    header "libssh2/libssh2_publickey.h"

    link "ssl"
    link "crypto"
    link "ssh2"

    export *
}
MODULEMAP

printf 'openssl %s\nlibssh2 %s\n' "$OPENSSL_VERSION" "$LIBSSH2_VERSION" >"$OUTPUT_DIR/VERSION"

note "Built $OUTPUT_DIR"
echo "  $(du -h "$OUTPUT_DIR/libssh2.a" | cut -f1) libssh2, $(du -h "$OUTPUT_DIR/libssl.a" | cut -f1) libssl, $(du -h "$OUTPUT_DIR/libcrypto.a" | cut -f1) libcrypto"
