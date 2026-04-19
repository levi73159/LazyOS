OUT ?= out
OBJ_DIR ?= .

SRCS = $(wildcard *.asm)
OBJS = $(patsubst %.asm,$(OBJ_DIR)/%.o,$(SRCS))

all: $(OUT)

$(OBJ_DIR)/%.o: %.asm
	nasm -f elf64 -o $@ $<

$(OUT): $(OBJS)
	ld -m elf_x86_64 -T link.ld -nostdlib -o $@ $^
