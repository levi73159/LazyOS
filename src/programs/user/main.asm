[bits 64]

section .text
global _start

_start:
mov rax, 1          ; syscall number for write
mov rdi, 1          ; file descriptor 1 (stdout)
lea rsi, [rel msg]  ; address of the string
mov rdx, 13         ; length of string
syscall             ; invoke the kernel

mov rax, 1
mov rdi, 2
lea rsi, [rel err]
mov rdx, 6
syscall

mov rax, 60
mov rdi, 0
syscall

jmp $

msg: db "Test Program", 10 ; len = 13
err: db "Error", 10        ; len = 6
