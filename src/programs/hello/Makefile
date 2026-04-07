# src/programs/hello/Makefile
OUT     ?= hello.bin
OBJ_DIR ?= .

CC     = /opt/musl-debug/bin/musl-gcc
CFLAGS = -static -O0 -fno-pie -no-pie

all: $(OUT)

$(OUT): $(OBJ_DIR)/hello.o
	$(CC) $(CFLAGS) -g -o $@ $(OBJ_DIR)/hello.o

$(OBJ_DIR)/hello.o: hello.c
	$(CC) $(CFLAGS) -g -c -o $@ $<

clean:
	rm -f $(OBJ_DIR)/hello.o $(OUT)
