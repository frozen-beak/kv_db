global _start

%define SYS_WRITE 1
%define SYS_EXIT 60

section .data
  msg db "Hello, echo (:"
  len equ $ - msg

section .text
_start:
  mov rax, SYS_WRITE
  mov rdi, 1
  lea rsi, [msg]
  mov rdx, len
  syscall

  mov rax, SYS_EXIT
  mov rdi, 0
  syscall
