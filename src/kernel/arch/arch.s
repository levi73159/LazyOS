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
    testb $3, 24(%rsp)
    jz .Lno_swapgs_entry
    swapgs

.Lno_swapgs_entry:
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

    mov %rsp, %rdi    # frame pointer into rdi (first arg)
    sub $8, %rsp      # align to 16 bytes before call
    call interruptHandler
    add $8, %rsp      # undo alignment pad

    pop %rax
    mov %ax, %ds
    mov %ax, %es

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

    testb $3, 8(%rsp)
    jz .Lno_swapgs_exit
    swapgs
.Lno_swapgs_exit:
    iretq

.global syscallEntry
.extern user_rsp
.extern kernel_rsp
.extern syscallHandler
syscallEntry:
    mov %rsp, user_rsp(%rip)
    mov kernel_rsp(%rip), %rsp

    # saves r11 (rflags)
    push %r11 
    # saves rcx (rip)
    push %rcx 

    push %rax
    push %rbx
    # skip rcx since is saved above
    push %rdx
    push %r8
    push %r9
    push %r10
    # skip r11 since is saved above
    push %r12
    push %r13
    push %r14
    push %r15

    push %rdi
    push %rsi
    push %rbp

    mov %rsp, %rdi
    sub $8, %rsp
    call syscallHandler
    add $8, %rsp

    pop %rbp
    pop %rsi
    pop %rdi

    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r10
    pop %r9
    pop %r8
    pop %rdx
    pop %rbx
    pop %rax

    pop %rcx 
    pop %r11 

    mov user_rsp(%rip), %rsp
    sysretq
