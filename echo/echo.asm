global _start

%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_CLOSE 3
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_EXIT 60

section .bss
  sock resq 1
  client resq 1
  buffer resb 1024

section .data
  ;;
  ;; `sockaddr_in` struct (IPv4 w/ port 6969)
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
      dw 0x391B                      ; port 6969 in big-endian (0x391B => 6969)
      dd 0                           ; sin_addr (INADDR_ANY)
      dq 0                           ; padding (8 bytes)

section .text
_start:
  ;;
  ;; create a listening socket
  ;;
  ;; `socket(AF_INET, SOCK_STREAM, 0)`
  ;;
  mov rax, SYS_SOCKET
  mov rdi, 2                    ; AF_INET
  mov rsi, 1                    ; SOCK_STREAM
  xor rdx, rdx                  ; protocol(0)
  syscall

  ;; check for socket errors
  test rax, rax
  js exit

  ;; save socket fd
  mov [sock], rax

  ;; TODO: call setsocketopt to reuse the addr

  ;;
  ;; bind the socket
  ;;
  mov rax, SYS_BIND
  mov rdi, [sock]
  lea rsi, [sockaddr_in]
  mov rdx, 16
  syscall

  ;; check for bind errors
  test rax, rax
  js exit

  ;;
  ;; listen to socket
  ;;
  mov rax, SYS_LISTEN
  mov rdi, [sock]
  mov rsi, 128
  syscall

  ;; check for listen errors
  cmp rax, 0
  jl exit

accept_loop:
  ;; accept connections
  mov rax, SYS_ACCEPT
  mov rdi, [sock]
  xor rsi, rsi
  xor rdx, rdx
  syscall

  ;; check for accept errors
  cmp rax, 0
  jl exit

  ;; store client socket fd
  mov [client], rax

echo_loop:
  ;; read data from the client
  mov rax, SYS_READ
  mov rdi, [client]
  lea rsi, [buffer]
  mov rdx, 1024
  syscall

  ;; check for read errors
  ;; EOF or (rax <= 0)
  test rax, rax
  jle close_client

  ;; check if client send 'q'
  cmp rax, 1
  je check_quit
  cmp rax, 2
  je check_quit_newline

  ;; proceed to echo data
  jmp echo_data

echo_data:
  ;; send data back to client
  mov rdx, rax
  mov rax, SYS_WRITE
  mov rdi, [client]
  lea rsi, [buffer]
  syscall

  ;; repeat the echo loop
  jmp echo_loop

check_quit:
  cmp byte [buffer], 'q'
  jne echo_data

  jmp close_client

check_quit_newline:
  cmp byte [buffer], 'q'
  jne echo_data
  cmp byte [buffer + 1], 0x0a
  jne echo_data

  ;; jmp close_client

  ;; fall through to close client connection
  ;; if both check passed

close_client:
  mov rax, SYS_CLOSE
  mov rdi, [client]
  syscall

  ;; wait for new connection
  jmp accept_loop

exit:
  mov rax, SYS_EXIT
  mov rdi, 1
  syscall
