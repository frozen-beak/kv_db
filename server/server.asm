global _start

;; sys calls
%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_SETSOCKOPT 54

;; constants
%define SOMAXCONN 128

section .data
  reuseaddr_val:  dd 1

  ;; sockaddr_in (16 bytes) for IPv4, port 1234, INADDR_ANY.
  sockaddr_in:
      dw 2                      ; AF_INET
      dw 0xD204                 ; port (1234)
      dd 0                      ; sin_addr (wildcard IP 0.0.0.0)
      dq 0                      ; padding (0)

section .bss
  server_fd resq 1              ; server socket fd
  client_fd resq 1              ; current client's fd

  buffer resb 128               ; universal buffer to read clients data

section .text
_start:
  ;; create a listening socket
  mov rax, SYS_SOCKET
  mov rdi, 2
  mov rsi, 1
  xor rdx, rdx
  syscall

  test rax, rax
  js error_exit

  mov [server_fd], rax

  ;; set socket options
  mov rax, SYS_SETSOCKOPT
  mov rdi, [server_fd]
  mov rsi, 1
  mov rdx, 2
  lea r10, [reuseaddr_val]
  mov r8, 4
  syscall

  test rax, rax
  js error_exit

  ;; bind to an address
  mov rax, SYS_BIND
  mov rdi, [server_fd]
  lea rsi, [sockaddr_in]
  mov rdx, 16
  syscall

  test rax, rax
  jnz error_exit

  ;; listen (finally create the actual socket)
  mov rax, SYS_LISTEN
  mov rdi, [server_fd]
  mov rsi, SOMAXCONN
  syscall

  test rax, rax
  jnz error_exit

server_loop:
  ;; accept connection
  mov rax, SYS_ACCEPT
  mov rdi, [server_fd]
  xor rsi, rsi
  xor rdx, rdx
  syscall

  test rax, rax
  js server_loop                ; continue in loop

  mov [client_fd], rax

  ;; read data from client
  mov rax, SYS_READ
  mov rdi, [client_fd]
  lea rsi, [buffer]
  mov rdx, 128
  syscall

  ;; check for read errors (rax < 0)
  test rax, rax
  jnz close_client


error_exit:
  mov rax, 60
  mov rdi, 1
  syscall
