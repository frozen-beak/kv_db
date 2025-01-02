%include "constants.inc"

global _start

section .data
    hello db "Hello, World", 0

section .bss
    hash resq 1                 ; Reserve space for hash (1 quadword, 8 bytes)

section .text
_start:
    ; Init hash to 5381
    mov rax, 5381
    mov [hash], rax

    ; Load addr of input
    mov rsi, hello

hash_loop:
    ; Load the next byte of the input
    movzx rax, byte [rsi]       ; Zero-extend the byte to 64-bit
    cmp al, 0                   ; Check if we reached the null terminator w/ lower 8 bits of rax
    je print_hash               ; Exit the loop at the end

    ; Update hash, hash = hash * 33 + char
    mov rbx, [hash]
    imul rbx, rbx, 33
    add rbx, rax
    mov [hash], rbx

    ; Advance to the next character
    inc rsi
    jmp hash_loop

print_hash:
    mov rax, WRITE
    mov rdi, WRITE
    mov rsi, hash
    mov rdx, 8
    syscall

    mov rax, EXIT
    xor rdi, rdi
    syscall
