#!/bin/bash


if [ "$#" -le 0 ]; then
    echo "Usage: $0 <image>"
    exit 1
fi

QEMU_ARGS="-S -gdb stdio -cdrom $1 --machine q35"

# kernel starts at 1M aka 0x100000
# layout asm
cat > .gdbinit << EOF
symbol-file $PWD/zig-out/bin/kernel
set disassembly-flavor att
target remote | qemu-system-x86_64 $QEMU_ARGS
EOF

gdb -x .gdbinit
