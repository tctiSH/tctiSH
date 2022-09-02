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

CONSOLE_KERNEL_OPTIONS=""
CONSOLE_QEMU_OPTIONS=""

# If we don't have a TCTI install, create one.
if [ ! -f ../qemu-tcti/build/qemu-system-${TCTI_ARCH} ]; then
	./build_tcti.sh
fi

# Make sure our TCTI build is up to date.
pushd ../qemu-tcti/build
	ninja qemu-system-${TCTI_ARCH}
popd

# If we don't have a stand-in for our iOS user storage, create one.
if [ ! -f user_union_standin.qcow ]; then
	../qemu-tcti/build/qemu-img create -f qcow2 user_union_standin.qcow ${STANDIN_IMAGE_SIZE}

	# The first time this runs, it's going to take a while. Enable console.
	CONSOLE_KERNEL_OPTIONS="console=ttyS0"
	CONSOLE_QEMU_OPTIONS="-serial stdio"

fi

# Run TCTI.
../qemu-tcti/build/qemu-system-${TCTI_ARCH} \
	-display none \
	-kernel bzImage \
	-initrd initrd.img \
	-m 4G \
	-device virtio-net-pci,id=net1,netdev=net0 \
	-netdev user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp::10022-:22,hostfwd=tcp::10023-:23 \
	-device virtio-blk-pci,id=disk1,drive=drive1 \
	-drive media=disk,id=drive1,if=none,file=user_union_standin.qcow,discard=unmap,detect-zeroes=unmap \
	-device virtio-rng-pci \
	$CONSOLE_QEMU_OPTIONS \
	-append "tcti_disk=file $CONSOLE_KERNEL_OPTIONS" &
QEMU_PID=$!

while true; do
	sleep 1
	ssh -i placeholder_keys/placeholder_key root@localhost -p 10022
done

# Cleanup.
kill $QEMU_PID
