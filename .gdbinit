symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor att
target remote | qemu-system-x86_64 -S -gdb stdio -hda ./.zig-cache/o/d54fe21e9afb098c4d6f560db800503f/lazyos.img --machine q35,accel=kvm --cpu host -bios /usr/share/ovmf/x64/OVMF.4m.fd
