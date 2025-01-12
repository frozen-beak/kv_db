; Define constants
%define TABLE_SIZE 16                 ; Must be a power of two
%define EMPTY_SLOT 0xFFFFFFFFFFFFFFFF ; Marker for empty slots
%define DELETED_SLOT 0xFFFFFFFFFFFFFFFE ; Marker for deleted slots

; Declare the data section
section .data
    hash_table_keys times TABLE_SIZE dq EMPTY_SLOT ; Initialize keys
    hash_table_values times TABLE_SIZE dq 0        ; Initialize values

; Declare the code section
section .text
    global _start

_start:
    ; Insert key-value pairs
    mov rax, 5
    mov rbx, 100
    call insert_hash

    mov rax, 21
    mov rbx, 200
    call insert_hash

    mov rax, 9
    mov rbx, 150
    call insert_hash

    ; Lookup a key
    mov rax, 21
    call lookup_hash
    ; The value will be in RCX if found

    ; Delete a key
    mov rax, 5
    call delete_hash

    ; Exit the program
    mov eax, 60         ; sys_exit
    xor edi, edi
    syscall

; Hash function: index = key % TABLE_SIZE
hash_function:
    mov rcx, TABLE_SIZE
    dec rcx              ; TABLE_SIZE is a power of two, so TABLE_SIZE - 1 is all 1 bits
    and rax, rcx         ; index = key & (TABLE_SIZE - 1)
    ret

; Insert function
insert_hash:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi
    push rbx
    push rax            ; Save key
    push rcx
    push rdx

    mov rsi, rax        ; Save key
    mov rdi, rbx        ; Save value

    call hash_function
    mov rbx, rax        ; rbx = index

.insert_loop:
    mov rax, qword [hash_table_keys + rbx*8]
    cmp rax, EMPTY_SLOT
    je .insert_found_empty
    cmp rax, rsi
    je .insert_found_key
    inc rbx
    and rbx, (TABLE_SIZE - 1) ; Wrap around using bitwise AND
    jmp .insert_loop

.insert_found_empty:
    mov qword [hash_table_keys + rbx*8], rsi
    mov qword [hash_table_values + rbx*8], rdi
    jmp .insert_exit

.insert_found_key:
    mov qword [hash_table_values + rbx*8], rdi
    ; Key already exists, update value

.insert_exit:
    pop rdx
    pop rcx
    pop rax
    pop rbx
    pop rdi
    pop rsi
    pop rbp
    ret

; Lookup function
lookup_hash:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi
    push rbx
    push rax            ; Save key
    push rcx
    push rdx

    mov rsi, rax        ; Save key

    call hash_function
    mov rbx, rax        ; rbx = index

.lookup_loop:
    mov rax, qword [hash_table_keys + rbx*8]
    cmp rax, EMPTY_SLOT
    je .lookup_not_found
    cmp rax, rsi
    je .lookup_found
    inc rbx
    and rbx, (TABLE_SIZE - 1) ; Wrap around using bitwise AND
    jmp .lookup_loop

.lookup_found:
    mov rcx, qword [hash_table_values + rbx*8]
    jmp .lookup_exit

.lookup_not_found:
    xor rcx, rcx        ; Set RCX to 0 if not found

.lookup_exit:
    pop rdx
    pop rcx
    pop rax
    pop rbx
    pop rdi
    pop rsi
    pop rbp
    ret

; Delete function
delete_hash:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi
    push rbx
    push rax            ; Save key
    push rcx
    push rdx

    mov rsi, rax        ; Save key

    call hash_function
    mov rbx, rax        ; rbx = index

.delete_loop:
    mov rax, qword [hash_table_keys + rbx*8]
    cmp rax, EMPTY_SLOT
    je .delete_not_found
    cmp rax, rsi
    je .delete_found
    inc rbx
    and rbx, (TABLE_SIZE - 1) ; Wrap around using bitwise AND
    jmp .delete_loop

.delete_found:
    mov qword [hash_table_keys + rbx*8], DELETED_SLOT
    mov qword [hash_table_values + rbx*8], 0

.delete_exit:
    pop rdx
    pop rcx
    pop rax
    pop rbx
    pop rdi
    pop rsi
    pop rbp
    ret