ASM=nasm

BIN_DIR=$(BUILD_DIR)/bin

.PHONY: all kernel
all: kernel

#
# Kernel
#
kernel: $(BIN_DIR)/kernel.bin

$(BIN_DIR)/kernel.bin: kmain.asm
	$(ASM) -f bin -o $@ $<
