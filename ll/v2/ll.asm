global _start

section .bss
  buf resb 16

section .data
  cmd_err db "Unknown Command", 0x0a
  cmd_err_len equ $ - cmd_err

section .text
_start:
  ;; read ll cmd from stdin
  lea rsi, [buf]
  mov rdx, 16
  call read_stdin

  ;; check for read errors (rax == -1)
  test rax, rax
  js error_exit

  ;; write ll cmd to stdout
  mov rdx, rax
  lea rsi, [buf]
  call write_stdout

  ;; check for write errors (rax == -1)
  test rax, rax
  js error_exit

  jmp exit

;; read user input from stdin
;;
;; args,
;; - rsi -> pointer to output buffer
;; - rdx -> max size of buffer
;;
;; ret,
;; - rax -> no. of bytes read or -1 on err
read_stdin:
  ;; read from stdin,
  ;; `rsi` & `rdx` are used from args
  mov rax, 0x00
  mov rdi, 0x00
  syscall

  ;; check for read errors (rax <= 0)
  test rax, rax
  js .err
  jz .err

  jmp .ret
.err:
  mov rax, -1
.ret:
  ret

;; write to stdout
;;
;; args,
;; - rsi -> pointer to buffer
;; - rdx -> no. of bytes to write
;;
;; ret,
;; - rax -> -1 on err, 0 on success
write_stdout:
  ;; write to stdout,
  ;; `rsi` & `rdx` are used from args
  mov rax, 0x01
  mov rdi, 0x01
  syscall

  ;; check for write errors (rax <= 0)
  test rax, rax
  js .err

  jmp .ret
.err:
  mov rax, -1
.ret:
  ret

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
