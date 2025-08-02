
ASM=nasm
ASMFLAGS=-f obj
CC16=/opt/watcom/binl/wcc
CFLAGS16=-4 -d3 -s -wx -ms -zl -zq -ecc # -oneatxzh 
LD16=/opt/watcom/binl/wlink

OBJ_DIR=$(BUILD_DIR)/obj
BIN_DIR=$(BUILD_DIR)/bin

SOURCES_C=$(wildcard *.c)
SOURCES_ASM=$(wildcard *.asm)
OBJECTS_C=$(patsubst %.c, $(OBJ_DIR)/stage2/c/%.obj, $(SOURCES_C))
OBJECTS_ASM=$(patsubst %.asm, $(OBJ_DIR)/stage2/asm/%.obj, $(SOURCES_ASM))

.PHONY: all stage2 clean always

all: stage2

stage2: $(BIN_DIR)/stage2.bin

$(BIN_DIR)/stage2.bin: $(OBJECTS_ASM) $(OBJECTS_C)
	@$(LD16) NAME $(BIN_DIR)/stage2.bin FILE \{ $(OBJECTS_ASM) $(OBJECTS_C) \} OPTION MAP=$(BIN_DIR)/stage2.map @linker.lnk

$(OBJ_DIR)/stage2/c/%.obj: %.c always
	$(CC16) $(CFLAGS16) -fo=$@ $<

$(OBJ_DIR)/stage2/asm/%.obj: %.asm always
	$(ASM) $(ASMFLAGS) -o $@ $<

always:
	@mkdir -p $(OBJ_DIR)/stage2/c
	@mkdir -p $(OBJ_DIR)/stage2/asm

clean:
	rm -f $(BUILD_DIR)/stage2.bin
