global _start

section .bss
  read_buffer resb 48
  key_buffer resb 16
  value_buffer resb 16

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
  je set_cmd

  cmp byte [read_buffer], 'd'
  je exit

  jmp unknown_cmd

set_cmd:
  mov rsi, [read_buffer]
  mov rdi, [key_buffer]
  mov rax, 2                    ; initial offset (1 byte [cmd] + 1 byte [space])
  call read_from_buf

  ;; rdx is returned from `read_from_buf` func
  mov rax, 0x01
  mov rdi, 0x01
  lea rsi, [key_buffer]
  syscall

  jmp exit

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

;; reads a string from buf at `rsi` into buf at `rdi`
;;
;; args,
;; - rax -> initial offset for src buffer
;; - rsi -> Pointer to src buffer
;; - rdi -> Pointer to dest buffer
;;
;; counters,
;; - r10 -> used as incr counter for loop
;; - rdx -> used to track no. of bytes to copy
;;
;; ret,
;; - rdx -> no. of bytes copied from src to dest buffer
read_from_buf:
  mov rdx, 0                  ; rdx is used as no. of bytes to copy from src buf
  mov r10, rax
.read_loop:
  ;; if we hit space loop should end
  cmp byte [rsi + r10], ' '
  je .ret

  ;; if we hit newline char, end loop
  cmp byte [rsi + r10], 0x0a
  je .ret

  ;; incr the counters
  add rdx, 1
  add r10, 1

  jmp .read_loop                ; continue the loop
.ret:
  ;; rdi -> hold pointer to dest buf
  lea rsi, [rsi + rax]          ; src buf with initial offset
  mov rcx, rdx                  ; no. of bytes to copy
  rep movsb                     ; copy from src to dest buffer

  ret
