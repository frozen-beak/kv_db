global _start

section .bss
  buffer: resb 16
  head: resq 1

section .text
_start:
  ;; read from stdin
  mov rax, 0x00
  mov rdi, 0x00
  lea rsi, [buffer]
  mov rdx, 128
  syscall

  ;; size of mem to allocate with mmap
  mov rbx, rax
  add rbx, 16                   ; 8 (pointer to next) + 8 (size of stored data)

  ;; allocate mem using `mmap` syscall
  mov rdi, 0                     ; addr = Null (kernal chooses the addr)
  mov rsi, rbx                   ; size of mem to allocate (rax + 12)
  mov rdx, 3                     ; prot = PROT_READ | PROT_WRITE (1 | 2 = 3)
  mov r10, 0x22                  ; flags = MAP_PRIVATE | MAP_ANONYMOUS (0x02 | 0x20)
  mov r9, 0                      ; offset = 0
  mov r8, -1                     ; fd = -1 (not backed by any file)
  mov rax, 0x09                  ; mmap syscall
  syscall

  ;; store size of the data in mem block
  ;;
  ;; - pointer (8 bytes) = null
  ;; - size (8 bytes) = rbx - 16
  sub rbx, 16
  mov [rax + 8], rbx

  ;; now let's copy the data from buffer to mem block
  lea rdi, [rax + 16]
  lea rsi, [buffer]
  mov rcx, rbx
  rep movsb                     ; copy `rcx` bytes from `rsi` (buffer) to `rdi` (mem block)

  ;; store the pointer in `head`
  lea rdi, [head]
  mov [rdi], rax

  ;; load the pointer to mem block from `head`
  mov rbx, [head]

  ;; write to stdout
  mov rdx, [rbx + 8]            ; size of the data stored in mem block
  lea rsi, [rbx + 16]           ; pointer to data stored in mem block
  mov rax, 0x01
  mov rdi, 0x01
  syscall

  mov rax, 0x3C
  mov rdi, 0x00
  syscall
