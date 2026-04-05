# src/programs/hello/Makefile
OUT     ?= hello.bin
OBJ_DIR ?= .

CC     = musl-gcc
CFLAGS = -static -O2 -fno-pie -no-pie

all: $(OUT)

$(OUT): $(OBJ_DIR)/hello.o
	$(CC) $(CFLAGS) -o $@ $(OBJ_DIR)/hello.o

$(OBJ_DIR)/hello.o: hello.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJ_DIR)/hello.o $(OUT)
