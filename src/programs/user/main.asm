; test.asm
bits 64
default rel

section .text
global _start

_start:
    ; sys_write(1, msg, 13)
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg]
    mov rdx, 13
    syscall

    ; sys_exit(0)
    mov rax, 60
    xor rdi, rdi
    syscall

section .data
msg: db "Hello World!", 10
