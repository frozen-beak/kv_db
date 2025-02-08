;; An event-driven, non-blocking TCP echo server in x86_64 assembly
;; using NASM (Intel syntax)

global _start

;; Global Constants
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
%define CLIENT_SIZE   1048
%define POLLFD_SIZE   8
%define POLLFD_FD     0
%define POLLFD_EV     4
%define POLLFD_REV    6

section .bss
  sock          resq 1
  active_clients resq 1
  clients        resb MAX_CLIENTS * CLIENT_SIZE
  pollfd_array   resb ((MAX_CLIENTS + 1) * POLLFD_SIZE)

section .data
  sockaddr_in:
      dw 2          ; AF_INET
      dw 0x1B39     ; Port 6969 (network byte order)
      dd 0          ; sin_addr: INADDR_ANY
      dq 0          ; padding (8 bytes)
  poll_timeout    dq -1

section .text
_start:
  ;; Create a listening socket
  mov     rax, SYS_SOCKET
  mov     rdi, 2          ; AF_INET
  mov     rsi, 1          ; SOCK_STREAM
  xor     rdx, rdx        ; protocol = 0
  syscall
  test    rax, rax
  js      exit            ; exit if error
  mov     [sock], rax     ; save the listening socket

  ;; Bind the socket
  mov     rax, SYS_BIND
  mov     rdi, [sock]
  lea     rsi, [sockaddr_in]
  mov     rdx, 16         ; sizeof(sockaddr_in)
  syscall
  test    rax, rax
  js      exit

  ;; Listen on the socket
  mov     rax, SYS_LISTEN
  mov     rdi, [sock]
  mov     rsi, 128        ; backlog
  syscall
  cmp     rax, 0
  jl      exit

  ;; Set the listening socket to non-blocking mode
  mov     rax, SYS_FCNTL
  mov     rdi, [sock]
  mov     rsi, F_SETFL
  mov     rdx, O_NONBLOCK
  syscall
  test    rax, rax
  js      exit

  ;; Initialize the active client counter to 0
  mov     qword [active_clients], 0

event_loop:
  ;; Build the pollfd array
  lea     rdi, [pollfd_array]
  mov     eax, dword [sock]       ; listening socket fd
  mov     dword [rdi + POLLFD_FD], eax
  mov     word  [rdi + POLLFD_EV], POLLIN
  mov     word  [rdi + POLLFD_REV], 0

  xor     rbx, rbx                ; client index = 0
  mov     rcx, [active_clients]
build_poll_loop:
  cmp     rbx, rcx
  jge     poll_call_done
  mov     rdx, rbx
  imul    rdx, CLIENT_SIZE
  lea     r8, [clients + rdx]
  mov     r9, [r8]                ; client fd
  mov     r10, [r8 + 8]           ; client state
  mov     rdx, rbx
  inc     rdx
  imul    rdx, POLLFD_SIZE
  lea     r11, [pollfd_array + rdx]
  mov     dword [r11 + POLLFD_FD], r9d
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
  mov     rbx, [active_clients]
  inc     rbx
  mov     rax, SYS_POLL
  lea     rdi, [pollfd_array]
  mov     rsi, rbx
  mov     rdx, [poll_timeout]
  syscall
  test    rax, rax
  js      exit

  ;; Check if the listening socket is ready
  lea     rdi, [pollfd_array]
  movzx   eax, word [rdi + POLLFD_REV]
  test    eax, POLLIN
  jz      process_clients

accept_loop:
  mov     rax, SYS_ACCEPT
  mov     rdi, [sock]
  xor     rsi, rsi
  xor     rdx, rdx
  syscall
  cmp     rax, 0
  jl      accept_error
  mov     rdi, rax
  mov     rax, SYS_FCNTL
  mov     rsi, F_SETFL
  mov     rdx, O_NONBLOCK
  syscall
  test    rax, rax
  js      close_new_client
  mov     rbx, [active_clients]
  cmp     rbx, MAX_CLIENTS
  jae     close_new_client
  mov     rdx, rbx
  imul    rdx, CLIENT_SIZE
  lea     r8, [clients + rdx]
  mov     [r8], rax
  mov     qword [r8 + 8], 0
  mov     qword [r8 + 16], 0
  inc     qword [active_clients]
  jmp     accept_loop

accept_error:
  cmp     rax, -11
  je      process_clients
  jmp     exit

close_new_client:
  mov     rdi, rax
  mov     rax, SYS_CLOSE
  syscall
  jmp     accept_loop

process_clients:
  xor     rbx, rbx
process_client_loop:
  mov     rcx, [active_clients]
  cmp     rbx, rcx
  jge     event_loop
  mov     rdx, rbx
  imul    rdx, CLIENT_SIZE
  lea     r8, [clients + rdx]
  mov     rdx, rbx
  inc     rdx
  imul    rdx, POLLFD_SIZE
  lea     r9, [pollfd_array + rdx]
  movzx   eax, word [r9 + POLLFD_REV]
  test    eax, eax
  jz      next_client
  movzx   ecx, word [r9 + POLLFD_REV]
  test    ecx, POLLERR
  jnz     close_client
  test    eax, POLLIN
  jnz     client_read
  test    eax, POLLOUT
  jnz     client_write
  jmp     next_client

client_read:
  mov     rdi, [r8]
  lea     rsi, [r8 + 24]
  mov     rdx, 1024
  mov     rax, SYS_READ
  syscall
  test    rax, rax
  jle     close_client
  mov     [r8 + 16], rax
  mov     qword [r8 + 8], 1
  jmp     next_client

client_write:
  mov     rdi, [r8]
  lea     rsi, [r8 + 24]
  mov     rdx, [r8 + 16]
  mov     rax, SYS_WRITE
  syscall
  test    rax, rax
  js      close_client
  cmp     rax, [r8 + 16]
  jl      partial_write
  mov     qword [r8 + 8], 0
  mov     qword [r8 + 16], 0
  jmp     next_client

partial_write:
  mov     r10, [r8 + 16]
  sub     r10, rax
  mov     [r8 + 16], r10
  lea     rsi, [r8 + 24 + rax]
  lea     rdi, [r8 + 24]
  mov     rcx, r10
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
  mov     rdi, [r8]
  mov     rax, SYS_CLOSE
  syscall
  mov     r10, [active_clients]
  dec     r10
  mov     [active_clients], r10
  cmp     rbx, r10
  je      next_client
  mov     rdx, r10
  imul    rdx, CLIENT_SIZE
  lea     r11, [clients + rdx]
  mov     rcx, CLIENT_SIZE/8
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
