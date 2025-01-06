global  _start

section .bss
    sock resq 1

section .text
_start:
    ; create a socket
    mov rax, 41
    mov rdi, 2   ; AF_INET (IPv4)
    mov rsi, 1   ; SOCK_STREAM (TCP)
    xor rdx, rdx ; protocol(0)
    syscall

    ; check for errors (rax < 0)
    test rax, rax
    js   socket_fail

    ; save the socket fd
    mov [sock], rax

    ; exit
    mov rax, 60
    xor rdi, rdi
    syscall

socket_fail:
    ; error handling
    mov rax, 60
    mov rdi, 1
    syscall
