#!/bin/bash

objdump -d -M intel zig-out/bin/kernel > zig-out/kernel.asm
readelf -a zig-out/bin/kernel > zig-out/kernel.info
