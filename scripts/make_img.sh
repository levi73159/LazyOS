#!/bin/bash

IMG_PATH=$1
EFI_PATH=$2
IMG_ROOT=$3

dd if=/dev/zero of=$IMG_PATH bs=1M count=10
gdisk $IMG_PATH < scripts/gdisk.script

offset=$(fdisk -l $IMG_PATH | awk '/disk.img1/ {print $2 * 512}')
echo "offset: $offset"

# NOTE: is it possible to do this without sudo?
# mformat -i $IMG_PATH@@$offset ::
#
# mmd -i $IMG_PATH@@$offset ::EFI
# mmd -i $IMG_PATH@@$offset ::EFI/BOOT
#
# mcopy -i $IMG_PATH@@$offset $EFI_PATH ::EFI/BOOT/BOOTX64.EFI
#
# mcopy -i $IMG_PATH@@$offset $IMG_ROOT/* ::

# sudo losetup -o $offset /dev/loop0 $IMG_PATH
# sudo mkfs.fat -F32 /dev/loop0
# sudo losetup -d /dev/loop0
#
# mkdir img
# sudo mount -o loop,offset=$offset $IMG_PATH img
# sudo mkdir -p img/EFI/BOOT
# sudo cp $EFI_PATH img/EFI/BOOT/BOOTX64.EFI
# sudo umount img
# sudo rm -rf img
