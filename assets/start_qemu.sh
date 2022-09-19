#!/bin/bash

# The architecture of we're targeting with QEMU.
TCTI_ARCH="x86_64"

USE_SSH=1
USE_DISK_STANDIN=1
INSTANT_STARTUP=0
FOREIGN_MOUNT=1

# The (initial) ram size of the disk.
INITIAL_RAM_SIZE="1G"

# The size of the image used to emulate iOS storage.
STANDIN_IMAGE_SIZE="200G"

# If we have a ramdisk directory, use it to create a ramdisk for TCTI.
if [ -d ramdisk ]; then
	pushd ramdisk
		find . | cpio -o -c -H newc | gzip -9 > ../initrd.img 2> /dev/null
	popd
fi

CONSOLE_KERNEL_OPTIONS=""
CONSOLE_QEMU_OPTIONS=""
BACKGROUND=""

# If we don't have a TCTI install, create one.
if [ ! -f ../qemu-tcti/build_mac/qemu-system-${TCTI_ARCH} ]; then
	./build_qemu.sh
fi

# Make sure our TCTI build is up to date.
pushd ../qemu-tcti/build_mac
	ninja qemu-system-${TCTI_ARCH}
popd

# If we're using a disk standin, set that up.
if [ $USE_DISK_STANDIN != 0 ]; then
	echo "Note: using disk as a standin for PV comms."
	CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -device virtio-blk-pci,id=disk1,drive=drive1"
	CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -drive media=disk,id=drive1,if=none,file=empty.qcow,discard=unmap,detect-zeroes=unmap"
	CONSOLE_KERNEL_OPTIONS="$CONSOLE_KERNEL_OPTIONS tcti_disk=file"

	# If we don't have a stand-in for our iOS user storage, create one.
	if [ ! -f empty.qcow ]; then
		../qemu-tcti/build_mac/qemu-img create -f qcow2 empty.qcow ${STANDIN_IMAGE_SIZE}

		# The first time this runs, it's going to take a while. Enable console.
		CONSOLE_KERNEL_OPTIONS="$CONSOLE_KERNEL_OPTIONS console=ttyS0"
		#CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -serial stdio"
	fi
else
	# TODO: set up PV comms here
	true
fi

# If we're using instant startup, instantly load our saved state.
if [ $INSTANT_STARTUP != 0 ]; then
	echo "Using instant startup."
	CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -loadvm instantboot"
fi

# If we're not using SSH, switch our mode to nograpnic.
if [ $USE_SSH == 0 ]; then
	echo "Not using SSH."
	CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -nographic"
	BACKGROUND=""
else 
	CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -display none"
	BACKGROUND="&"
fi


# If we're using an example of pulling in something from the host, do that.
if [ $FOREIGN_MOUNT != 0 ]; then
	echo "Passing /tmp into the vm, as an example."
	echo "mount with: mount -t 9p -o trans=virtio foreign /mnt -oversion=9p2000.L"
	CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -fsdev local,path=/tmp/,security_model=none,id=fsdev0"
	CONSOLE_QEMU_OPTIONS="$CONSOLE_QEMU_OPTIONS -device virtio-9p-pci,fsdev=fsdev0,mount_tag=shared"
fi

#fsdev_add local,path=/tmp/,mount_tag=foreign,security_model=none,id=fsdev0


# Run TCTI.
../qemu-tcti/build_mac/qemu-system-${TCTI_ARCH} \
	-kernel bzImage \
	-initrd initrd.img \
	-m $INITIAL_RAM_SIZE \
	-device virtio-net-pci,id=net1,netdev=net0 \
	-netdev user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp::10022-:22,hostfwd=tcp::10023-:23 \
	-device virtio-rng-pci \
	$CONSOLE_QEMU_OPTIONS \
	-append "$CONSOLE_KERNEL_OPTIONS" \
	-monitor tcp:localhost:10044,server,wait=off \
	-monitor tcp:localhost:10045,server,wait=off &
QEMU_PID=$!



# If we're not using SSH, forground QEMU and just use that.
if [ $USE_SSH == 0 ]; then
	exit 0

# Otherwise, connect via SSH.
else

	while true; do
		sleep 1
		ssh -i placeholder_keys/placeholder_key root@localhost -p 10022
	done

	# Cleanup.
	kill $QEMU_PID

fi
