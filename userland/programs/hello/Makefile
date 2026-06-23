# src/programs/hello/Makefile

OUT     ?= hello.bin
OBJ_DIR ?= .

CC      = zig cc -target x86_64-linux-musl

CFLAGS  = -static -O3 -fno-pie -no-pie
LDFLAGS = -Wl,--no-as-needed

all: $(OUT)

$(OUT): $(OBJ_DIR)/hello.o
	$(CC) $(CFLAGS) $(LDFLAGS) -g -o $@ $(OBJ_DIR)/hello.o

$(OBJ_DIR)/hello.o: hello.c
	$(CC) $(CFLAGS) -g -c -o $@ $<

clean:
	rm -f $(OBJ_DIR)/hello.o $(OUT)
