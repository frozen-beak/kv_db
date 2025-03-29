global _start

;===========================================================================
; Syscall numbers and constants
;===========================================================================
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

; Socket options & flags
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

;===========================================================================
; Data Section
;===========================================================================
section .data
    ; Value used for SO_REUSEADDR socket option
    reuseaddr_val: dd 1

    ; sockaddr_in structure for IPv4, port 1234 (0x04D2 -> network order 0xD204), INADDR_ANY
    ; Structure:
    ;   sa_family: 2 bytes (AF_INET = 2)
    ;   sin_port:  2 bytes (network order)
    ;   sin_addr:  4 bytes (0)
    ;   padding:   8 bytes (0)
    sockaddr_in:
         dw 2                 ; AF_INET
         dw 0xD204            ; Port 1234 in network order
         dd 0                 ; INADDR_ANY
         dq 0                 ; padding

;===========================================================================
; BSS Section – reserve memory for state
;===========================================================================
section .bss
    listen_fd   resq 1                   ; Listening socket file descriptor
    client_fds  resq 128                 ; Array to store up to 128 client fds (each a qword)
    pollfds     resb (130*8)             ; Pollfd array: one for listen + 128 for clients; each pollfd is 8 bytes
    buffer      resb 1024                ; I/O buffer for client data

;===========================================================================
; Code Section
;===========================================================================
section .text

;---------------------------------------------------------------------------
; _start
;  Entry point for the server.
;  Calls initialization functions then enters the main event loop.
;---------------------------------------------------------------------------
_start:
    call init_server        ; Setup listening socket and client structures
    call event_loop         ; Enter the main event loop (never returns)
    ; If we ever exit the loop, exit normally
    call exit_server

;---------------------------------------------------------------------------
; init_server
;  Initializes the server by:
;   - Creating the listening socket.
;   - Setting socket options.
;   - Binding to the desired address/port.
;   - Setting the socket to nonblocking.
;   - Starting to listen.
;   - Initializing the client_fds array.
;  Parameters: none
;  Returns: none (exits on error)
;---------------------------------------------------------------------------
init_server:
    call create_socket          ; returns listening socket in rax
    mov [listen_fd], rax

    call set_socket_options     ; use listen_fd, exit on error

    call bind_socket            ; use listen_fd, exit on error

    call set_nonblocking        ; sets listen_fd to nonblocking mode

    call listen_socket          ; begins listening on listen_fd

    call init_client_fds        ; initialize the client_fds array with -1

    ret

;---------------------------------------------------------------------------
; create_socket
;  Creates an IPv4, stream (TCP) socket.
;  Parameters: none
;  Returns:
;    rax: socket file descriptor (>0) on success.
;         Exits the program on error.
;---------------------------------------------------------------------------
create_socket:
    mov rax, SYS_SOCKET
    mov rdi, 2            ; AF_INET
    mov rsi, 1            ; SOCK_STREAM
    xor rdx, rdx          ; Protocol 0
    syscall
    ; Check for error (negative value)
    test rax, rax
    js exit_error
    ret

;---------------------------------------------------------------------------
; set_socket_options
;  Sets the SO_REUSEADDR option on the listening socket.
;  Uses the global 'reuseaddr_val'.
;  Parameters: none (operates on [listen_fd])
;  Returns: none (exits the program on error)
;---------------------------------------------------------------------------
set_socket_options:
    mov rax, SYS_SETSOCKOPT
    mov rdi, [listen_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    lea r10, [reuseaddr_val]
    mov r8, 4               ; Length of the option value
    syscall
    test rax, rax
    js exit_error
    ret

;---------------------------------------------------------------------------
; bind_socket
;  Binds the listening socket to the address and port defined in 'sockaddr_in'.
;  Parameters: none (operates on [listen_fd])
;  Returns: none (exits the program on error)
;---------------------------------------------------------------------------
bind_socket:
    mov rax, SYS_BIND
    mov rdi, [listen_fd]
    lea rsi, [sockaddr_in]
    mov rdx, 16             ; sizeof(sockaddr_in)
    syscall
    test rax, rax
    jnz exit_error
    ret

;---------------------------------------------------------------------------
; set_nonblocking
;  Sets a given file descriptor (here, listen_fd or a client fd) into nonblocking mode.
;  Assumes fd is in rdi.
;  Parameters:
;    rdi - file descriptor to modify.
;  Returns: none
;---------------------------------------------------------------------------
set_nonblocking:
    ; Get current flags: fcntl(fd, F_GETFL, 0)
    mov rax, SYS_FCNTL
    ; rdi is already set
    mov rsi, F_GETFL
    xor rdx, rdx
    syscall
    ; Save current flags in rbx and add O_NONBLOCK
    mov rbx, rax
    or rbx, O_NONBLOCK
    ; Set new flags: fcntl(fd, F_SETFL, new_flags)
    mov rax, SYS_FCNTL
    mov rsi, F_SETFL
    mov rdx, rbx
    syscall
    ret

;---------------------------------------------------------------------------
; listen_socket
;  Puts the socket into listening mode.
;  Parameters: none (operates on [listen_fd])
;  Returns: none (exits the program on error)
;---------------------------------------------------------------------------
listen_socket:
    mov rax, SYS_LISTEN
    mov rdi, [listen_fd]
    mov rsi, 128          ; backlog
    syscall
    test rax, rax
    jnz exit_error
    ret

;---------------------------------------------------------------------------
; init_client_fds
;  Initializes the client file descriptor array to -1 to indicate empty slots.
;  Parameters: none
;  Returns: none
;---------------------------------------------------------------------------
init_client_fds:
    mov rcx, 128          ; number of client slots
    lea rdi, [client_fds]
.init_loop:
    mov qword [rdi], -1   ; mark slot as empty
    add rdi, 8
    loop .init_loop
    ret

;---------------------------------------------------------------------------
; event_loop
;  Main loop: prepares pollfd array, accepts new clients, and processes client events.
;  Parameters: none
;  Returns: none (runs indefinitely)
;---------------------------------------------------------------------------
event_loop:
.loop_start:
    call build_pollfds    ; builds pollfds array from listen_fd and active clients; returns count in r12

    ; Poll indefinitely for an event.
    mov rax, SYS_POLL
    lea rdi, [pollfds]
    mov rsi, r12         ; number of pollfd entries
    mov rdx, -1          ; timeout = infinite
    syscall
    cmp rax, 0
    jl .loop_start       ; on error, restart loop

    ; Check for new connections on listening socket (pollfds[0]).
    call check_listen_socket

    ; Process events for each client socket.
    call process_client_events

    jmp .loop_start

;---------------------------------------------------------------------------
; build_pollfds
;  Builds the pollfds array with the listening socket and all active client sockets.
;  Returns:
;    r12 - total number of pollfd entries built.
;  Modifies:
;    pollfds memory block.
;---------------------------------------------------------------------------
build_pollfds:
    ; First pollfd entry: listening socket.
    lea rdi, [pollfds]
    mov eax, dword [listen_fd]
    mov [rdi], eax              ; pollfds[0].fd = listen_fd
    mov word [rdi+4], POLLIN     ; pollfds[0].events = POLLIN (accept new connections)
    mov word [rdi+6], 0          ; clear revents

    mov r12, 1                 ; Start count at 1

    ; For each client in client_fds, if slot != -1 then add to pollfds.
    xor r13, r13               ; index = 0
.client_loop:
    cmp r13, 128
    jge .build_done
    mov rax, [client_fds + r13*8]
    cmp rax, -1
    je .next_client
    ; Add pollfd for active client.
    lea rbx, [pollfds + r12*8]
    mov dword [rbx], eax       ; client fd (lower 32-bits)
    mov word [rbx+4], POLLIN   ; monitor for read events
    mov word [rbx+6], 0        ; clear revents
    inc r12
.next_client:
    inc r13
    jmp .client_loop
.build_done:
    ret

;---------------------------------------------------------------------------
; check_listen_socket
;  Checks if the listening socket has an event and accepts a new connection.
;  Parameters: none
;  Returns: none
;---------------------------------------------------------------------------
check_listen_socket:
    lea rdi, [pollfds]
    movzx eax, word [rdi+6]    ; get revents from listening socket pollfd
    test eax, POLLIN
    jz .skip_accept

    ; Accept a new connection.
    call accept_client
.skip_accept:
    ret

;---------------------------------------------------------------------------
; accept_client
;  Accepts an incoming connection on listen_fd and sets it nonblocking.
;  If no free slot in client_fds is found, the connection is closed.
;  Parameters: none
;  Returns: none
;---------------------------------------------------------------------------
accept_client:
    mov rax, SYS_ACCEPT
    mov rdi, [listen_fd]
    xor rsi, rsi             ; not storing client address
    xor rdx, rdx
    syscall
    test rax, rax
    js .accept_fail          ; error, do nothing
    mov r14, rax             ; r14 holds the new client fd

    ; Set new client socket to nonblocking.
    mov rdi, r14
    call set_nonblocking

    ; Add new client fd to first free slot in client_fds.
    xor r13, r13             ; index = 0
.find_slot:
    cmp r13, 128
    jge .no_slot             ; no free slot available
    mov rax, [client_fds + r13*8]
    cmp rax, -1
    je .store_client
    inc r13
    jmp .find_slot
.no_slot:
    ; No free slot; close connection to prevent fd leak.
    mov rax, SYS_CLOSE
    mov rdi, r14
    syscall
    jmp .done_accept
.store_client:
    mov [client_fds + r13*8], r14
.done_accept:
    ret
.accept_fail:
    ret

;---------------------------------------------------------------------------
; process_client_events
;  Processes all client pollfd entries and handles read/write.
;  Parameters: none
;  Returns: none
;---------------------------------------------------------------------------
process_client_events:
    ; r12 holds total pollfds count; client entries start at index 1.
    mov r15, 1                ; client pollfd index counter
.process_loop:
    cmp r15, r12
    jge .proc_done
    lea rdi, [pollfds + r15*8]
    movzx eax, word [rdi+6]   ; revents field for this client pollfd
    test eax, POLLIN
    jz .next_poll
    ; Get client fd from pollfd entry.
    mov eax, [rdi]            ; lower 32-bits is client fd
    mov ebx, eax              ; save client fd in ebx for further use

    ; Read from client: read(fd, buffer, 1024)
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [buffer]
    mov rdx, 1024
    syscall
    cmp rax, 0
    je .close_client         ; EOF: close connection
    js .check_eagain         ; error: check if it is EAGAIN

    ; rax > 0: echo the data back by writing.
    mov rcx, rax             ; number of bytes read
    mov rax, SYS_WRITE
    mov rdi, rbx
    lea rsi, [buffer]
    mov rdx, rcx
    syscall
    jmp .next_poll

.check_eagain:
    cmp rax, EAGAIN
    je .next_poll
.close_client:
    ; Close the client fd.
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    ; Remove client from client_fds array.
    call remove_client_fd
.next_poll:
    inc r15
    jmp .process_loop
.proc_done:
    ret

;---------------------------------------------------------------------------
; remove_client_fd
;  Removes a client fd from the client_fds array.
;  Expects: client fd in ebx.
;  Parameters: none (fd to remove is in ebx)
;  Returns: none
;---------------------------------------------------------------------------
remove_client_fd:
    xor r13, r13             ; index counter
.remove_loop:
    cmp r13, 128
    jge .remove_done
    mov rdx, [client_fds + r13*8]
    cmp rdx, rbx
    je .found_remove
    inc r13
    jmp .remove_loop
.found_remove:
    mov qword [client_fds + r13*8], -1
.remove_done:
    ret

;---------------------------------------------------------------------------
; exit_server
;  Exits the server cleanly.
;  Parameters: none
;  Returns: does not return.
;---------------------------------------------------------------------------
exit_server:
    mov rax, SYS_EXIT
    xor rdi, rdi           ; exit code 0
    syscall

;---------------------------------------------------------------------------
; exit_error
;  Exits the server with an error status.
;  Parameters: none
;  Returns: does not return.
;---------------------------------------------------------------------------
exit_error:
    mov rax, SYS_EXIT
    mov rdi, 1             ; exit code 1
    syscall
