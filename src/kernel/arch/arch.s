.section .text
.global loadIDT
loadIDT:
    lidt (%rdi)
    ret

.global asm_loadGDT
asm_loadGDT:
    lgdt (%rdi)
    ret
