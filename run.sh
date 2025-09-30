#!/bin/bash
set -euo pipefail

# Settings
DISK="disk.img"
SIZE="2G"
EFI_PART_SIZE="+512M"
EFI_MOUNT="img"
EFI_BOOT_PATH="$EFI_MOUNT/EFI/BOOT"
BOOTX64="zig-out/bin/bootx64.efi"   # Path to your EFI binary
OVMF_CODE="/usr/share/OVMF/x64/OVMF_CODE.4m.fd" # Adjust if in a different path
OVMF_VARS="/tmp/OVMF_VARS.fd"

# Clean up any old disk
rm -f "$DISK"

# 1. Create raw disk image
qemu-img create "$DISK" $SIZE

# 2. Partition with GPT and make EFI System Partition
sgdisk -o "$DISK"
sgdisk -n 1:2048:$EFI_PART_SIZE -t 1:EF00 -c 1:"EFI System" "$DISK"

# 3. Set up loop device
LOOP=$(sudo losetup --show -f -P "$DISK")

# 4. Format partition 1 as FAT32
sudo mkfs.fat -F32 "${LOOP}p1"

# 5. Mount and copy Bootx64.efi
sudo mkdir -p "$EFI_BOOT_PATH"
sudo mount "${LOOP}p1" "$EFI_MOUNT"
sudo mkdir -p "$EFI_BOOT_PATH"
sudo cp "$BOOTX64" "$EFI_BOOT_PATH/BOOTx64.efi"
sync
sudo umount "$EFI_MOUNT"
sudo losetup -d "$LOOP"

echo "Disk image created: $DISK"
echo "Now launching QEMU with UEFI firmware..."

# 6. Run QEMU with OVMF
qemu-system-x86_64 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -hda "$DISK"
