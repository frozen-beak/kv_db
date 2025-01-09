global  _start

section .bss
    sock       resq 1    ; server socket fd
    client     resq 1    ; client socket fd
    rbuf       resb 4100 ; read buffer (4 + k_max_msg + 1)
    wbuf       resb 4100 ; write buffer (4 + reply length)
    bytes_read resq 1    ; bytes read from the client

section .data
    sockaddr_in db 2, 0 ; sin_family (AF_INET)
                dw 0xd204          ; sin_port (1234 in big-endian)
                dd 0               ; sin_addr (0.0.0.0 -> INADDR_ANY)
                dd 0,0,0,0,0,0,0,0 ; sin_zero (padding)

    reply     db  "world", 0
    reply_len equ $ - reply

    msg_eof     db  "EOF", 0
    msg_eof_len equ $ - msg_eof

    msg_read_err     db  "read() error", 0
    msg_read_err_len equ $ - msg_read_err

    msg_too_long     db  "too long", 0
    msg_too_long_len equ $ - msg_too_long

    reuse_addr_val dd 1 ; value for SO_REUSEADDR

section .text
_start:
    ; create a socket
    mov rax, 41  ; socket syscall
    mov rdi, 2   ; AF_INET
    mov rsi, 1   ; SOCK_STREAM
    xor rdx, rdx ; protocol (0)
    syscall

    ; check for socket errors (rax < 0)
    test rax, rax
    js   socket_fail

    ; save the socket fd
    mov [sock], rax

    ; set options for socket (SO_REUSEADDR)
    mov rax, 54               ; setsockopt syscall
    mov rdi, [sock]
    mov rsi, 1                ; SOL_SOCKET
    mov rdx, 2                ; SO_REUSEADDR
    lea r10, [reuse_addr_val]
    mov r8,  4                ; sizeof(val)
    syscall

    ; bind socket
    mov rax, 49            ; bind syscall
    mov rdi, [sock]
    lea rsi, [sockaddr_in]
    mov rdx, 16            ; sizeof (sockaddr_in)
    syscall
    
    ; check for bind errors (rax < 0)
    test rax, rax
    js   bind_fail

close_client:
    ; close client socket
    mov rax, 3        ; close syscall
    mov rdi, [client]
    syscall

    ; accept next connection
    jmp accept_loop

accept_loop:
    ; accept connection
    mov rax, 43     ; accept syscall
    mov rdi, [sock]
    xor rsi, rsi    ; client sockaddr (NULL / 0)
    xor rdx, rdx    ; sockaddr length (NULL / 0)
    syscall

    ; check for accept for errors (rax < 0)
    test rax, rax
    js   accept_loop ; retry on error

    ; store client socket fd
    mov [client], rax

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

read_error:
    ; log read error
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_read_err]
    mov rdx, msg_read_err_len
    syscall
    
    jmp close_client

too_long:
    ; log too long error
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_too_long]
    mov rdx, msg_too_long_len
    syscall

    jmp close_client

write_error:
    ; log write error
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_read_err]
    mov rdx, msg_read_err_len
    syscall

    jmp close_client

