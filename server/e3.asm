; Assemble with:
;   nasm -f elf64 fixed_e3.asm -o fixed_e3.o && ld -o fixed_e3 fixed_e3.o

global _start

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

%define AF_INET        2
%define SOCK_STREAM    1

; Socket options and flags
%define SOL_SOCKET     1
%define SO_REUSEADDR   2

; fcntl commands and flags
%define F_GETFL        3
%define F_SETFL        4
%define O_NONBLOCK     0x800

; Poll events
%define POLLIN         0x001
%define POLLOUT        0x004
%define POLLERR        0x008
%define POLLHUP        0x010

; errno value for EAGAIN/EWOULDBLOCK
%define EAGAIN         11

; Client structure definition.
; Layout (total size = 2068 bytes):
;   0 - 7    : CLIENT_FD         (qword)    <-- FD (or -1 if free)
;   8 - 11   : CLIENT_IN_LEN     (dword)    <-- number of bytes in input buffer
;  12 -1035 : CLIENT_IN_BUF     (1024 bytes)
; 1036-1039 : CLIENT_OUT_LEN    (dword)    <-- number of bytes in output buffer
; 1040-1043 : CLIENT_OUT_SENT   (dword)    <-- number of bytes already sent
; 1044-2067 : CLIENT_OUT_BUF    (1024 bytes)
;
; Note: There is a deliberate 4-byte gap after CLIENT_IN_LEN.
%define MAX_CLIENTS    128
%define IN_BUF_SIZE    1024
%define OUT_BUF_SIZE   1024

CLIENT_FD         equ 0
CLIENT_IN_LEN     equ 8
CLIENT_IN_BUF     equ 12
CLIENT_OUT_LEN    equ CLIENT_IN_BUF + IN_BUF_SIZE    ; 12+1024 = 1036
CLIENT_OUT_SENT   equ CLIENT_OUT_LEN + 4             ; 1040
CLIENT_OUT_BUF    equ CLIENT_OUT_SENT + 4            ; 1044
CLIENT_STRUCT_SIZE equ CLIENT_OUT_BUF + OUT_BUF_SIZE ; 1044+1024 = 2068

; Pollfd definitions: one pollfd is 8 bytes.
%define NUM_POLLFD (MAX_CLIENTS + 1)
%define POLLFD_SIZE 8

section .data
reuseaddr_val:  dd 1

; sockaddr_in for IPv4, port 1234 (0xD204 in network order), INADDR_ANY.
sockaddr_in:
    dw 2                 ; AF_INET
    dw 0xD204            ; Port 1234 (network order)
    dd 0                 ; INADDR_ANY
    dq 0                 ; padding

section .bss
listen_fd:      resq 1
; Pollfd array: one for the listening socket plus one per client.
pollfds:        resb NUM_POLLFD * POLLFD_SIZE
; Parallel array to map pollfd entries to client structure pointers.
pollfd_client_map: resq NUM_POLLFD
; Array of client structures.
clients:        resb MAX_CLIENTS * CLIENT_STRUCT_SIZE

section .text

_start:
    call init_server
    call event_loop        ; infinite loop
    ; No exit_server call here as event_loop never returns.

;-----------------------------------------------------------
; init_server: Create and prepare the listening socket.
;-----------------------------------------------------------
init_server:
    call create_socket
    mov [listen_fd], rax
    call set_socket_options
    call bind_socket
    ; Set listening socket to nonblocking.
    mov rdi, [listen_fd]
    call set_nonblocking
    cmp rax, 0
    js exit_error
    call listen_socket
    call init_clients      ; mark all client slots free (FD = -1)
    ret

;-----------------------------------------------------------
; create_socket: Create an IPv4 stream socket.
;-----------------------------------------------------------
create_socket:
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    xor rdx, rdx
    syscall
    test rax, rax
    js exit_error
    ret

;-----------------------------------------------------------
; set_socket_options: Set SO_REUSEADDR.
;-----------------------------------------------------------
set_socket_options:
    mov rax, SYS_SETSOCKOPT
    mov rdi, [listen_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    lea r10, [reuseaddr_val]
    mov r8, 4
    syscall
    test rax, rax
    js exit_error
    ret

;-----------------------------------------------------------
; bind_socket: Bind the listening socket.
;-----------------------------------------------------------
bind_socket:
    mov rax, SYS_BIND
    mov rdi, [listen_fd]
    lea rsi, [sockaddr_in]
    mov rdx, 16
    syscall
    test rax, rax
    jnz exit_error
    ret

;-----------------------------------------------------------
; set_nonblocking: Set FD nonblocking.
; Returns 0 on success.
;-----------------------------------------------------------
set_nonblocking:
    push rbx
    mov rax, SYS_FCNTL
    mov rsi, F_GETFL
    xor rdx, rdx
    syscall
    mov rbx, rax
    or rbx, O_NONBLOCK
    mov rax, SYS_FCNTL
    mov rsi, F_SETFL
    mov rdx, rbx
    syscall
    test rax, rax
    js .fcntl_fail
    mov rax, 0
    pop rbx
    ret
.fcntl_fail:
    pop rbx
    ret

;-----------------------------------------------------------
; listen_socket: Put listening socket into listen mode.
;-----------------------------------------------------------
listen_socket:
    mov rax, SYS_LISTEN
    mov rdi, [listen_fd]
    mov rsi, 128
    syscall
    test rax, rax
    jnz exit_error
    ret

;-----------------------------------------------------------
; init_clients: Mark all client slots as free (FD = -1).
;-----------------------------------------------------------
init_clients:
    mov rcx, MAX_CLIENTS
    lea rdi, [clients]
.init_loop:
    mov qword [rdi + CLIENT_FD], -1
    add rdi, CLIENT_STRUCT_SIZE
    loop .init_loop
    ret

;-----------------------------------------------------------
; event_loop: Build pollfds, poll, and process events.
;-----------------------------------------------------------
event_loop:
.loop_start:
    call build_pollfds       ; r12 = number of pollfd entries built
    mov rax, SYS_POLL
    lea rdi, [pollfds]
    mov rsi, r12             ; number of pollfds
    mov rdx, -1              ; infinite timeout
    syscall
    cmp rax, 0
    jl .loop_start           ; on error, restart loop

    call check_listen_socket
    call process_client_events
    jmp .loop_start

;-----------------------------------------------------------
; build_pollfds: Create pollfds and map to client pointers.
; pollfds[0] is for the listening socket.
;-----------------------------------------------------------
build_pollfds:
    ; Pollfd 0 for listening socket.
    lea rdi, [pollfds]
    mov eax, dword [listen_fd]
    mov [rdi], eax
    mov word [rdi+4], POLLIN
    mov word [rdi+6], 0
    mov qword [pollfd_client_map], 0

    mov r12, 1              ; count starts at 1
    mov rcx, MAX_CLIENTS
    lea rsi, [clients]
.client_loop:
    cmp rcx, 0
    je .build_done
    mov rax, qword [rsi + CLIENT_FD]
    cmp rax, -1
    je .skip_client

    ; Set up pollfd for this client.
    mov r15, r12
    lea rdi, [pollfds + r15 * POLLFD_SIZE]
    ; Store FD.
    mov eax, dword [rsi + CLIENT_FD]
    mov [rdi], eax

    ; Initialize event mask to 0.
    mov word [rdi+4], 0

    ; Add POLLIN only if input buffer not full.
    mov eax, dword [rsi + CLIENT_IN_LEN]
    cmp eax, IN_BUF_SIZE
    jge .skip_pollin
    or word [rdi+4], POLLIN
.skip_pollin:
    ; Add POLLOUT if there is unsent data.
    mov eax, dword [rsi + CLIENT_OUT_LEN]
    mov edx, dword [rsi + CLIENT_OUT_SENT]
    cmp eax, edx
    jle .no_pollout
    or word [rdi+4], POLLOUT
.no_pollout:
    mov word [rdi+6], 0

    ; Save pointer to client structure.
    mov qword [pollfd_client_map + r12*8], rsi

    inc r12
.skip_client:
    add rsi, CLIENT_STRUCT_SIZE
    dec rcx
    jmp .client_loop
.build_done:
    ret

;-----------------------------------------------------------
; check_listen_socket: Accept new connection if listening socket is ready.
;-----------------------------------------------------------
check_listen_socket:
    lea rdi, [pollfds]
    movzx eax, word [rdi+6]
    test eax, POLLIN
    jz .done_check
    call accept_client
.done_check:
    ret

;-----------------------------------------------------------
; accept_client: Accept a new connection and store it in a free slot.
;-----------------------------------------------------------
accept_client:
    mov rax, SYS_ACCEPT
    mov rdi, [listen_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    test rax, rax
    js .accept_fail
    mov r14, rax             ; new client FD
    mov rdi, r14
    call set_nonblocking
    cmp rax, 0
    js .accept_fail_close_new_fd
    mov rcx, MAX_CLIENTS
    lea rsi, [clients]
.find_slot:
    cmp rcx, 0
    je .no_slot
    mov rax, qword [rsi + CLIENT_FD]
    cmp rax, -1
    je .store_client
    add rsi, CLIENT_STRUCT_SIZE
    dec rcx
    jmp .find_slot
.no_slot:
    mov rax, SYS_CLOSE
    mov rdi, r14
    syscall
    jmp .done_accept
.store_client:
    mov qword [rsi + CLIENT_FD], r14
    mov dword [rsi + CLIENT_IN_LEN], 0
    mov dword [rsi + CLIENT_OUT_LEN], 0
    mov dword [rsi + CLIENT_OUT_SENT], 0
.done_accept:
    ret
.accept_fail_close_new_fd:
    mov rax, SYS_CLOSE
    mov rdi, r14
    syscall
.accept_fail:
    ret

;-----------------------------------------------------------
; process_client_events: Process poll events using pollfd_client_map.
;-----------------------------------------------------------
process_client_events:
    mov rbx, r12           ; total pollfds count
    mov r15, 1             ; skip pollfd 0 (listening socket)
.proc_loop:
    cmp r15, rbx
    jge .proc_done
    lea rdi, [pollfds + r15*POLLFD_SIZE]
    movzx eax, word [rdi+6]   ; revents
    test eax, POLLERR
    jnz .close_client_event
    test eax, POLLHUP
    jnz .close_client_event
    cmp eax, 0
    je .next_poll
    ; Retrieve client pointer directly.
    mov rsi, [pollfd_client_map + r15*8]
    ; Process POLLIN.
    test eax, POLLIN
    jz .skip_read
    mov rdi, rsi
    call handle_read
.skip_read:
    ; Process POLLOUT.
    test eax, POLLOUT
    jz .skip_write
    mov rdi, rsi
    call handle_write
.skip_write:
.next_poll:
    inc r15
    jmp .proc_loop
.close_client_event:
    mov rsi, [pollfd_client_map + r15*8]
    mov edi, dword [rsi + CLIENT_FD]
    mov rax, SYS_CLOSE
    syscall
    mov qword [rsi + CLIENT_FD], -1
    inc r15
    jmp .proc_loop
.proc_done:
    ret

;-----------------------------------------------------------
; handle_read: Read from client into input buffer.
;-----------------------------------------------------------
handle_read:
    push rbx
    push r12
    push r13
    ; rdi holds the client structure pointer.
    mov r8, rdi             ; save client pointer
    mov rbx, qword [r8 + CLIENT_FD]
    lea rsi, [r8 + CLIENT_IN_BUF]
    mov eax, dword [r8 + CLIENT_IN_LEN]
    lea rsi, [rsi + rax]     ; append pointer in input buffer
    mov ecx, IN_BUF_SIZE
    sub ecx, eax           ; available space
    cmp ecx, 0
    jle .done_read         ; if no space, simply return
    mov rax, SYS_READ
    mov rdi, rbx
    mov rdx, rcx
    syscall
    cmp rax, 0
    je .do_close_client_read
    js .check_read_error
    add dword [r8 + CLIENT_IN_LEN], eax
    mov rdi, r8
    call process_requests
    jmp .done_read
.check_read_error:
    neg rax
    cmp rax, EAGAIN
    je .done_read
.do_close_client_read:
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    mov qword [r8 + CLIENT_FD], -1
.done_read:
    pop r13
    pop r12
    pop rbx
    ret

;-----------------------------------------------------------
; process_requests: Process complete messages from input buffer.
; Message format: 4-byte length header (network order) + payload.
;-----------------------------------------------------------
process_requests:
    push rbx
    push r12
    push r13
.process_loop:
    mov eax, dword [rdi + CLIENT_IN_LEN]
    cmp eax, 4
    jl .end_process
    ; Set r14 to the client structure pointer for use in calculations.
    mov r14, rdi

    ; Read 4-byte header from beginning of input buffer.
    lea rsi, [r14 + CLIENT_IN_BUF]
    mov eax, dword [rsi]
    bswap eax
    mov r12d, eax
    add r12d, 4           ; total message size

    mov edx, dword [r14 + CLIENT_IN_LEN]
    cmp edx, r12d
    jb .end_process

    ; Check output buffer overflow.
    mov eax, dword [r14 + CLIENT_OUT_LEN]
    mov edx, r12d
    add edx, eax          ; potential new out_len
    cmp edx, OUT_BUF_SIZE
    ja .overflow          ; jump only if new size > capacity

    ; --- Copy complete message into output buffer ---
    ; Save client pointer in r14.
    mov eax, dword [r14 + CLIENT_OUT_LEN]  ; current out_len (32-bit)
    movsx rcx, eax                         ; sign extend to 64-bit
    lea rdi, [r14 + CLIENT_OUT_BUF + rcx]    ; destination address in output buffer
    mov r12d, r12d                         ; message size already in r12d
    mov rcx, r12d                          ; count of bytes to copy
    lea rsi, [r14 + CLIENT_IN_BUF]           ; source = beginning of input buffer
    rep movsb
    add dword [r14 + CLIENT_OUT_LEN], r12d

    ; --- Compact the input buffer: remove processed message ---
    mov eax, dword [r14 + CLIENT_IN_LEN]   ; total input length
    mov r13d, r12d                         ; processed message size
    sub eax, r13d                          ; remaining bytes
    mov dword [r14 + CLIENT_IN_LEN], eax   ; update input length
    cmp eax, 0
    jle .process_loop                     ; nothing left to move
    ; Calculate source and destination for memmove.
    lea rsi, [r14 + CLIENT_IN_BUF + r13d]   ; source = input buffer + message size
    lea rdi, [r14 + CLIENT_IN_BUF]          ; destination = start of input buffer
    mov ecx, eax                          ; count = remaining bytes
    rep movsb
    jmp .process_loop
.end_process:
    pop r13
    pop r12
    pop rbx
    ret

.overflow:
    mov rax, SYS_CLOSE
    mov rdi, qword [r14 + CLIENT_FD]
    syscall
    mov qword [r14 + CLIENT_FD], -1
    jmp .end_process

;-----------------------------------------------------------
; handle_write: Write outgoing buffer to client.
;-----------------------------------------------------------
handle_write:
    push rbx
    push r13                ; save client pointer
    mov r13, rdi            ; r13 = client structure pointer

    mov rbx, qword [r13 + CLIENT_FD]    ; rbx = FD
    mov eax, dword [r13 + CLIENT_OUT_LEN]
    cmp eax, 0
    je .done_write_restore

    mov edx, dword [r13 + CLIENT_OUT_SENT]
    lea rsi, [r13 + CLIENT_OUT_BUF]
    add rsi, rdx          ; rsi points to unsent data

    mov eax, dword [r13 + CLIENT_OUT_LEN]
    sub eax, dword [r13 + CLIENT_OUT_SENT] ; remaining bytes
    mov ecx, eax                          ; count for write

    mov rax, SYS_WRITE
    mov rdi, rbx                          ; FD for write syscall
    mov rdx, rcx                          ; count
    syscall

    cmp rax, 0
    jle .check_write_error

    add dword [r13 + CLIENT_OUT_SENT], eax
    mov edx, dword [r13 + CLIENT_OUT_SENT]
    mov eax, dword [r13 + CLIENT_OUT_LEN]
    cmp edx, eax
    jne .done_write_restore
    mov dword [r13 + CLIENT_OUT_LEN], 0
    mov dword [r13 + CLIENT_OUT_SENT], 0
    jmp .done_write_restore

.check_write_error:
    js .check_write_eagain_real_error
    jmp .done_write_restore

.check_write_eagain_real_error:
    neg rax
    cmp rax, EAGAIN
    je .done_write_restore

    ; Fatal error: close the connection.
.close_client_write_error:
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    mov qword [r13 + CLIENT_FD], -1

.done_write_restore:
    pop r13
    pop rbx
    ret

;-----------------------------------------------------------
; exit_error: Exit with error code 1.
;-----------------------------------------------------------
exit_error:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall
