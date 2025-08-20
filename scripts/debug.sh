#!/bin/bash


if [ "$#" -le 0 ]; then
    echo "Usage: $0 <image>"
    exit 1
fi

QEMU_ARGS="-S -gdb stdio -m 32 -hda $1"

# kernel starts at 1M aka 0x100000
# layout asm
cat > .gdbinit << EOF
symbol-file $PWD/zig-out/bin/kernel
set disassembly-flavor intel
target remote | qemu-system-i386 $QEMU_ARGS
EOF

gdb -x .gdbinit
