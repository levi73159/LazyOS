ASM=nasm

BIN_DIR=$(BUILD_DIR)/bin

.PHONY: all bootloader

#
# Bootloader
#
bootloader: $(BIN_DIR)/stage1.bin
all: bootloader

$(BIN_DIR)/stage1.bin: boot.asm
	$(ASM) -f bin -o $@ $<
