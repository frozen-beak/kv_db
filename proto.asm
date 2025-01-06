global  _start

section .bss
    sock       resq 1    ; server socket fd
    client     resq 1    ; client socket fd
    rbuf       resb 4100 ; read buffer (4 + k_max_msg + 1)
    wbuf       resb 4100 ; write buffer (4 + reply length)
    bytes_read resq 1    ; bytes read from client

section .data
    sockaddr_in db 2, 0 ; sin_family (AF_INET)
                dw 0xd204          ; sin_port (1234 in big-endian)
                dd 0               ; sin_addr (0.0.0.0 -> INADDR_ANY)
                db 0,0,0,0,0,0,0,0 ; sin_zero (padding)

    reply     db  "world", 0
    reply_len equ $ - reply

    msg_eof      db "EOF", 0
    msg_read_err db "read() error", 0
    msg_too_long db "too long", 0

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

    ; set SO_REUSEADDR option
    mov rax, 54     ; setsockopt syscall
    mov rdi, [sock]
    mov rsi, 1      ; SOL_SOCKET
    mov rdx, 2      ; SO_REUSEADDR
    lea r10, [val]
    mov r8,  4      ; sizeof(val)
    syscall

    ; bind socket
    mov rax, 49            ; bind syscall
    mov rdi, [sock]
    lea rsi, [sockaddr_in]
    mov rdx, 16            ; sizeof(sockaddr_in)
    syscall

    ; check for bind errors (rax < 0)
    test rax, rax
    js   bind_fail

    ; listen to socket
    mov rax, 50     ; listen syscall
    mov rdi, [sock]
    mov rsi, 128    ; SOMAXCONN
    syscall

    ; check for listen errors (rax < 0)
    test rax, rax
    js   listen_fail

accept_loop:
    ; accept connection
    mov rax, 43     ; accept syscall
    mov rdi, [sock]
    xor rsi, rsi    ; client sockaddr (NULL)
    xor rdx, rdx    ; sockaddr length (NULL)
    syscall

    ; check for accept errors (rax < 0)
    test rax, rax
    js   accept_loop ; retry on error

    ; store client socket fd
    mov [client], rax

request_loop:
    ; read 4-byte header
    mov rax, 0        ; read syscall
    mov rdi, [client]
    lea rsi, [rbuf]
    mov rdx, 4        ; read 4 bytes
    syscall

    ; check for read errors or EOF
    test rax, rax
    jz   close_client ; EOF
    js   read_error   ; read error

    ; extract message length (network byte order)
    mov   eax, [rbuf]
    bswap eax         ; convert from network byte order to host byte order

    ; save message length in rcx
    mov rcx, rax

    ; check if message is too long
    cmp ecx, 4096
    ja  too_long

    ; read message body
    mov rax, 0          ; read syscall
    mov rdi, [client]
    lea rsi, [rbuf + 4]
    mov rdx, rcx        ; message length
    syscall

    ; store the number of bytes read
    mov [bytes_read], rax

    ; null-terminate the message
    mov byte [rbuf + 4 + rax], 0

    ; log the message
    mov rax, 1            ; write syscall
    mov rdi, 1            ; stdout
    lea rsi, [rbuf + 4]
    mov rdx, [bytes_read] ; message length
    syscall

    ; prepare reply
    mov       eax,    reply_len
    bswap     eax                ; convert to network byte order
    mov       [wbuf], eax        ; write length header
    lea       rsi,    [reply]
    lea       rdi,    [wbuf + 4]
    mov       rcx,    reply_len
    rep movsb                    ; copy reply to write buffer

    ; send reply
    mov rax, 1             ; write syscall
    mov rdi, [client]
    lea rsi, [wbuf]
    mov rdx, 4 + reply_len
    syscall

    ; check for write errors
    test rax, rax
    js   write_error

    ; repeat for next request
    jmp request_loop

close_client:
    ; close client socket
    mov rax, 3        ; close syscall
    mov rdi, [client]
    syscall

    ; accept next connection
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

read_error:
    ; log read error
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_read_err]
    mov rdx, 13
    syscall
    jmp close_client

too_long:
    ; log too long error
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_too_long]
    mov rdx, 9
    syscall
    jmp close_client

write_error:
    ; log write error
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_read_err]
    mov rdx, 13
    syscall
    jmp close_client

section .data
    val dd 1 ; value for SO_REUSEADDR