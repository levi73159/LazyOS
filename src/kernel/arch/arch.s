.extern interruptHandler

.section .text
.global loadIDT
loadIDT:
    lidt (%rdi)
    ret

.global asm_loadGDT
asm_loadGDT:
    lgdt (%rdi)
    ret

.global interruptCommon
interruptCommon:
    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
    push %rdi
    push %rsi
    push %rbp

    mov $0, %rax
    mov %ds, %ax
    push %rax

    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs

    mov %rsp, %rdi    # frame pointer into rdi (first arg)
    sub $8, %rsp      # align to 16 bytes before call
    call interruptHandler
    add $8, %rsp      # undo alignment pad

    pop %rax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs

    pop %rbp
    pop %rsi
    pop %rdi
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax
    add $16, %rsp
    iretq
