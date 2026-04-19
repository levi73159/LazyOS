#!/bin/bash

set -e
sudo -v

IMG="$1"
IMG_SIZE="$2" # in MB
ROOT_FOLDER="$3" # files that will be in root partition
KERNEL="$4"

dd if=/dev/zero of="$IMG" bs=1M count="$IMG_SIZE" && sync

parted -s $IMG mklabel gpt
parted -s $IMG mkpart BIOS "" 1MiB 2MiB      # partition 1 — BIOS boot
parted -s $IMG set 1 bios_grub on
parted -s $IMG mkpart ESP fat32 2MiB 32MiB   # partition 2 — EFI/boot
parted -s $IMG set 2 esp on
parted -s $IMG mkpart primary ext2 32MiB 100%   # partition 3 — root

# attach to loop device so we can copy files
LOOP=$(sudo losetup -fP --show "$IMG")

sudo mkfs.fat -F 16 ${LOOP}p2
sudo mkfs.ext2 ${LOOP}p3

# 'boot' partition
sudo mkdir -p /mnt/lazyos_boot
sudo mount ${LOOP}p2 /mnt/lazyos_boot
sudo mkdir -p /mnt/lazyos_boot/EFI/BOOT
sudo cp bootloader/limine.conf /mnt/lazyos_boot/
sudo cp $KERNEL /mnt/lazyos_boot/
sudo cp limine/BOOTX64.EFI /mnt/lazyos_boot/EFI/BOOT
sudo umount /mnt/lazyos_boot
sudo rmdir /mnt/lazyos_boot

# 'root' partition
sudo mkdir -p /mnt/lazyos_root
sudo mount ${LOOP}p3 /mnt/lazyos_root

sudo cp -r $ROOT_FOLDER/* /mnt/lazyos_root

sudo umount /mnt/lazyos_root
sudo rmdir /mnt/lazyos_root
sudo losetup -d $LOOP

sudo ./limine/limine bios-install $IMG

echo "Done: $IMG"
