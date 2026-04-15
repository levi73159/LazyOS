symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor att
target remote | qemu-system-x86_64 -S -gdb stdio -hda ./.zig-cache/o/90bbea6456e89c0619ac34f19ba055d5/lazyos.img --machine q35,accel=kvm --cpu host -bios /usr/share/ovmf/x64/OVMF.4m.fd
