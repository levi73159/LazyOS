symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor intel
target remote | qemu-system-i386 -S -gdb stdio -m 32 -hda zig-out/lazyos.iso
