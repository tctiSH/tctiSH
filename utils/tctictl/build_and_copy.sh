#!/bin/bash
#
# Builds the utility, and copies the result into our ramdisk.
#

set +e

TARGET="x86_64-unknown-linux-musl"

cargo build --release --target=$TARGET
cp ./target/x86_64-unknown-linux-musl/release/tctictl ../../assets/ramdisk/bin

pushd ../../assets
	./make_ramdisk.sh
popd
