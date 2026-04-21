#!/bin/bash

set -e
KERNEL="$1"
OUTPUT="$2"

dd if=/dev/zero of="$OUTPUT" bs=1M count=30
mkfs.fat -F 16 "$OUTPUT"
mmd   -i "$OUTPUT"                        ::/EFI
mmd   -i "$OUTPUT"                        ::/EFI/BOOT
mcopy -i "$OUTPUT" bootloader/limine.conf ::
mcopy -i "$OUTPUT" "$KERNEL"              ::
mcopy -i "$OUTPUT" limine/BOOTX64.EFI     ::/EFI/BOOT
