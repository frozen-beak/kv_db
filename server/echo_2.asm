global _start

;; sys calls
%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_CLOSE 3
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_SETSOCKOPT 54
%define SYS_EXIT 60

;; socket options constants
%define SOL_SOCKET 1
%define SO_REUSEADDR 2

;; poll(2) events (the pollfd struct has: int fd, short events, short revents)
%define POLLIN 0x0001
%define POLLOUT 0x0004

;; fcntl flags (F_SETFL is used to set the file descriptor flags)
%define F_SETFL 4
%define O_NONBLOCK 0x800        ; non block flag on linux

;; max no. of connections allowed
%define MAX_EVENTS 128

;; error values
%define POLLERR 0x0008
%define POLLHUP 0x0010

section .bss
  sock resq 1                   ; listening socket fd
  client resq 1                 ; clients socket fd
  buffer resb 1024              ; client's data buffer

section .data
  reuseaddr_val dd 1          ; int (VALUE = 1) for setsocketopt

  ;;
  ;; `sockaddr_in` struct (16 bytes) w/ IPv4 port 6969 and INADDR_ANY
  ;;
  ;; struct:
  ;;
  ;;   sa_family:   2 bytes
  ;;   sin_port:    2 bytes
  ;;   sin_addr:    4 bytes
  ;;   padding:     8 bytes
  ;;
  sockaddr_in:
      dw 2                      ; AF_INET
      dw 0x391B                 ; 6969 in big endian
      dd 0                      ; sin_addr
      dq 0                      ; padding (8 bytes)

section .text
_start:
  ;; create a listening socket
  ;;
  ;; `socket(AF_INET, SOCK_STREAM, 0)`
  mov rax, SYS_SOCKET
  mov rdi, 2
  mov rsi, 1
  xor rdx, rdx
  syscall

  ;; check for errors (rax < 0)
  test rax, rax
  js error

  ;; save the listening socket fd
  mov [sock], rax

  ;; set socket options
  ;;
  ;; `setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseaddr_val, 4)`
  mov rax, SYS_SETSOCKOPT
  mov rdi, [sock]
  mov rsi, SOL_SOCKET
  mov rdx, SO_REUSEADDR
  lea r10, [reuseaddr_val]
  mov r8, 4
  syscall

  ;; check for errors (rax < 0)
  test rax, rax
  js error

  ;; bind the socket
  ;;
  ;; `bind(sock, sockaddr_in, 16)`
  mov rax, SYS_BIND
  mov rdi, [sock]
  lea rsi, [sockaddr_in]
  mov rdx, 16
  syscall

  ;; check for errors (rax != 0)
  test rax, rax
  jnz error

  ;; listen to connections
  ;;
  ;; `listen(fd, SOMAXCONN)`
  mov rax, SYS_LISTEN
  mov rdi, [sock]
  mov rsi, 128
  syscall

  ;; check for listen errors (rax != 0)
  test rax, rax
  jnz error

accept_loop:
  ;; accept new connections
  ;;
  ;; `accept(fd, (struct sockaddr *)&client_addr, &addrlen)`
  mov rax, SYS_ACCEPT
  mov rdi, [sock]
  xor rsi, rsi
  xor rdx, rdx
  syscall

  ;; check for accept errors (rax < 0)
  test rax, rax
  js error

  ;; store clients fd
  mov [client], rax

echo_msg:
  ;; read from client
  ;;
  ;; `read(connfd, rbuf, sizeof(rbuf) - 1)`
  mov rax, SYS_READ
  mov rdi, [client]
  lea rsi, [buffer]
  mov rdx, 1024
  syscall

  ;; check for read errors
  ;; EOF or (rax <= 0)
  test rax, rax
  jle close_client

  ;; no of bytes to write
  mov rdx, rax

  ;; write back to client
  ;;
  ;; `write(connfd, wbuf, strlen(wbuf))`
  mov rax, SYS_WRITE
  mov rdi, [client]
  lea rsi, [buffer]
  syscall

  jmp close_client

close_client:
  mov rax, SYS_CLOSE
  mov rdi, [client]
  syscall

  ;; wait for the new connection
  jmp accept_loop

exit:
  mov rax, SYS_EXIT
  mov rdi, 0
  syscall

error:
  mov rax, SYS_EXIT
  mov rdi, 1
  syscall
