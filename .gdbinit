symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor att
target remote | qemu-system-x86_64 -S -gdb stdio -cdrom /home/levi/Projects/LazyOS/zig-out/bin/lazyos.iso --machine q35,accel=kvm --cpu host
