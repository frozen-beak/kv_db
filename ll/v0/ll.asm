global _start

section .data
  buffer resb 16

section .text
_start:
  ;; read from stdin
  mov rax, 0x00
  mov rdi, 0x00
  lea rsi, [buffer]
  mov rdx, 128
  syscall

  ;; write to stdout
  mov rdx, rax
  mov rax, 0x01
  mov rdi, 0x01
  lea rsi, [buffer]
  syscall

  mov rax, 0x3C
  mov rdi, 0x00
  syscall
