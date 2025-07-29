#!/bin/bash

echo "Checking if tools are installed..."
which zig > /dev/null || (echo "Error: zig not found in PATH" && exit 1)
which grub-mkrescue > /dev/null || (echo "Error: grub-mkrescue not found in PATH" && exit 1)
which xorriso > /dev/null || (echo "Error: xorriso not found in PATH" && exit 1)
which qemu-system-x86_64 > /dev/null || (echo "Error: qemu-system-x86_64 not found in PATH" && exit 1)

echo "All required tools found"
