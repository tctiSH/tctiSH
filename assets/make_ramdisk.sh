#!/bin/bash

pushd ramdisk
	find . | cpio -o -c -H newc | gzip -9 > ../initrd.img 2> /dev/null
popd
