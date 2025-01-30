global _start

section .bss
  sock resq 1
  client resq 1
  buffer resb 1024

section .data
  sockaddr_in db 2, 0
              dw 0xd204         ; sin_port (1234 in big-endian)
              dd 0
              db 0,0,0,0,0,0,0,0 ; padding

section .text
_start:
  ;; create a socket
  mov rax, 41
  mov rdi, 2
  mov rsi, 1
  xor rdx, rdx
  syscall

  ;; check for socket errors
  test rax, rax
  js exit

  ;; save the socket fd
  mov [sock], rax

  ;; bind socket
  mov rax, 49
  mov rdi, [sock]
  lea rsi, [sockaddr_in]
  mov rdx, 16
  syscall

  ;; check for bind errors
  test rax, rax
  js exit

  ;; listen to socket
  mov rax, 50
  mov rdi, [sock]
  mov rsi, 5
  syscall

  ;; check for listen erros
  cmp rax, 0
  jl exit

accept_loop:
  ;; accept connections
  mov rax, 43
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
  mov rax, 0
  mov rdi, [client]
  lea rsi, [buffer]
  mov rdx, 1024
  syscall

  ;; check for read errors
  ;; or EOF (rax <= 0)
  test rax, rax
  jle close_client

  ;; echo data back to client
  mov rdx, rax                  ; no of bytes received from client
  mov rax, 1
  mov rdi, [client]
  lea rsi, [buffer]
  syscall

  ;; repeat the echo loop
  jmp echo_loop

close_client:
  ;; close the client socket
  mov rax, 3
  mov rdi, [client]
  syscall

  ;; wait for the new connection
  jmp accept_loop

exit:
  mov rax, 60
  mov rdi, 1
  syscall
