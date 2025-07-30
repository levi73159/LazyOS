ASM=nasm

BUILD_DIR=../../zig-out
BIN_DIR=$(BUILD_DIR)/bin

#
# Kernel
#
kernel: $(BIN_DIR)/kernel.bin

$(BIN_DIR)/kernel.bin: kmain.asm
	$(ASM) -f bin -o $@ $<
