symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor att
target remote | qemu-system-x86_64 -S -gdb stdio -hda ./.zig-cache/o/6c01086bc1edf617ce992725d389a62a/lazyos.img --machine q35,accel=kvm --cpu host -bios /usr/share/ovmf/x64/OVMF.4m.fd --no-reboot --no-shutdown
