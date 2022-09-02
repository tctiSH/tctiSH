#!/bin/bash

brew install libslirp

pushd ../qemu-tcti
	# Set things up to build TCTI...
	./configure \
		--disable-linux-user \
		--disable-bsd-user \
		--disable-guest-agent \
		--enable-libssh \
		--enable-slirp=system \
		--extra-cflags=-DNCURSES_WIDECHAR=1 \
		--disable-sdl \
		--disable-gtk \
		--smbd=/opt/homebrew/sbin/samba-dot-org-smbd \
		--target-list=x86_64-softmmu \
		--enable-tcg-tcti \
		--enable-shared-lib \

	# Build our support packages; TCTI itself will be automatically built below.
	pushd build
		ninja qemu-img
	popd
popd
