org 0x7C00
bits 16

%define NL 0x0D, 0x0A

; ========= fat 12 headers =======
jmp short start
nop

bdb_oem:                    db "MSWIN4.1"           ; 8 bytes
bdb_bytes_per_sector:       dw 512
bdb_sectors_per_cluster:    db 1
bdb_reserved_sectors:       dw 1
bdb_fat_count:              db 2
bdb_dir_entries_count:      dw 0E0h
bdb_total_sectors:          dw 2880                 ; 2880 * 512 = 1.44MB
bdb_media_descriptor_type:  db 0F0h                 ; F0 = 3.5" floppy disk
bdb_sectors_per_fat:        dw 9                    ; 9 sectors/fat
bdb_sectors_per_track:      dw 18
bdb_heads:                  dw 2
bdb_hidden_sectors:         dd 0
bdb_large_sector_count:     dd 0

; extended boot record
ebr_drive_number:           db 0                    ; 0x00 floppy, 0x80 hdd, useless
                            db 0                    ; reserved
ebr_signature:              db 29h
ebr_volume_id:              db 12h, 34h, 56h, 78h   ; serial number, value doesn't matter
ebr_volume_label:           db "LAZY OS    "        ; 11 bytes, padded with spaces
ebr_system_id:              db "FAT12   "           ; 8 bytes

; ========= code =======

start:
    jmp main

; data
message: db "Hello World!", NL, 0
msg_read_failed: db "Failed to read", NL, 0

main:
    ; set up data segments 
    mov ax, 0
    mov ds, ax
    mov es, ax

    ; set up stack
    mov ss, ax
    mov sp, 0x7C00

    ; read somthing from disk
    ; BIOS should set dl to drive number
    mov [ebr_drive_number], dl

    mov ax, 1       ; LBA=1, second sector from disk
    mov cl, 1       ; read 1 sector
    mov bx, 0x7E00  ; data should be after the bootloader
    call disk_read

    ; print message
    mov si, message
    call puts

.halt:
    cli
    hlt

; ========= functions =======

; error handlers
floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key

wait_key:
    mov ah, 0x0
    int 0x16
    jmp 0xFFFF:0 ; jump to beginning of the bios

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

; ===== disk routines =====

; LBA to CHS conversion
;   sector = (lba % sectors_per_track) + 1
;   head = (lba / sectors_per_track) % heads
;   cylinder = (lba / sectors_per_track) / heads

;
; Converts LBA to CHS (see comment above to see how it works)
; Params:
;   - ax: the LBA address
; Returns:
;   - cx [bits 0-5]: sector number
;   - cx [bits 6-15]: cylinder number
;   - dh: head number
;
lba_to_chs:
    push ax
    push dx

    mov dx, 0 ; dx = 0
    div word [bdb_sectors_per_track] ; ax = lba / sectors_per_track, 
                                     ; dx = lba % sectors_per_track
    inc dx                           ; dx = lba % sectors_per_track + 1 (we now got the sector number)
    mov cx, dx

    mov dx, 0 ; (I FORGOT THIS, and it was the reason for a long time that it didn't work)
    div word [bdb_heads]             ; ax = (lba / sectors_per_track) / heads (we now got the cylinder number)
                                     ; dx = (lba / sectors_per_track) % heads (we now got the head number)

    ; do some magic to get the address in the right registers
    mov dh, dl                       ; dh = head number
    mov ch, al                       ; ch = cylinder (lower 8 bits)
    shl ah, 6
    or cl, ah                        ; cl = cylinder (upper 2 bits)

    pop ax
    mov dl, al ; restore dl
    pop ax
    ret

;
; Reads a sector from the disk
; Params:
;   - ax: the LBA address
;   - cl: number of sectors to read
;   - dl: drive number
;   - es:bx: the address to store the data
disk_read:
    push ax
    push bx
    push cx
    push dx
    push di

    push cx ; temp save cl, number of sectors to read
    call lba_to_chs
    pop ax ; al = number of sectors to read

    mov ah, 0x02 ; read sectors
    mov di, 3    ; retry count

.retry:
    pusha        ; save registers
    stc          ; BIOS somtimes won't set carry flag
    int 0x13     ; carry flag clear = success
    jnc .done    ; carry flag set = error

    ; retry failed
    popa         ; restore registers
    dec di       ; retry count
    test di, di  ; retry count = 0?
    jnz .retry   ; retry

.fail:
    jmp floppy_error

.done:
    popa         ; restore registers

    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

;
; Resets the disk controller
; Params:
;   - dl: drive number
disk_reset:
    pusha
    mov ah, 0x00
    stc
    int 0x13
    jc floppy_error
    popa
    ret

times 510-($-$$) db 0
dw 0xAA55
