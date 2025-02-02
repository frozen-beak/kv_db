;;
;; An event driven, non blocking TCP echo server in x86
;; assembly w/ nasm and intel syntax.
;;

global _start

;;
;; Global Constants
;;

%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_CLOSE 3
%define SYS_POLL 7
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_EXIT 60
%define SYS_FCNTL 72

%define MAX_CLIENTS 1024
%define POLLIN 0x0001
%define POLLOUT 0x0004
%define POLLERR 0x0008
%define F_SETFL 3
%define O_NONBLOCK 0x4000

;;
;; Uninitialized global variables
;;
section .bss
  ;; listening socket
  sock resq 1

  ;; no. of active clients
  active_clients resq 1

  ;;
  ;; Client structure array for each client
  ;;
  ;; It stores,
  ;;
  ;;   fd:       8 bytes
  ;;   state:    8 bytes (0: want read; 1: want write)
  ;;   buf_len:  8 bytes (bytes pending for write)
  ;;   buf:      1024 bytes (client-specific buffer)
  ;;
  ;; Total per client: 8 + 8 + 8 + 1024 = 1048 bytes
  ;;
  ;; 📝 NOTE: At max, only `1024` clients are allowed
  ;;
  clients     resb MAX_CLIENTS * 1048

  ;;
  ;; PollFd array,
  ;;
  ;; Total Entries -> 1 + MAX_CLIENTS
  ;;
  ;; 📝 NOTE: Includes server's own fd at 0th index
  ;;
  ;; Each pollfd stores,
  ;;
  ;;   (int) fd:          4 bytes
  ;;   (short) events:    2 bytes
  ;;   (short) revents:   2 bytes
  ;;
  ;; Total per pollfd: 4 + 2 + 2 = 8 bytes
  ;;
  pollfd_array resb ((MAX_CLIENTS + 1) * 8)

;;
;; Initialized global variables
;;
section .data
  ;;
  ;; `sockaddr_in` struct (assume IPv4 w/ port 6969)
  ;;
  ;; struct:
  ;;
  ;;   sa_family:   2 bytes
  ;;   sin_port:    2 bytes
  ;;   sin_addr:    4 bytes
  ;;   padding:     8 bytes
  ;;
  ;; Total 16 bytes
  ;;
  sockaddr_in:
      dw 2                           ; AF_INET
      dw 0x1B39                      ; port 6969 in big-endian (0x391B => 6969)
      dd 0                           ; sin_addr (INADDR_ANY)
      dq 0                           ; padding (8 bytes)

  ;; timeout for poll(), set to -1 (infinite)
  poll_timeout dq -1

  ;;
  ;; constants for pollfd fields
  ;;
  ;; structure,
  ;;  fd = 0
  ;;  events = 4
  ;;  revents = 4
  pollfd_fd equ 0
  pollfd_ev equ 4
  pollfd_rev equ 4

  ;; client states
  STATE_READ dq 0               ; want to read
  STATE_WRITE dq 1              ; want to write

section .text
_start:
  ;;
  ;; create a listening socket,
  ;;
  ;; `socket(AF_INET, SOCK_STREAM, 0)`
  ;;
  mov rax, SYS_SOCKET
  mov rdi, 2                    ; AF_INET
  mov rsi, 1                    ; SOCK_STREAM
  xor rdx, rdx                  ; protocol (0)
  syscall

  ;; check for listen errors (rax < 0)
  test rax, rax
  js exit

  ;; save socket fd
  mov [sock], rax

  ;; bind the socket
  mov rax, SYS_BIND
  mov rdi, [sock]
  lea rsi, [sockaddr_in]
  mov rdx, 16                   ; sizeof `sockaddr_in`
  syscall

  ;; check for bind errors (rax < 0)
  test rax, rax
  js exit

  ;; listen to the socket
  mov rax, SYS_LISTEN
  mov rdi, [sock]
  mov rsi, 5                    ; backlog
  syscall

  ;; check for listen errors (rax < 0)
  cmp rax, 0
  jl exit

  ;; set the listening socket to non-blocking
  ;;
  ;; `fcntl(fd, F_SETFL, O_NONBLOCK)`
  mov rax, SYS_FCNTL
  mov rdi, [sock]
  mov rsi, F_SETFL
  mov rdx, O_NONBLOCK
  syscall

  ;; check for fcntl error (rax < 0)
  test rax, rax
  js exit

  ;; init client counter to 0
  mov qword [active_clients], 0

shut:
  mov rax, SYS_EXIT
  xor rdi, rdi
  syscall

exit:
  mov rax, SYS_EXIT
  mov rdi, 1
  syscall
