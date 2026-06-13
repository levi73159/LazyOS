symbol-file /home/levi/Projects/LazyOS/zig-out/bin/kernel
set disassembly-flavor att
target remote | qemu-system-x86_64 -S -gdb stdio -hda ./.zig-cache/o/f13cd4315b3f610f63b22398da675b1e/lazyos.img --machine q35,accel=kvm --cpu host -bios /usr/share/ovmf/x64/OVMF.4m.fd --no-reboot --no-shutdown
