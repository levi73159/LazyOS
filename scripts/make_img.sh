#!/bin/bash
set -e

BOOT_IMG="$1"
ROOT_IMG="$2"
OUTPUT="$3"
TOTAL_MB="${4:-64}"

BOOT_START_SECTOR=4096    # 2MiB in 512-byte sectors
ROOT_START_SECTOR=65536   # 32MiB in 512-byte sectors

# blank image + GPT
dd if=/dev/zero of="$OUTPUT" bs=1M count="$TOTAL_MB"
parted -s "$OUTPUT" mklabel gpt
parted -s "$OUTPUT" mkpart BIOS  ""    1MiB  2MiB
parted -s "$OUTPUT" set 1 bios_grub on
parted -s "$OUTPUT" mkpart ESP fat32   2MiB  32MiB
parted -s "$OUTPUT" set 2 esp on
parted -s "$OUTPUT" mkpart primary ext2 32MiB 100%

# write partition images at correct offsets
dd if="$BOOT_IMG" of="$OUTPUT" bs=512 seek=$BOOT_START_SECTOR conv=notrunc
dd if="$ROOT_IMG" of="$OUTPUT" bs=512 seek=$ROOT_START_SECTOR  conv=notrunc

# root.ext2 clobbered the backup GPT — move it back to where it belongs
sgdisk --move-second-header "$OUTPUT"

./limine/limine bios-install "$OUTPUT"
echo "Done: $OUTPUT"
