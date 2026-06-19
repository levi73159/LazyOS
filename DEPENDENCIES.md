# Dependencies

Everything needed to build and run LazyOS on a fresh Linux host.

You can install everything automatically with [`scripts/install-deps.sh`](scripts/install-deps.sh)
(supports both `apt` and `pacman`/`yay`), or follow the manual steps below.

## Toolchain

- **Zig 0.16.0** — exact version. Get it via [zvm](https://github.com/tristanisham/zvm) (`zvm install 0.16.0`) or download from <https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz> and put it on your `PATH`. (Distro `zig` packages track the latest release and usually won't be 0.16.0.)

## Host packages

### Debian / Ubuntu (apt)

```sh
sudo apt-get update
sudo apt-get install -y \
  nasm \
  musl-tools \
  mtools \
  dosfstools \
  genext2fs \
  xorriso \
  imagemagick \
  qemu-system-x86 \
  ovmf
```

### Arch (pacman / yay)

`genext2fs` lives in the AUR, so install it with an AUR helper (`yay`/`paru`); the rest are in the official repos.

```sh
# official repos
sudo pacman -S --needed nasm musl mtools dosfstools libisoburn imagemagick qemu-system-x86 edk2-ovmf
# AUR
yay -S --needed genext2fs
```

### Package reference

| Debian/Ubuntu      | Arch              | Used for |
| ------------------ | ----------------- | -------- |
| `nasm`             | `nasm`            | assembling userland programs |
| `musl-tools`       | `musl`            | `musl-gcc` for building C userland programs |
| `mtools`           | `mtools`          | building the FAT EFI system partition (`boot.fat`) |
| `dosfstools`       | `dosfstools`      | `mkfs.vfat` for the EFI partition |
| `genext2fs`        | `genext2fs` (AUR) | building the ext2 root filesystem (`root.ext2`) |
| `xorriso`          | `libisoburn`      | ISO image creation (`xorriso`) |
| `imagemagick`      | `imagemagick`     | converting `assets/*.png` UI assets to `.tga` |
| `qemu-system-x86`  | `qemu-system-x86` | running the OS (`zig build run`) |
| `ovmf`             | `edk2-ovmf`       | UEFI firmware for QEMU (we boot via OVMF, not BIOS) |

> Note: ImageMagick **6** (common on Ubuntu) only ships `convert`, but the build
> scripts call `magick`. ImageMagick 7 (Arch) ships `magick` directly. If `magick`
> is missing, add a shim:
> ```sh
> sudo ln -sf "$(command -v convert)" /usr/local/bin/magick
> ```

## Submodules and limine

```sh
git submodule update --init --recursive   # limine, vendor/uACPI
make -C limine                            # build the host `limine` binary
```

## Build & run

```sh
zig build              # build kernel + bootable image -> zig-out/bin/lazyos.img
zig build make-image   # build the disk image only
```

Run under QEMU with the OVMF (UEFI) firmware; the kernel logs to COM1:

```sh
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/ovmf_vars.fd   # Arch: /usr/share/edk2/x64/OVMF_VARS.4m.fd
qemu-system-x86_64 \
  -drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/ovmf_vars.fd \
  -drive format=raw,file=zig-out/bin/lazyos.img \
  -machine q35 -cpu max -serial stdio
```

> OVMF firmware paths differ by distro. Debian/Ubuntu: `/usr/share/OVMF/OVMF_CODE_4M.fd`
> and `OVMF_VARS_4M.fd`. Arch (`edk2-ovmf`): `/usr/share/edk2/x64/OVMF_CODE.4m.fd`
> NOTE: it might be different for you!

`zig build run` wraps QEMU as well (see `build/qemu.build.zig`).
