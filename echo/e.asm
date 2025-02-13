; event‐based TCP echo server using poll for concurrency
; (x86_64 Linux / NASM)

global _start

%define SYS_READ           0
%define SYS_WRITE          1
%define SYS_CLOSE          3
%define SYS_SOCKET         41
%define SYS_ACCEPT         43
%define SYS_BIND           49
%define SYS_SETSOCKETOPT   54
%define SYS_LISTEN         50
%define SYS_EXIT           60
%define SYS_POLL           7
%define SYS_FCNTL          72

; socket options constants
%define SOL_SOCKET         1
%define SO_REUSEADDR       2

; poll(2) events (the pollfd struct has: int fd, short events, short revents)
%define POLLIN             0x0001

; fcntl flags (F_SETFL is used to set the file descriptor flags)
%define F_SETFL            4
%define O_NONBLOCK         0x800   ; Linux’s nonblocking flag

; maximum number of file descriptors (listening socket + clients)
%define MAX_EVENTS         128

section .bss
    sock       resq 1        ; our listening socket
    ; pollfds array: each entry is 8 bytes:
    ;   4 bytes: file descriptor (int)
    ;   2 bytes: events (short)
    ;   2 bytes: revents (short)
    pollfds    resb MAX_EVENTS * 8
    nfds       resq 1        ; number of valid pollfd entries currently in use
    buffer     resb 1024     ; temporary data buffer

section .data
    reuseaddr_val  dd 1     ; for setsockopt()

    ; sockaddr_in structure (16 bytes) for IPv4 port 6969 (0x391B) and INADDR_ANY
    sockaddr_in:
        dw 2                ; AF_INET
        dw 0x391B           ; port 6969 (big-endian)
        dd 0                ; sin_addr (INADDR_ANY)
        dq 0                ; padding

section .text
_start:
    ; --- create listening socket ---
    ; socket(AF_INET, SOCK_STREAM, 0)
    mov     rax, SYS_SOCKET
    mov     rdi, 2           ; AF_INET
    mov     rsi, 1           ; SOCK_STREAM
    xor     rdx, rdx         ; protocol 0
    syscall
    test    rax, rax
    js      exit
    mov     [sock], rax

    ; --- set socket options ---
    ; setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseaddr_val, 4)
    mov     rax, SYS_SETSOCKETOPT
    mov     rdi, [sock]
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     r10, [reuseaddr_val]
    mov     r8, 4
    syscall
    test    rax, rax
    js      exit

    ; --- bind the socket ---
    ; bind(sock, sockaddr_in, 16)
    mov     rax, SYS_BIND
    mov     rdi, [sock]
    lea     rsi, [sockaddr_in]
    mov     rdx, 16
    syscall
    test    rax, rax
    js      exit

    ; --- listen on the socket ---
    mov     rax, SYS_LISTEN
    mov     rdi, [sock]
    mov     rsi, 128
    syscall
    cmp     rax, 0
    jl      exit

    ; --- set the listening socket to nonblocking ---
    mov     rax, SYS_FCNTL
    mov     rdi, [sock]
    mov     rsi, F_SETFL
    mov     rdx, O_NONBLOCK
    syscall

    ; --- initialize our pollfds array ---
    ; Put the listening socket at index 0.
    ; pollfds[0].fd = sock, .events = POLLIN, .revents = 0.
    mov     eax, dword [sock]
    mov     dword [pollfds], eax       ; fd
    mov     word  [pollfds+4], POLLIN    ; events
    mov     word  [pollfds+6], 0         ; revents
    mov     qword [nfds], 1             ; nfds = 1

poll_loop:
    ; --- call poll ---
    ; poll(pollfds, nfds, timeout=-1)
    mov     rax, SYS_POLL
    lea     rdi, [pollfds]
    mov     rsi, qword [nfds]
    mov     rdx, -1
    syscall
    test    rax, rax
    js      exit

    ; --- check if the listening socket has an event ---
    movzx   eax, word [pollfds+6]   ; revents of pollfds[0]
    test    eax, POLLIN
    jz      skip_accept
    ; Accept new connection: accept(sock, NULL, NULL)
    mov     rax, SYS_ACCEPT
    mov     rdi, [sock]
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    cmp     rax, 0
    js      skip_accept
    ; Save new client fd in r10
    mov     r10, rax
    ; Set the new client socket to nonblocking.
    mov     rax, SYS_FCNTL
    mov     rdi, r10
    mov     rsi, F_SETFL
    mov     rdx, O_NONBLOCK
    syscall
    ; Add new client socket to pollfds array (if room)
    mov     rbx, qword [nfds]         ; current count
    cmp     rbx, MAX_EVENTS
    jae     .close_client_new         ; if too many, close new client
    ; Calculate address: pollfds + (rbx * 8)
    mov     r8, rbx
    shl     r8, 3
    lea     r9, [pollfds + r8]
    mov     dword [r9], r10d           ; new client fd
    mov     word  [r9+4], POLLIN       ; events = POLLIN
    mov     word  [r9+6], 0            ; revents = 0
    inc     qword [nfds]
    jmp     skip_accept

.close_client_new:
    mov     rax, SYS_CLOSE
    mov     rdi, r10
    syscall

skip_accept:
    ; --- iterate over client sockets (pollfds indices 1..nfds-1) ---
    mov     rbx, 1

client_loop:
    mov     rax, qword [nfds]    ; read current number of entries
    cmp     rbx, rax
    jge     poll_loop_end

    ; Calculate address of pollfds[rbx]: offset = rbx * 8 (each pollfd is 8 bytes)
    mov     r8, rbx
    shl     r8, 3
    lea     r9, [pollfds + r8]

    ; Check if this client has an event (revents & POLLIN)
    movzx   eax, word [r9+6]
    test    eax, POLLIN
    jz      next_client

    ; Read from client socket: read(fd, buffer, 1024)
    mov     rax, SYS_READ
    mov     edi, dword [r9]       ; client fd (using dword because pollfd.fd is 32-bit)
    lea     rsi, [buffer]
    mov     edx, 1024
    syscall
    cmp     rax, 1                ; if ≤0 then error/EOF
    jle     .remove_client

    ; Echo back: write(fd, buffer, <number of bytes read>)
    mov     rdx, rax              ; number of bytes to echo
    mov     rax, SYS_WRITE
    mov     edi, dword [r9]       ; client fd
    lea     rsi, [buffer]
    syscall
    jmp     next_client

.remove_client:
    ; Close and remove a client socket
    mov     rax, SYS_CLOSE
    mov     edi, dword [r9]       ; client fd
    syscall
    ; Remove this pollfd entry by replacing it with the last one.
    mov     r10, qword [nfds]
    dec     r10                 ; last index = nfds - 1
    cmp     rbx, r10
    je      .decrement_nf       ; if this is already the last entry, just decrement nfds
    mov     r11, r10
    shl     r11, 3
    lea     r12, [pollfds + r11]
    ; Copy the last pollfd entry into the current one
    mov     rax, qword [r12]
    mov     qword [r9], rax

.decrement_nf:
    mov     qword [nfds], r10    ; update nfds in memory
    ; Do not increment rbx here because a new entry has been copied into the current slot.
    jmp     client_loop_continue

next_client:
    inc     rbx

client_loop_continue:
    jmp     client_loop

poll_loop_end:
    jmp     poll_loop

exit:
    mov     rax, SYS_EXIT
    mov     rdi, 1
    syscall
