global _start

section .text
_start:
  ;; sys exit
  mov rax, 0x3c
  mov rdi, 0x00
  syscall
