ASM=nasm

BUILD_DIR=../../zig-out
BIN_DIR=$(BUILD_DIR)/bin

#
# Bootloader
#
bootloader: $(BIN_DIR)/bootloader.bin

$(BIN_DIR)/bootloader.bin: boot.asm
	$(ASM) -f bin -o $@ $<
