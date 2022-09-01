#!/bin/bash

# The architecture of we're targeting with QEMU.
TCTI_ARCH="x86_64"

# The size of the image used to emulate iOS storage.
STANDIN_IMAGE_SIZE="10G"

# If we have a ramdisk directory, use it to create a ramdisk for TCTI.
if [ -d ramdisk ]; then
	pushd ramdisk
		find . | cpio -o -c -H newc | gzip -9 > ../initrd.img 2> /dev/null
	popd
fi

# If we don't have a TCTI install, create one.
if [ ! -f ../qemu-tcti/build/qemu-system-${TCTI_ARCH} ]; then
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

		# Build our support packages; TCTI itself will be automatically built below.
		pushd build
			ninja qemu-img
		popd
	popd
fi

# Make sure our TCTI build is up to date.
pushd ../qemu-tcti/build
	ninja qemu-system-${TCTI_ARCH}
popd

# If we don't have a stand-in for our iOS user storage, create one.
if [ ! -f user_union_standin.qcow ]; then
	../qemu-tcti/build/qemu-img create -f qcow2 user_union_standin.qcow ${STANDIN_IMAGE_SIZE}
fi

# Run TCTI.
../qemu-tcti/build/qemu-system-${TCTI_ARCH} \
	-display none \
	-kernel bzImage \
	-initrd initrd.img \
	-m 4G \
	-device virtio-net-pci,id=net1,netdev=net0 \
	-netdev user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp::10022-:22 \
	-device virtio-blk-pci,id=disk1,drive=drive1 \
	-drive media=disk,id=drive1,if=none,file=user_union_standin.qcow,discard=unmap,detect-zeroes=unmap \
	-device virtio-rng-pci \
	-append "tcti_disk=file" &
QEMU_PID=$!

while true; do
	sleep 1
	ssh -i placeholder_keys/placeholder_key root@localhost -p 10022
done

# Cleanup.
kill $QEMU_PID
