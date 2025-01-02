global _start

section .data
    hello db "Hello, World"
    len equ $ - hello

section .text
_start:
    mov rax, 1
    mov rdi, 1
    mov rsi, hello
    mov rdx, len
    syscall

    mov rax, 60
    xor rdi, rdi        ; XOR with itself is 0, Compact way to exit(0)
    syscall
