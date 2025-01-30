global _start

section .bss
  sock resq 1
  client resq 1

section .data
  sockaddr_in db 2, 0
              dw 0xd204         ; sin_port (1234 in big-endian)
              dd 0
              db 0,0,0,0,0,0,0,0 ; padding

  reply_msg db "connection accpeted", 0
  reply_len equ $ - reply_msg

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

  ;; log connection success
  mov rax, 1
  mov rdi, 1
  mov rsi, reply_msg
  mov rdx, reply_len
  syscall

  ;; send response to the client
  mov rax, 1
  mov rdi, [client]
  lea rsi, [reply_msg]
  mov rdx, reply_len
  syscall

  ;; close client socket
  mov rax, 3
  mov rdi, [client]
  syscall

  ;; repeat the loop
  jmp accept_loop

exit:
  mov rax, 60
  mov rdi, 1
  syscall
