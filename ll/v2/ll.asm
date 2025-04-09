global _start

section .bss
  read_buffer resb 128

section .data
  cmd_err db "Unknown Command", 0x0a
  cmd_err_len equ $ - cmd_err

section .text
_start:
  ;; read user input,
  ;;
  ;; format - {cmd} {key} {val} (space sepreated)
  mov rax, 0x00
  mov rdi, 0x00
  lea rsi, [read_buffer]
  mov rdx, 128
  syscall

  ;; check for read errors (rax <= 0)
  test rax, rax
  js error_exit
  jz error_exit

;; process linked list commands
process_cmds:
  cmp byte [read_buffer], 'g'
  je exit

  cmp byte [read_buffer], 's'
  je exit

  cmp byte [read_buffer], 'd'
  je exit

  jmp unknown_cmd

unknown_cmd:
  mov rax, 0x01
  mov rdi, 0x01
  lea rsi, [cmd_err]
  mov rdx, cmd_err_len
  syscall

  jmp error_exit

error_exit:
  mov rax, 0x3c
  mov rdi, 0x01
  syscall

exit:
  mov rax, 0x3c
  mov rdi, 0x00
  syscall
