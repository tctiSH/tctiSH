#!/bin/bash

if [ -d ramdisk ]; then
	echo "This environment is already set up for ramdisk development."
	echo ""
	echo "Any changes to the 'ramdisk' folder will automatically be packed "
	echo "into inird.img when running 'start_tcti.sh'."
	exit 0
fi

echo "Creating a 'live' ramdisk directory..."
mkdir ramdisk
pushd ramdisk
	zcat < ../initrd.img | cpio -idmv 2> /dev/null
popd
echo "Done. From now on, any changes to the 'ramdisk' folder will automatically"
echo "be packed into inird.img when running 'start_tcti.sh'."
