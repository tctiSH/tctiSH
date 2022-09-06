#!/bin/bash

brew install libslirp

export CFLAGS=""
export LDFLAGS=""

mkdir -p ../qemu-tcti/build_mac
pushd ../qemu-tcti/build_mac

	# Set things up to build QEMU...
	../configure \
		--disable-linux-user \
		--disable-bsd-user \
		--disable-guest-agent \
		--enable-libssh \
		--enable-virtfs \
		--enable-slirp=system \
		--extra-cflags=-DNCURSES_WIDECHAR=1 \
		--disable-sdl \
		--disable-gtk \
		--smbd=/opt/homebrew/sbin/samba-dot-org-smbd \
		--target-list=x86_64-softmmu

	# ... and build QEMU.
	ninja qemu-img qemu-system-x86_64
popd
