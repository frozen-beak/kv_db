global _start

;----------------------------
; Syscall numbers and constants
;----------------------------
%define SYS_READ       0
%define SYS_WRITE      1
%define SYS_CLOSE      3
%define SYS_SOCKET     41
%define SYS_ACCEPT     43
%define SYS_BIND       49
%define SYS_LISTEN     50
%define SYS_SETSOCKOPT 54
%define SYS_EXIT       60
%define SYS_FCNTL      72
%define SYS_POLL       7

; socket options & flags
%define SOL_SOCKET     1
%define SO_REUSEADDR   2

; fcntl commands and flag
%define F_GETFL        3
%define F_SETFL        4
%define O_NONBLOCK     0x800

; poll event flags
%define POLLIN         0x001
%define POLLOUT        0x004
%define POLLERR        0x008

; errno value for EAGAIN (or EWOULDBLOCK)
%define EAGAIN         -11

;----------------------------
; Data Section
;----------------------------
section .data
    reuseaddr_val: dd 1

    ; sockaddr_in (16 bytes) for IPv4, port 1234, INADDR_ANY.
    ; Structure:
    ;   sa_family: 2 bytes (AF_INET = 2)
    ;   sin_port:  2 bytes (network order, port 1234 → 0x04D2 becomes 0xD204)
    ;   sin_addr:  4 bytes (0)
    ;   padding:   8 bytes (0)
    sockaddr_in:
         dw 2
         dw 0xD204
         dd 0
         dq 0

;----------------------------
; BSS Section – reserve memory for state
;----------------------------
section .bss
    listen_fd   resq 1                   ; listening socket fd
    client_fds  resq 128                 ; fixed array for up to 128 client fds (each slot holds a qword)
    pollfds     resb (130*8)             ; pollfd array: one for listen + up to 128 clients; each pollfd is 8 bytes
    buffer      resb 1024                ; temporary I/O buffer

;----------------------------
; Code Section
;----------------------------
section .text
_start:
    ; 1. Create the listening socket: socket(AF_INET, SOCK_STREAM, 0)
    mov rax, SYS_SOCKET
    mov rdi, 2            ; AF_INET
    mov rsi, 1            ; SOCK_STREAM
    xor rdx, rdx          ; protocol 0
    syscall
    test rax, rax
    js exit_error         ; error if rax is negative
    mov [listen_fd], rax

    ; 2. Set SO_REUSEADDR: setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &reuseaddr_val, 4)
    mov rax, SYS_SETSOCKOPT
    mov rdi, [listen_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    lea r10, [reuseaddr_val]
    mov r8, 4
    syscall
    test rax, rax
    js exit_error

    ; 3. Bind the socket: bind(listen_fd, sockaddr_in, 16)
    mov rax, SYS_BIND
    mov rdi, [listen_fd]
    lea rsi, [sockaddr_in]
    mov rdx, 16
    syscall
    test rax, rax
    jnz exit_error

    ; 4. Set the listening socket to nonblocking via fcntl
    ; fcntl(listen_fd, F_GETFL, 0)
    mov rax, SYS_FCNTL
    mov rdi, [listen_fd]
    mov rsi, F_GETFL
    xor rdx, rdx
    syscall
    mov rbx, rax         ; save current flags in rbx
    or rbx, O_NONBLOCK   ; add nonblocking flag
    ; fcntl(listen_fd, F_SETFL, rbx)
    mov rax, SYS_FCNTL
    mov rdi, [listen_fd]
    mov rsi, F_SETFL
    mov rdx, rbx
    syscall

    ; 5. Listen: listen(listen_fd, 128)
    mov rax, SYS_LISTEN
    mov rdi, [listen_fd]
    mov rsi, 128
    syscall
    test rax, rax
    jnz exit_error

    ; 6. Initialize the client_fds array to -1 (empty slot marker)
    mov rcx, 128
    lea rdi, [client_fds]
.init_loop:
    mov qword [rdi], -1
    add rdi, 8
    loop .init_loop

;----------------------------
; Main Event Loop
;----------------------------
event_loop:
    ; Build the pollfds array in memory.
    ; First entry: listening socket.
    lea rdi, [pollfds]
    ; pollfds[0].fd = listen_fd (store as 32–bit value)
    mov eax, dword [listen_fd]
    mov [rdi], eax
    ; pollfds[0].events = POLLIN (we always want to accept new connections)
    mov word [rdi+4], POLLIN
    ; pollfds[0].revents = 0
    mov word [rdi+6], 0

    ; Start count of pollfds entries at 1.
    mov r12, 1          ; r12 will hold the total number of pollfd entries

    ; For each client in client_fds (128 slots), if slot ≠ -1, add an entry.
    xor r13, r13        ; r13 = index counter (0..127)
client_loop:
    cmp r13, 128
    jge done_clients
    mov rax, [client_fds + r13*8]
    cmp rax, -1
    je next_client
    ; Add new pollfd entry at pollfds[r12]:
    lea rbx, [pollfds + r12*8]
    mov dword [rbx], eax        ; writes lower 32-bits of rax into pollfd entry
    mov word [rbx+4], POLLIN    ; monitor for read events
    mov word [rbx+6], 0         ; clear revents
    inc r12
next_client:
    inc r13
    jmp client_loop
done_clients:

    ; Call poll: poll(pollfds, nfds=r12, timeout=-1)
    mov rax, SYS_POLL
    lea rdi, [pollfds]
    mov rsi, r12
    mov rdx, -1
    syscall
    cmp rax, 0
    jl event_loop      ; on error (or EINTR), restart loop

    ;----------------------------
    ; 7. Check the listening socket (pollfds[0]) for new connections
    lea rdi, [pollfds]
    movzx eax, word [rdi+6]    ; revents for listening socket
    test eax, POLLIN
    jz skip_accept
    ; Accept a new connection
    mov rax, SYS_ACCEPT
    mov rdi, [listen_fd]
    xor rsi, rsi       ; not saving client addr
    xor rdx, rdx
    syscall
    test rax, rax
    js skip_accept   ; if error, skip
    ; rax now contains the new client fd; save it in r14.
    mov r14, rax
    ; Set the new client socket to nonblocking via fcntl.
    mov rdi, r14
    mov rax, SYS_FCNTL
    mov rsi, F_GETFL
    xor rdx, rdx
    syscall
    mov rbx, rax
    or rbx, O_NONBLOCK
    mov rax, SYS_FCNTL
    mov rdi, r14
    mov rsi, F_SETFL
    mov rdx, rbx
    syscall
    ; Add the new client fd to the first available slot in client_fds.
    xor r13, r13
find_slot:
    cmp r13, 128
    jge no_slot_found   ; no free slot available
    mov rax, [client_fds + r13*8]
    cmp rax, -1
    je store_client
    inc r13
    jmp find_slot

no_slot_found:
    ; If no slot available, close the accepted connection to avoid fd leak.
    mov rax, SYS_CLOSE
    mov rdi, r14
    syscall
    jmp skip_accept

store_client:
    mov [client_fds + r13*8], r14
skip_accept:

    ;----------------------------
    ; 8. Process events on client sockets (their pollfd entries are in pollfds[1..r12-1])
    mov r15, 1         ; r15 = index into pollfds for clients
client_poll_loop:
    cmp r15, r12
    jge event_loop    ; finished processing all client pollfds, loop back to poll
    lea rdi, [pollfds + r15*8]
    movzx eax, word [rdi+6]   ; revents field
    test eax, POLLIN
    jz next_poll
    ; Get client fd from pollfd entry
    mov eax, [rdi]    ; lower 32–bits hold client fd
    mov ebx, eax      ; save client fd in ebx
    ; Read from client: read(fd, buffer, 1024)
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [buffer]
    mov rdx, 1024
    syscall
    cmp rax, 0
    je close_client_fd    ; EOF: close connection
    js  check_eagain      ; error: check if EAGAIN
    ; rax > 0, echo data: write(fd, buffer, rax)
    mov rcx, rax         ; number of bytes read in rcx
    mov rax, SYS_WRITE
    mov rdi, rbx
    lea rsi, [buffer]
    mov rdx, rcx
    syscall
    jmp next_poll

check_eagain:
    ; if error is EAGAIN (-11), simply skip (poll will trigger again)
    cmp rax, EAGAIN
    je next_poll
    ; Otherwise, close client connection
close_client_fd:
    ; Close the client socket.
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    ; Remove the client from client_fds by searching for the matching fd.
    xor r13, r13
remove_client_loop:
    cmp r13, 128
    jge next_poll
    mov rdx, [client_fds + r13*8]
    cmp rdx, rbx
    je remove_client_found
    inc r13
    jmp remove_client_loop
remove_client_found:
    mov qword [client_fds + r13*8], -1
next_poll:
    inc r15
    jmp client_poll_loop

;----------------------------
; Error exit
;----------------------------
exit_error:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

;----------------------------
; Normal exit (never reached in this loop)
;----------------------------
exit:
    mov rax, SYS_EXIT
    mov rdi, 0
    syscall
