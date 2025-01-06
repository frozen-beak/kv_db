global _start

struc sockaddr_in
    .sin_family resw 1
    .sin_port resw 1
    .sin_addr resd 1
    .sin_zero resb 8
endstruc

section .bss
    sock resw 2
    client resw 2
    echobuf resb 256
    read_count resw 2

section .data
    sock_err_msg db "Failed to init socket", 0x0a, 0
    sock_err_msg_len equ $ - sock_err_msg

    bind_err_msg db "Failed to bind socket to listening address", 0x0a, 0
    bind_err_msg_len equ $ - bind_err_msg

    listen_err_msg db "Failed to listen on socket", 0x0a, 0
    listen_err_msg_len equ $ - listen_err_msg

    accept_err_msg db "Could not accept connection attempt", 0x0a, 0
    acceot_err_msg_len equ $ - accept_err_msg

    response_msg db `HTTP/1.1 200 OK\nConnection: close\nContent-length: 0\n\n`
    response_msg_len equ $ - response_msg

    ;; sockaddr_in structure for the address, the listening socket binds to
    ;; pop_sa istruc sockaddr_in
    pop_sa istruc sockaddr_in
        at sockaddr_in.sin_family, dw 2     ; AF_INET
        at sockaddr_in.sin_port, dw 0xa1ed  ; port 60833
        at sockaddr_in.sin_addr, dd 0       ; localhost
        at sockaddr_in.sin_zero, dd 0, 0
    iend
    sockaddr_in_len equ $ - pop_sa

section .text

;; main entry point
_start:
    ;; Init listening and client sockets value to 0,
    ;; used for cleanup handeling
    mov word [sock], 0
    mov word [client], 0

    pop rax                     ; pop the arg count
    pop rax                     ; pop the program name
    pop rsi                     ; pop the only argument

    call string_to_int          ; convert the arg string to int

    ;; need to make the int to reverse byte order
    mov bl, ah
    mov bh, al
