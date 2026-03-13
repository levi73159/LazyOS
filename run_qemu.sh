#!/bin/bash

set -e
ISO="$1"

qemu-system-x86_64 \
  -cdrom "$ISO" \
  -cpu qemu64 \
  -debugcon stdio \
  -serial file:serial.log \
  -s -S \
  -no-reboot \
  -no-shutdown \
  -bios /usr/share/ovmf/x64/OVMF.4m.fd
