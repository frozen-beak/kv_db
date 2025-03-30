global _start

%define SYS_SOCKET 41

section .bss
  server_fd resq 1              ; server socket fd

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

  jmp shutdown

error_exit:
  mov rax, 60
  mov rdi, 1
  syscall

shutdown:
  mov rax, 60
  xor rdi, rdi
  syscall
