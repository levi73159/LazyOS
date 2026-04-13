symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor att
target remote | qemu-system-x86_64 -S -gdb stdio -hda /home/levi/Projects/LazyOS/zig-out/bin/lazyos.img --machine q35,accel=kvm --cpu host -bios /usr/share/ovmf/x64/OVMF.4m.fd
