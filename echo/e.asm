;;-----------------------------------------------------------------------
;; An event-driven, non-blocking TCP echo server in x86_64 assembly
;; using NASM (Intel syntax)
;;
;; This server uses poll(2) to multiplex a listening socket and up to
;; MAX_CLIENTS concurrently. Each client is stored in a fixed-size struct
;; that holds its file descriptor, state (read or write), the pending
;; number of bytes, and a 1024-byte buffer.
;;
;; Author: Your Name (adapted by ChatGPT)
;; Date: 2025-02-10
;;-----------------------------------------------------------------------

global _start

;-----------------------------------------------------------------------
;; Global Constants
;-----------------------------------------------------------------------

%define SYS_READ      0
%define SYS_WRITE     1
%define SYS_CLOSE     3
%define SYS_POLL      7
%define SYS_SOCKET    41
%define SYS_ACCEPT    43
%define SYS_BIND      49
%define SYS_LISTEN    50
%define SYS_EXIT      60
%define SYS_FCNTL     72

%define MAX_CLIENTS   1024

%define POLLIN        0x0001
%define POLLOUT       0x0004
%define POLLERR       0x0008

%define F_SETFL       3
%define O_NONBLOCK    0x4000

;; Each client structure holds:
;;   fd       : 8 bytes
;;   state    : 8 bytes  (0 = want read, 1 = want write)
;;   buf_len  : 8 bytes  (number of pending bytes)
;;   buf      : 1024 bytes
;;
;; Total size: 8 + 8 + 8 + 1024 = 1048 bytes.
%define CLIENT_SIZE   1048

;; Each pollfd structure (for poll(2)) holds:
;;   int fd        (4 bytes)
;;   short events  (2 bytes)
;;   short revents (2 bytes)
;;
;; Total size: 4+2+2 = 8 bytes.
%define POLLFD_SIZE   8
%define POLLFD_FD     0
%define POLLFD_EV     4
%define POLLFD_REV    6

;-----------------------------------------------------------------------
;; Uninitialized Global Variables
;-----------------------------------------------------------------------

section .bss
  ;; Listening socket file descriptor
  sock            resq 1

  ;; Number of active clients
  active_clients  resq 1

  ;; Client structures array. Maximum MAX_CLIENTS clients.
  clients         resb MAX_CLIENTS * CLIENT_SIZE

  ;; Pollfd array.
  ;; We reserve one extra entry (index 0 for the listening socket) and then
  ;; one entry per active client.
  pollfd_array    resb ((MAX_CLIENTS + 1) * POLLFD_SIZE)

;-----------------------------------------------------------------------
;; Initialized Global Variables
;-----------------------------------------------------------------------

section .data
  ;; sockaddr_in structure for binding (IPv4, port 6969)
  ;; Layout:
  ;;   sa_family : 2 bytes (AF_INET = 2)
  ;;   sin_port  : 2 bytes (network order port 6969, 0x1B39)
  ;;   sin_addr  : 4 bytes (INADDR_ANY = 0)
  ;;   padding   : 8 bytes
  sockaddr_in:
      dw 2                   ; AF_INET
      dw 0x04D2              ; Port 1234 (network byte order)
      dd 0                   ; sin_addr: INADDR_ANY
      dq 0                   ; padding (8 bytes)

  ;; Poll timeout value for poll(2): -1 = infinite timeout.
  poll_timeout    dq -1

;-----------------------------------------------------------------------
;; Code Section
;-----------------------------------------------------------------------

section .text
_start:
  ;; Create a listening socket:
  ;;   socket(AF_INET, SOCK_STREAM, 0)
  mov     rax, SYS_SOCKET
  mov     rdi, 2                ; AF_INET
  mov     rsi, 1                ; SOCK_STREAM
  xor     rdx, rdx              ; protocol = 0
  syscall
  test    rax, rax
  js      exit                ; exit if error (rax < 0)
  mov     [sock], rax         ; save the listening socket

  ;; Bind the socket:
  ;;   bind(sock, &sockaddr_in, sizeof(sockaddr_in))
  mov     rax, SYS_BIND
  mov     rdi, [sock]
  lea     rsi, [sockaddr_in]
  mov     rdx, 16             ; sizeof(sockaddr_in)
  syscall
  test    rax, rax
  js      exit

  ;; Listen on the socket:
  ;;   listen(sock, backlog)
  mov     rax, SYS_LISTEN
  mov     rdi, [sock]
  mov     rsi, 128              ; backlog
  syscall
  cmp     rax, 0
  jl      exit

  ;; Set the listening socket to non-blocking mode:
  ;;   fcntl(sock, F_SETFL, O_NONBLOCK)
  mov     rax, SYS_FCNTL
  mov     rdi, [sock]
  mov     rsi, F_SETFL
  mov     rdx, O_NONBLOCK
  syscall
  test    rax, rax
  js      exit

  ;; Initialize the active client counter to 0.
  mov     qword [active_clients], 0

event_loop:
  ;;---------------------------------------------------------------------
  ;; Build the pollfd array.
  ;;
  ;; Entry 0: the listening socket.
  ;; Entries 1..N: each active client.
  ;;---------------------------------------------------------------------
  lea     rdi, [pollfd_array]
  mov     eax, dword [sock]         ; listening socket fd (lower 32 bits)
  mov     dword [rdi + POLLFD_FD], eax
  mov     word  [rdi + POLLFD_EV], POLLIN
  mov     word  [rdi + POLLFD_REV], 0

  ;; For each client in the clients array, add an entry.
  xor     rbx, rbx                ; client index = 0
  mov     rcx, [active_clients]
build_poll_loop:
  cmp     rbx, rcx
  jge     poll_call_done

  ;; Compute pointer to the client structure: clients + (rbx * CLIENT_SIZE)
  mov     rdx, rbx
  imul    rdx, CLIENT_SIZE
  lea     r8, [clients + rdx]

  ;; Load client fd and state.
  mov     r9, [r8]              ; client fd (64-bit, use lower 32 bits)
  mov     r10, [r8 + 8]         ; client state (0 = want read, 1 = want write)

  ;; Compute pointer to the corresponding pollfd entry:
  ;; pollfd_array + ((rbx + 1) * POLLFD_SIZE)
  mov     rdx, rbx
  inc     rdx
  imul    rdx, POLLFD_SIZE
  lea     r11, [pollfd_array + rdx]

  ;; Store client fd (use only the lower 32 bits)
  mov     dword [r11 + POLLFD_FD], r9d
  ;; Set the events based on the client state.
  cmp     r10, 0
  je      set_read_event
  mov     word [r11 + POLLFD_EV], POLLOUT
  jmp     clear_revents
set_read_event:
  mov     word [r11 + POLLFD_EV], POLLIN
clear_revents:
  mov     word [r11 + POLLFD_REV], 0

  inc     rbx
  jmp     build_poll_loop

poll_call_done:
  ;; Total number of pollfd entries = active_clients + 1.
  mov     rbx, [active_clients]
  inc     rbx

  ;; Call poll(2):
  ;;   poll(pollfd_array, nfds, timeout)
  mov     rax, SYS_POLL
  lea     rdi, [pollfd_array]
  mov     rsi, rbx
  mov     rdx, [poll_timeout]   ; load timeout value (-1 for infinite)
  syscall
  test    rax, rax
  js      exit                ; error in poll

  ;; Check if the listening socket is ready (new connection available).
  lea     rdi, [pollfd_array]
  movzx   eax, word [rdi + POLLFD_REV]
  test    eax, POLLIN
  jz      process_clients     ; if not, skip the accept loop

accept_loop:
  ;; Accept new connections as long as poll(2) indicates data.
  mov     rax, SYS_ACCEPT
  mov     rdi, [sock]
  xor     rsi, rsi           ; addr = NULL
  xor     rdx, rdx           ; addrlen = NULL
  syscall
  cmp     rax, 0
  jl      accept_error      ; error if rax < 0

  ;; Set the new client socket to non-blocking mode.
  mov     rdi, rax           ; new client fd
  mov     rax, SYS_FCNTL
  mov     rsi, F_SETFL
  mov     rdx, O_NONBLOCK
  syscall
  test    rax, rax
  js      close_new_client

  ;; Add the new client to our clients array if room permits.
  mov     rbx, [active_clients]
  cmp     rbx, MAX_CLIENTS
  jae     close_new_client

  mov     rdx, rbx
  imul    rdx, CLIENT_SIZE
  lea     r8, [clients + rdx]
  mov     [r8], rax         ; store the client fd
  mov     qword [r8 + 8], 0   ; set state = READ
  mov     qword [r8 + 16], 0  ; initial buffer length = 0
  inc     qword [active_clients]
  jmp     accept_loop

accept_error:
  cmp     rax, -11         ; EAGAIN/EWOULDBLOCK (-11)
  je      process_clients
  jmp     exit

close_new_client:
  mov     rdi, rax         ; client fd to close
  mov     rax, SYS_CLOSE
  syscall
  jmp     accept_loop

process_clients:
  ;;---------------------------------------------------------------------
  ;; Process events on each active client.
  ;;---------------------------------------------------------------------
  xor     rbx, rbx         ; client index = 0
process_client_loop:
  mov     rcx, [active_clients]
  cmp     rbx, rcx
  jge     event_loop       ; finished processing clients; loop back

  ;; Compute pointer to the client structure: clients + (rbx * CLIENT_SIZE)
  mov     rdx, rbx
  imul    rdx, CLIENT_SIZE
  lea     r8, [clients + rdx]

  ;; Compute pointer to corresponding pollfd entry:
  ;; pollfd_array + ((rbx + 1) * POLLFD_SIZE)
  mov     rdx, rbx
  inc     rdx
  imul    rdx, POLLFD_SIZE
  lea     r9, [pollfd_array + rdx]

  ;; Get the pollfd revents field.
  movzx   eax, word [r9 + POLLFD_REV]
  test    eax, eax
  jz      next_client

  ;; If an error occurred on the client socket, close it.
  movzx   ecx, word [r9 + POLLFD_REV]
  test    ecx, POLLERR
  jnz     close_client

  ;; If the client socket is ready for reading...
  test    eax, POLLIN
  jnz     client_read

  ;; ...or if it’s ready for writing...
  test    eax, POLLOUT
  jnz     client_write

  jmp     next_client

client_read:
  ;; Read data from the client into its buffer (up to 1024 bytes).
  mov     rdi, [r8]           ; client fd
  lea     rsi, [r8 + 24]      ; pointer to client's buffer
  mov     rdx, 1024
  mov     rax, SYS_READ
  syscall
  test    rax, rax
  jle     close_client       ; if rax <= 0, close client (error or EOF)
  mov     [r8 + 16], rax     ; store number of bytes read
  mov     qword [r8 + 8], 1  ; set client state to WRITE
  jmp     next_client

client_write:
  ;; Write pending data from the client's buffer.
  mov     rdi, [r8]           ; client fd
  lea     rsi, [r8 + 24]      ; pointer to client's buffer
  mov     rdx, [r8 + 16]      ; number of bytes pending
  mov     rax, SYS_WRITE
  syscall
  test    rax, rax
  js      close_client       ; if error, close client
  cmp     rax, [r8 + 16]
  jl      partial_write      ; if not all data was written, do a partial write
  ;; All data written: reset state to READ and clear buf_len.
  mov     qword [r8 + 8], 0
  mov     qword [r8 + 16], 0
  jmp     next_client

partial_write:
  ;; Adjust the client’s buffer after a partial write.
  mov     r10, [r8 + 16]    ; current pending length
  sub     r10, rax          ; remaining = buf_len - bytes_written
  mov     [r8 + 16], r10    ; update pending length
  lea     rsi, [r8 + 24 + rax]  ; source: remaining data after what was written
  lea     rdi, [r8 + 24]        ; destination: start of buffer
  mov     rcx, r10         ; number of remaining bytes
.copy_loop:
  cmp     rcx, 0
  je      next_client
  mov     al, [rsi]
  mov     [rdi], al
  inc     rsi
  inc     rdi
  dec     rcx
  jmp     .copy_loop

close_client:
  ;; Close the client socket and remove it from the array.
  mov     rdi, [r8]         ; client fd
  mov     rax, SYS_CLOSE
  syscall

  ;; Decrement active_clients.
  mov     r10, [active_clients]
  dec     r10
  mov     [active_clients], r10

  ;; If this client was the last one, we are done.
  cmp     rbx, r10
  je      next_client

  ;; Otherwise, swap the last client into the slot of the closed client.
  mov     rdx, r10
  imul    rdx, CLIENT_SIZE
  lea     r11, [clients + rdx]
  ;; Copy the client structure in qwords.
  mov     rcx, CLIENT_SIZE/8   ; 1048/8 = 131 qwords
.swap_loop:
  cmp     rcx, 0
  je      next_client
  mov     rax, [r11]
  mov     [r8], rax
  add     r8, 8
  add     r11, 8
  dec     rcx
  jmp     .swap_loop

next_client:
  inc     rbx
  jmp     process_client_loop

exit:
  mov     rax, SYS_EXIT
  mov     rdi, 1
  syscall
