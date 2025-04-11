global _start

section .bss
  buf resb 16
  key_buf resb 16
  val_buf resb 16

  key_len resq 1
  val_len resq 1
  node_head resq 1

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

  ;; process read cmd
  jmp process_cmds

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

;; process linked list commands
process_cmds:
  cmp byte [buf], 'g'
  je exit

  cmp byte [buf], 's'
  je set_cmd

  cmp byte [buf], 'd'
  je exit

  jmp unknown_cmd

;; write cmd unknown error to stdout
unknown_cmd:
  lea rsi, [cmd_err]
  mov rdx, cmd_err_len
  call write_stdout

  ;; check for write errors
  test rax, rax
  js error_exit

  jmp error_exit

;; handle `set` command
set_cmd:
  ;; read key from user
  lea rsi, [key_buf]
  mov rdx, 16
  call read_stdin

  ;; check for read errors (rax == -1)
  test rax, rax
  js error_exit

  ;; store key buf len
  mov [key_len], rax                ; no. of bytes read from stdin

  ;; read value from user
  lea rsi, [val_buf]
  mov rdx, 16
  call read_stdin

  ;; check for read errors (rax == -1)
  test rax, rax
  js error_exit

  ;; store val buf len
  mov [val_len], rax                ; no. of bytes read from stdin

  ;; create a new node
  call create_node

  ;; check for `create_node` errors (rax == -1)
  test rax, rax
  js error_exit

  jmp exit

;; create a mem block for node in linked list
;;
;; ret,
;; - `rax` -> pointer to the node mem block or -1 on error
create_node:
  ;; Calculate Node len,
  ;;
  ;; len = m (no. of key bytes) + n (no. of val bytes)
  ;;     + 24  (pointer + key len + val len)
  mov rax, [key_len]
  mov rbx, [val_len]
  add rbx, rax                  ; now rbx is (val_len + key_len)
  add rbx, 24

  ;; Node,
  ;;
  ;; - 8 bytes = pointer
  ;; - 8 bytes = size of key
  ;; - 8 bytes = size of value
  ;; - n bytes = key (at position [8 * 3])
  ;; - m bytes = value (at position [8 * 3 + n])
  ;;
  ;; allocate mem using `mmap` syscall
  mov rdi, 0x00              ; addr = Null (kernal chooses the addr)
  mov rsi, rbx               ; size of mem to allocate
  mov rdx, 0x03              ; prot = PROT_READ | PROT_WRITE (1 | 2 = 3)
  mov r10, 0x22              ; flags = MAP_PRIVATE | MAP_ANONYMOUS (0x02 | 0x20)
  mov r9, 0x00               ; offset = 0
  mov r8, -1                 ; fd = -1 (not backed by any file)
  mov rax, 0x09              ; mmap syscall
  syscall

  ;; check for `mmap` errors (rax < 0)
  test rax, rax
  js .err

  ;; load key & val len's
  mov rdx, [key_len]
  mov r10, [val_len]

  mov [rax + 8], rdx            ; store the key len
  mov [rax + 16], r10           ; store the val len

  ;; store the key
  lea rdi, [rax + 24]
  lea rsi, [key_buf]
  mov rcx, rdx                  ; len of key buf
  rep movsb

  ;; store the val
  add rdx, 24                   ; pointer for val pos in node (24 + key_len)
  lea rdi, [rax + rdx]
  lea rsi, [val_buf]
  mov rcx, r10                  ; len of val buf
  rep movsb

  jmp .ret
.err:
  mov rax, -1
.ret:
  ret                           ; returned w/ `rax` holding pointer to the node

error_exit:
  mov rax, 0x3c
  mov rdi, 0x01
  syscall

exit:
  mov rax, 0x3c
  mov rdi, 0x00
  syscall
