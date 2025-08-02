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
bdb_dir_entries_count:      dw 0xE0
bdb_total_sectors:          dw 2880                 ; 2880 * 512 = 1.44MB
bdb_media_descriptor_type:  db 0xF0                 ; F0 = 3.5" floppy disk
bdb_sectors_per_fat:        dw 9                    ; 9 sectors/fat
bdb_sectors_per_track:      dw 18
bdb_heads:                  dw 2
bdb_hidden_sectors:         dd 0
bdb_large_sector_count:     dd 0

; extended boot record
ebr_drive_number:           db 0                    ; 0x00 floppy, 0x80 hdd, useless
                            db 0                    ; reserved
ebr_signature:              db 0x29
ebr_volume_id:              db 0x43, 0x4C, 0x81, 0x8C   ; serial number, value doesn't matter
ebr_volume_label:           db "LAZY OS    "        ; 11 bytes, padded with spaces
ebr_system_id:              db "FAT12   "           ; 8 bytes

stage2_LOAD_SEGMENT equ 0x2000
stage2_LOAD_OFFSET equ 0

start:
    ; set up data segments 
    xor ax, ax ; ax = 0
    mov ds, ax
    mov es, ax

    ; set up stack
    mov ss, ax
    mov sp, 0x7C00

    ; some bioses might start us at 07C0:0000 instead of 0000:7c00, make sure we are in the
    ; expected location
    push es
    push word .after
    retf
.after:

    ; read somthing from disk
    ; BIOS should set dl to drive number
    mov [ebr_drive_number], dl

    ; read drive params
    push es
    mov ah, 0x08
    int 0x13
    jc floppy_error
    pop es

    and cl, 0x3F
    xor ch, ch
    mov [bdb_sectors_per_track], cx ; sector count

    inc dh
    mov [bdb_heads], dh             ; head count

    ; read FAT root directory
    mov ax, [bdb_sectors_per_fat]   ; compute first FAT sector
    mov bl, [bdb_fat_count]
    xor bh, bh
    mul bx                          ; ax = (fats * sectors_per_fat)
    add ax, [bdb_reserved_sectors]  ; ax = LBA of root directory
    push ax

    ; compute size of root directory = (32 * number_of_entries) / bytes_per_sector
    mov ax, [bdb_dir_entries_count]
    shl ax, 5                       ; ax *= 32
    xor dx, dx
    div word [bdb_bytes_per_sector] ; number of sectors we need to read

    test dx, dx
    jz .root_dir_after
    inc ax

.root_dir_after:
    ; read root directory
    mov cl, al                      ; number
    pop ax                          ; LBA of root directory
    mov dl, [ebr_drive_number]
    mov bx, buffer
    call disk_read

    ; search for stage2.bin
    xor bx, bx
    mov di, buffer

.search_stage2:
    mov si, stage2_name
    mov cx, 11
    push di
    repe cmpsb
    pop di
    je .found_stage2

    add di, 32
    inc bx
    cmp bx, [bdb_dir_entries_count]
    jl .search_stage2

    jmp stage2_not_found_error

.found_stage2:
    mov ax, [di + 26] ; LBA
    mov [stage2_cluster], ax

    ; load FAT from disk into memory
    mov ax, [bdb_reserved_sectors]
    mov bx, buffer
    mov cl, [bdb_sectors_per_fat]
    mov dl, [ebr_drive_number]
    call disk_read

    ; read stage2 and process FAT
    mov bx, stage2_LOAD_SEGMENT
    mov es, bx
    mov bx, stage2_LOAD_OFFSET

.load_stage2_loop:
    ; Read next cluster
    mov ax, [stage2_cluster]
    
    ; not nice :( hardcoded value
    add ax, 31                          ; first cluster = (stage2_cluster - 2) * sectors_per_cluster + start_sector
                                        ; start sector = reserved + fats + root directory size = 1 + 18 + 134 = 33
    mov cl, 1
    mov dl, [ebr_drive_number]
    call disk_read

    add bx, [bdb_bytes_per_sector]

    ; compute location of next cluster
    mov ax, [stage2_cluster]
    mov cx, 3
    mul cx
    mov cx, 2
    div cx                              ; ax = index of entry in FAT, dx = cluster mod 2

    mov si, buffer
    add si, ax
    mov ax, [ds:si]                     ; read entry from FAT table at index ax

    or dx, dx
    jz .even

.odd:
    shr ax, 4
    jmp .next_cluster_after

.even:
    and ax, 0x0FFF

.next_cluster_after:
    cmp ax, 0x0FF8                      ; end of chain
    jae .read_finish

    mov [stage2_cluster], ax
    jmp .load_stage2_loop

.read_finish:
    ; jump to our stage2
    mov dl, [ebr_drive_number]          ; boot device in dl

    mov ax, stage2_LOAD_SEGMENT         ; set segment registers
    mov ds, ax
    mov es, ax

    jmp stage2_LOAD_SEGMENT:stage2_LOAD_OFFSET

    jmp wait_key                        ; should never happen

    cli                                 ; disable interrupts, this way CPU can't get out of "halt" state
    hlt

.halt:
    cli
    hlt

; ========= functions =======

; error handlers
floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key

stage2_not_found_error:
    mov si, msg_stage2_not_found
    call puts
    jmp wait_key

wait_key:
    mov si, msg_wait
    call puts

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
    push bx

    mov ah, 0x0E    ; set video mode for int 0x10
    xor bh, bh       ; set page mode = 0

.loop:
    lodsb       ; load next character in al
    or al, al   ; verfiy if next is null?
    jz .done

    int 0x10

    jmp .loop

.done:
    pop bx
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

    xor dx, dx ; dx = 0
    div word [bdb_sectors_per_track] ; ax = lba / sectors_per_track, 
                                     ; dx = lba % sectors_per_track
    inc dx                           ; dx = lba % sectors_per_track + 1 (we now got the sector number)
    mov cx, dx

    xor dx, dx ; (I FORGOT THIS, and it was the reason for a long time that it didn't work)
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
    push ax                             ; save registers we will modify
    push bx
    push cx
    push dx
    push di

    push cx                             ; temporarily save CL (number of sectors to read)
    call lba_to_chs                     ; compute CHS
    pop ax                              ; AL = number of sectors to read
    
    mov ah, 02h
    mov di, 3                           ; retry count

.retry:
    pusha                               ; save all registers, we don't know what bios modifies
    stc                                 ; set carry flag, some BIOS'es don't set it
    int 13h                             ; carry flag cleared = success
    jnc .done                           ; jump if carry not set

    ; read failed
    popa
    call disk_reset

    dec di
    test di, di
    jnz .retry

.fail:
    ; all attempts are exhausted
    jmp floppy_error

.done:
    popa

    pop di
    pop dx
    pop cx
    pop bx
    pop ax                             ; restore registers modified
    ret


;
; Resets the disk controller
; Params:
;   - dl: drive number
disk_reset:
    pusha
    mov ah, 0
    stc
    int 0x13
    jc floppy_error
    popa
    ret

; ========= data =======
msg_wait: db "Press key to restart...", NL, 0
msg_read_failed: db "Failed to read", NL, 0
msg_stage2_not_found: db "STAGE2.BIN not found", NL, 0
stage2_name: db "STAGE2  BIN"
stage2_cluster: dw 0

times 510-($-$$) db 0
dw 0xAA55

buffer:
