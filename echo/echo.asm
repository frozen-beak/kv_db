global _start

%define SYS_EXIT 60

section .text
_start:
  mov rax, SYS_EXIT
  xor rdi, rdi
  syscall
