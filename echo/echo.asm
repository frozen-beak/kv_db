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

section .text
_start:
  mov rax, SYS_EXIT
  mov rdi, 0
  syscall
