org 0x0
bits 16

%define NL 0x0D, 0x0A

start:
    jmp main

; data
message: db "Hello Kernel!", NL, 0

main:
    ; print message
    mov si, message
    call puts

    hlt

.halt:
    jmp .halt

; ========= functions =======

;
; Prints a string to the screen
; Params:
;   - ds:si: the string to print (null-terminated)
puts:
    push si
    push ax

    mov ah, 0x0E    ; set video mode for int 0x10
    mov bh, 0       ; set page mode = 0

.loop:
    lodsb       ; load next character in al
    or al, al   ; verfiy if next is null?
    jz .done

    int 0x10

    jmp .loop

.done:
    pop ax
    pop si
    ret
