global _start

;; syscall numbers
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

;; Socket options & flags
%define SOL_SOCKET     1
%define SO_REUSEADDR   2

;; fcntl commands and flag
%define F_GETFL        3
%define F_SETFL        4
%define O_NONBLOCK     0x800

;; poll event flags
%define POLLIN         0x001
%define POLLOUT        0x004
%define POLLERR        0x008

;; errno value for EAGAIN (or EWOULDBLOCK)
%define EAGAIN         -11

section .data
  ;; Value used for SO_REUSEADDR socket option
  reuseaddr_val:   dd 1

  ;;
  ;; sockaddr_in structure for IPv4, port 6969 (0x1B39 -> network order 0x391B), INADDR_ANY
  ;;
  ;; Struc:
  ;;   sa_family: 2 bytes (AF_INET = 2)
  ;;   sin_port:  2 bytes (network order)
  ;;   sin_addr:  4 bytes (0)
  ;;   padding:   8 bytes (0)
  ;;
  sockaddr_in:
     dw 2                       ; AF_INET
     dw 0x391B                  ; port 6969 in network byte order
     dd 0                       ; INADDR_ANY
     dq 0                       ; Padding (8 bytes)

section .bss
  server_fd  resq 1             ; Listening socket file descriptor
  client_fds resq 128           ; Array to store up to 128 client fds (each a qword)
  pollfds    resb (130 * 8)     ; Pollfd array: one for listen + 128 for clients; each pollfd is 8 bytes
  buffer     resb 1024          ; I/O buffer for client data

section .text
_start:
  mov rax, SYS_EXIT
  mov rdi, 0
  syscall
