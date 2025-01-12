global  _start

section .bss
    sock   resq 1
    client resq 1

    r_buf resb 4100 ; Read buffer
    w_buf resb 4100 ; Write buffer

    bytes_read resq 1 ; bytes read from the client

section .data
    sockaddr_in db 2, 0 ; sin_family (AF_INET)
                dw 0xd204          ; sin_port (1234 in big-endian)
                dd 0               ; sin_addr (0.0.0.0 -> INADDR_ANY)
                db 0,0,0,0,0,0,0,0 ; sin_zero (padding)

    reply_ok     db  "200", 0
    reply_ok_len equ $ - reply_ok

    reply_not_found     db  "404", 0
    reply_not_found_len equ $ - reply_not_found

    msg_eof     db  "EOF", 0
    msg_eof_len equ $ - msg_eof

    msg_too_long     db  "too long", 0
    msg_too_long_len equ $ - msg_too_long

    client_read_error     db  "read() error", 0
    client_read_error_len equ $ - client_read_error

    client_write_error     db  "write() error", 0
    client_write_error_len equ $ - client_write_error

    ; this indicates a boolean value, but the function in C
    ; requires a pointer to an int, which is 4 bytes
    value dd 1 ; value for SO_REUSEADDR

    set_cmd db "set", 0
    get_cmd db "get", 0
    del_cmd db "del", 0

section .text
_start:
    ; create a socket
    mov rax, 41  ; socket syscall
    mov rdi, 2   ; AF_INET
    mov rsi, 1   ; SOCK_STREAM
    xor rdx, rdx ; protocol (0)
    syscall

    ; check for socket errors (rax < 0)
    ; cause rax should store fd of the socket
    test rax, rax
    js   socket_fail

    ; save the socket fd
    mov [sock], rax

    ; set socket options
    mov rax, 54      ; setsockopt syscall
    mov rdi, [sock]  ; socket fd
    mov rsi, 1       ; SOL_SOCKET
    mov rdx, 2       ; SO_REUSEADDR
    lea r10, [value] ; load addr of [value]
    mov r8,  4       ; sizeof(value)
    syscall 

    ; bind socket
    mov rax, 49            ; bind syscall
    mov rdi, [sock]
    lea rsi, [sockaddr_in] ; pointer to sockaddr struct
    mov rdx, 16            ; sizeof(sockaddr_in)
    syscall

    ; check for bind errors (rax < 0)
    test rax, rax
    js   bind_fail

    ; listen to the socket
    mov rax, 50     ; listen syscall
    mov rdi, [sock]
    mov rsi, 128    ; SOMAXCONN
    syscall

    ; check for listen errors (rax < 0)
    test rax, rax
    js   listen_fail

accept_loop:
    ; accept connections
    mov rax, 43     ; accept syscall
    mov rdi, [sock]
    xor rsi, rsi    ; client sockaddr (NULL)
    xor rdx, rdx    ; sockaddr length (NULL)
    syscall

    ; check for accept errors
    test rax, rax
    js   accept_loop ; retry on error

    ; store client socket fd
    mov [client], rax

request_loop:
    ; read 4-byte header
    mov rax, 0        ; read syscall
    mov rdi, [client] ; client fd
    lea rsi, [r_buf]
    mov rdx, 4        ; read only 4 bytes
    syscall

    ; check for read() errors or EOF (rax <= 0)
    ; [rax] holds number of bytes read
    test rax, rax
    jz   close_client ; EOF
    js   read_error   ; read error

    ; extract message length
    ; using [eax] 'cause we are dealing with only 
    ; 4-bytes of data
    mov   eax, [r_buf]
    bswap eax          ; convert from network byte order
                       ; (big-endian) to host (x86) byte
                       ; order (little-endian)

    ; save message length to rcx
    mov rcx, rax

    ; check if the message is too long
    cmp ecx, 4096
    ja  too_long_error

    ; read message body
    mov rax, 0           ; read syscall
    mov rdi, [client]    ; client fd
    lea rsi, [r_buf + 4] ; skip the first 4 bytes
    mov rdx, rcx         ; message length
    syscall

    ; check for read() errors
    test rax, rax
    jz   close_client ; EOF
    js   read_error   ; read error

    ; store the number of bytes read
    mov [bytes_read], rax

    ; null-terminate the message
    mov byte [r_buf + 4 + rax], 0

    ; log the message
    mov rax, 1
    mov rdi, 1
    lea rsi, [r_buf + 4]  ; skip the length bytes
    mov rdx, [bytes_read] ; message length
    syscall

    ; parse command
    lea  rsi, [r_buf + 4] ; point to the start of the cmd
    call parse_command

    ; send appropriate reply to client
    cmp rax, 1
    je  send_ok        ; 1 indicates valid command
    jne send_not_found ; 0 indicates invalid command

send_ok:
    mov   eax,     reply_ok_len
    bswap eax                   ; convert to network byte order (big-endian)
    mov   [w_buf], eax

    lea       rsi, [reply_ok]
    lea       rdi, [w_buf + 4]
    mov       rcx, reply_ok_len
    rep movsb                   ; copy 'reply_ok_len' bytes from [rsi] to [rdi]

    ; send reply
    mov rax, 1
    mov rdi, [client]
    lea rsi, [w_buf]
    mov rdx, 4 + reply_ok_len
    syscall

    ; check for write() errors (rax < 0)
    test rax, rax
    js   write_error

    ; repeat for next request
    jmp request_loop

send_not_found:
    mov   eax,     reply_not_found_len
    bswap eax                          ; convert to network byte order (big-endian)
    mov   [w_buf], eax

    lea       rsi, [reply_not_found]
    lea       rdi, [w_buf + 4]
    mov       rcx, reply_not_found_len
    rep movsb                          ; copy 'reply_not_found_len' bytes from [rsi] to [rdi]

    ; send reply
    mov rax, 1
    mov rdi, [client]
    lea rsi, [w_buf]
    mov rdx, 4 + reply_not_found_len
    syscall

    ; check for write() errors (rax < 0)
    test rax, rax
    js   write_error

    ; repeat for next request
    jmp request_loop

parse_command:
    ; rsi points to the start of the message
    ; only 'get', 'set' or 'del' commands should be allowed
    mov rdi, rsi
    mov rcx, 3
    lea rsi, [set_cmd]
    repe cmpsb
    je  valid_command

    mov rdi, rsi
    mov rcx, 3
    lea rsi, [get_cmd]
    repe cmpsb
    je  valid_command

    mov rdi, rsi
    mov rcx, 3
    lea rsi, [del_cmd]
    repe cmpsb
    je  valid_command

    mov rax, 0
    ret

valid_command:
    mov rax, 1
    ret

close_client:
    mov rax, 3        ; socket close syscall
    mov rdi, [client] ; client fd
    syscall

    jmp accept_loop

socket_fail:
    mov rax, 60
    mov rdi, 100
    syscall

bind_fail:
    mov rax, 60
    mov rdi, 2
    syscall

listen_fail:
    mov rax, 60
    mov rdi, 3
    syscall

too_long_error:
    ; log too long error
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_too_long]
    mov rdx, msg_too_long_len
    syscall

    jmp close_client

write_error:
    ; log write() error
    mov rax, 1
    mov rdi, 1
    lea rsi, [client_write_error]
    mov rdx, client_write_error_len
    syscall

    jmp close_client

read_error:
    ; log read() error
    mov rax, 1
    mov rdi, 1
    lea rsi, [client_read_error]
    mov rdx, client_read_error_len
    syscall

    jmp close_client
