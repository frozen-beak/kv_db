global _start

section .bss
  key_buffer: resb 16
  val_buffer: resb 16

  key_len: resq 1
  val_len: resq 1
  head: resq 1

section .text
_start:
  ;; read key from stdin
  mov rax, 0x00
  mov rdi, 0x00
  lea rsi, [key_buffer]
  mov rdx, 16
  syscall

  ;; check for read error (rax < 0)
  test rax, rax
  js error_exit

  ;; store key len
  mov [key_len], rax

  ;; read value from stdin
  mov rax, 0x00
  mov rdi, 0x00
  lea rsi, [val_buffer]
  mov rdx, 16
  syscall

  ;; check for read errors (rax < 0)
  test rax, rax
  js error_exit

  ;; store val len
  mov [val_len], rax

  ;; Construct Node len to create mem block,
  ;;
  ;; len = 8 (pointer) + 8 (key len) + 8 (val len)
  ;;       + m (no. of key bytes) + n (no. of val bytes)
  ;;
  mov rbx, [key_len]            ; we have `val_len` already in rax
  add rbx, rax                  ; now rbx is (key_len + val_len)
  add rbx, 24

  ;; Node,
  ;; - 8 bytes = pointer
  ;; - 8 bytes = size of key
  ;; - 8 bytes = size of value
  ;; - n bytes = key
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

  ;; TODO: check for `mmap` error

  ;; store the mem pointer in head
  lea rdi, [head]
  mov [rdi], rax

  ;; store key len in Node
  mov rdx, [key_len]
  mov [rax + 8], rdx

  ;; store the key buffer in Node
  lea rdi, [rax + 24]
  lea rsi, [key_buffer]
  mov rcx, rdx                  ; key len
  rep movsb                     ; copy `rcx` no. of bytes from `rsi` to `rdi`

  ;; store val len in Node
  mov rdx, [val_len]
  mov [rax + 16], rdx

  ;; load the node offset for value buffer
  mov r10, [key_len]            ; val position is (24 + n (size of key))
  add r10, 24                   ; pointer and size offset

  ;; store the value buffer in Node
  lea rdi, [rax + r10]
  lea rsi, [val_buffer]
  mov rcx, rdx
  rep movsb

  ;; load pointer to the Node
  mov rbx, [head]               ; pointer to the node
  mov rdx, 0x00

  ;; read key len
  mov rax, [rbx + 8]
  add rdx, rax

  ;; read value len
  mov rax, [rbx + 16]
  add rdx, rax

  ;; write key + value to stdout
  lea rsi, [rbx + 24]          ; pointer w/ offset to data in Node
  mov rax, 0x01
  mov rdi, 0x01
  syscall

  ;; sys exit
  mov rax, 0x3c
  mov rdi, 0x00
  syscall

;; exit the program with error code
error_exit:
  mov rax, 0x3c
  mov rdi, 0x01
  syscall
