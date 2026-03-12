symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor intel
target remote | qemu-system-x86_64 -S -gdb stdio -cdrom /home/levi/Projects/LazyOS/zig-out/bin/lazyos.iso
