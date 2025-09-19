#!/bin/bash

IMG_PATH=$1


dd if=/dev/zero of=$IMG_PATH bs=1048576 count=10
printf "g\nn p\n1\n2048\n+8M\nt\n1\nw\n" | fdisk $IMG_PATH
losetup -D
losetup -o 1048576 -f $IMG_PATH
mkfs.vfat -F 16 -v -n "EFI System" /dev/loop0
mkdir -p img
mount -t vfat,fat=16 /dev/loop0 img
mkdir -p img/BIOS/BOOT
mkdir -p img/EFI/BOOT
mkdir -p img/SYS
cp boot.efi img/EFI/BOOT/BOOTx64.EFI
# cp kernel64.elf img/SYS/KERNEL64.elf
umount img
rmdir img
losetup -D
