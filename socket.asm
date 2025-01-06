global  _start

section .bss
    sock resq 1

section .data
    sockaddr_in db 2, 0 ; sin_family (AF_INET)
                dw 0x1f90          ; sin_port (8080)
                dd 0               ; sin_addr (0.0.0.0 -> INADDR_ANY)
                db 0,0,0,0,0,0,0,0 ; sin_zero (padding)

section .text
_start:
    ; create a socket
    mov rax, 41  ; socket sys call number
    mov rdi, 2   ; AF_INET (IPv4)
    mov rsi, 1   ; SOCK_STREAM (TCP)
    xor rdx, rdx ; protocol(0)
    syscall

    ; check for socket errors (rax < 0)
    test rax, rax
    js   socket_fail

    ; save the socket fd
    mov [sock], rax

    ; bind socket
    mov rax, 49            ; bind syscall number
    mov rdi, [sock]        ; store the socket fd
    mov rsi, [sockaddr_in]
    mov rdx, 16            ; size of [sockaddr_in]
    syscall

    ; check for bind errors (rax < 0)
    test rax, rax
    js   bind_fail

    ; listen to socket
    mov rax, 50     ; listen syscall number
    mov rdi, [sock] ; fd of socket
    mov rsi, 1      ; max connection backlog allowed
    syscall

    ; check for listen errors (rax < 0)
    cmp rax, 0
    jl  listen_fail ; jump to err if (rax < 0)

    ; exit
    mov rax, 60
    xor rdi, rdi
    syscall

socket_fail:
    ; handle socket error
    mov rax, 60
    mov rdi, 1
    syscall

bind_fail:
    ; handle bind error
    mov rax, 60
    mov rdi, 2
    syscall

listen_fail:
    ; handle bind error
    mov rax, 60
    mov rdi, 2
    syscall