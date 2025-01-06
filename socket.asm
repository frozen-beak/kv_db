global  _start

section .bss
    sock       resq 1
    client     resq 1
    res_buffer resb 1024 ; result buffer (1Kib)

section .data
    sockaddr_in db 2, 0 ; sin_family (AF_INET)
                dw 0x901f          ; sin_port (8080 in big-endian)
                dd 0               ; sin_addr (0.0.0.0 -> INADDR_ANY)
                db 0,0,0,0,0,0,0,0 ; sin_zero (padding)

    accept_msg     db  "connection accepted!", 0
    accept_msg_len equ $ - accept_msg

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
    lea rsi, [sockaddr_in]
    mov rdx, 16            ; size of [sockaddr_in]
    syscall

    ; check for bind errors (rax < 0)
    test rax, rax
    js   bind_fail

    ; listen to socket
    mov rax, 50     ; listen syscall number
    mov rdi, [sock] ; fd of socket
    mov rsi, 5      ; max connection backlog allowed
    syscall

    ; check for listen errors (rax < 0)
    cmp rax, 0
    jl  listen_fail ; jump to err if (rax < 0)

    accept_loop:
        ; accept connection
        mov rax, 43     ; accept syscall number
        mov rdi, [sock] ; fd of socket
        xor rsi, rsi    ; pointer to client sockaddr (0)
        xor rdx, rdx    ; len of client sockaddr (0)
        syscall

        ; check for accept errors (rax < 0)
        cmp rax, 0
        jl  accept_fail ; goto error if (rax < 0)

        ; store client socket fd
        mov [client], rax

        ; log connection success
        mov rax, 1
        mov rdi, 1
        mov rsi, accept_msg
        mov rdx, accept_msg_len
        syscall

        ; receive data from client
        mov rax, 0            ; syscall number for read
        mov rdi, [client]     ; client socket fd
        lea rsi, [res_buffer] ; buffer to store received data
        mov rdx, 1024         ; buffer size
        syscall

        ; check for recv errors (rax <= 0)
        test rax, rax
        jle  close_client

        ; log received data (optional)
        mov rdx, rax          ; number of bytes received
        mov rax, 1            ; syscall number for write
        mov rdi, 1            ; stdout fd
        lea rsi, [res_buffer] ; buffer to write
        syscall

        ; send a response to the client
        mov rax, 1              ; syscall number for write
        mov rdi, [client]       ; client socket fd
        lea rsi, [accept_msg]   ; message to send
        mov rdx, accept_msg_len ; message length
        syscall

        ; close client socket
        close_client:
        mov rax, 3        ; syscall number for close
        mov rdi, [client] ; client socket fd
        syscall

        ; repeat the loop
        jmp accept_loop

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
    ; handle listen error
    mov rax, 60
    mov rdi, 3
    syscall

accept_fail:
    ; handle accept error
    mov rax, 60
    mov rdi, 4
    syscall