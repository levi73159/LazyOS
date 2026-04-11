#!/bin/bash

USB="$1"

zig build --release=safe

./limine/limine bios-install zig-out/bin/lazyos.iso

sudo dd if=zig-out/bin/lazyos.iso of=$USB bs=4M status=progress && sync
