#!/usr/bin/env bash
# Install host dependencies for building and running LazyOS.
# Supports Debian/Ubuntu (apt) and Arch (pacman + an AUR helper for genext2fs).
#
# Does NOT install zig 0.16.0 — get it with zvm (`zvm install 0.16.0`) or from
# https://ziglang.org/download/0.16.0/
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

install_apt() {
  echo ">> Installing packages with apt..."
  $SUDO apt-get update
  $SUDO apt-get install -y \
    nasm musl-tools mtools dosfstools genext2fs xorriso imagemagick qemu-system-x86 ovmf
  # ImageMagick 6 ships `convert` but the build scripts call `magick`.
  if ! command -v magick >/dev/null 2>&1 && command -v convert >/dev/null 2>&1; then
    echo ">> Adding 'magick' shim -> convert"
    $SUDO ln -sf "$(command -v convert)" /usr/local/bin/magick
  fi
}

install_arch() {
  echo ">> Installing packages with pacman..."
  $SUDO pacman -S --needed --noconfirm \
    nasm musl mtools dosfstools libisoburn imagemagick qemu-system-x86 edk2-ovmf
  # genext2fs is in the AUR.
  if command -v yay >/dev/null 2>&1; then
    yay -S --needed --noconfirm genext2fs
  elif command -v paru >/dev/null 2>&1; then
    paru -S --needed --noconfirm genext2fs
  else
    echo "!! genext2fs is in the AUR; install it with an AUR helper (yay/paru) or manually." >&2
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  install_apt
elif command -v pacman >/dev/null 2>&1; then
  install_arch
else
  echo "Unsupported distro: need apt-get or pacman." >&2
  exit 1
fi

cat <<'EOF'

Host packages installed.

Next steps:
  zvm install 0.16.0 && zvm use 0.16.0   # or put zig 0.16.0 on your PATH
  git submodule update --init --recursive
  make -C limine
  zig build
EOF
