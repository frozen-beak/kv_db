global _start

;; sys calls
%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_CLOSE 3
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_SETSOCKOPT 54
%define SYS_EXIT 60

;; constants
%define SOMAXCONN 128
%define AF_INET 2
%define SOCK_STREAM 1
%define SOL_SOCKET 1
%define SO_REUSEADDR 2

section .data
  reuseaddr_val: dd 1

  ;; sockaddr_in struct (16 bytes) for IPv4, port 1234, INADDR_ANY.
  sockaddr_in:
      dw 2                      ; AF_INET
      dw 0xD204                 ; port (1234) in network byte order
      dd 0                      ; protocol(0)
      dq 0                      ; padding of 8 bytes

section .bss
  server_fd resq 1              ; server fd
  client_fd resq 1              ; current client's fd
  buffer resb 128               ; universal buffer used for read/write from/to client

section .text
_start:
  ;; create a listening socket
  mov rax, SYS_SOCKET
  mov rdi, AF_INET
  mov rsi, SOCK_STREAM
  xor rdx, rdx
  syscall

  ;; check for socket errors (rax < 0)
  test rax, rax
  js error_exit

  mov [server_fd], rax

  ;; set socket options
  mov rax, SYS_SETSOCKOPT
  mov rdi, [server_fd]
  mov rsi, SOL_SOCKET
  mov rdx, SO_REUSEADDR
  lea r10, [reuseaddr_val]
  mov r8, 4
  syscall

  ;; bind to an address
  mov rax, SYS_BIND
  mov rdi, [server_fd]
  lea rsi, [sockaddr_in]
  mov rdx, 16
  syscall

  ;; check for bind errors (rax != 0)
  test rax, rax
  jnz error_exit

  ;; listen to the socket
  mov rax, SYS_LISTEN
  mov rdi, [server_fd]
  mov rsi, SOMAXCONN
  syscall

  ;; check for listen errors (rax != 0)
  test rax, rax
  jnz error_exit

server_loop:
  ;; accept new conn
  mov rax, SYS_ACCEPT
  mov rdi, [server_fd]
  xor rsi, rsi
  xor rdx, rdx
  syscall

  ;; check for accept errors
  ;; if client fd is less then 0 i.e. (rax < 0)
  test rax, rax
  js server_loop                ; contiune the loop

  mov [client_fd], rax          ; save current clients fd

  ;; read 4 byte header from client fd
  lea rsi, [buffer]
  mov rdx, 4
  mov rdi, [client_fd]
  call read_full

  ;; extract 4 bytes msg len from buffer
  mov edx, [buffer]

  ;; read the msg from the client fd
  lea rsi, [buffer + 4]         ; first 4 bytes are header
  mov rdi, [client_fd]
  call read_full

  ;; read msg len (header) from buffer
  mov edx, [buffer]
  add edx, 4

  ;; write back to client
  mov rdi, [client_fd]
  lea rsi, [buffer]
  call write_full

  jmp close_client              ; close the connection

;; read from the client fd
;;
;; args:
;;   rdi - clients fd to read from
;;   rsi - buffer pointer
;;   rdx - no. of bytes to read / buffer len
;;
;; ret:
;;   rax - `0` on success and `-1` on error
read_full:
.read_loop:
  cmp rdx, 0
  jle .done

  mov rax, SYS_READ
  syscall

  ;; check for read errors (rax < 0)
  test rax, rax
  js .err
  jz .read_loop                      ; continue reading if 0 bytes are read

  add rsi, rax                  ; advance the buffer pointer
  sub rdx, rax                  ; subtract no. of bytes read from `n`

  jmp .read_loop
.done:
  mov rax, 0
  jmp .ret
.err:
  mov rax, -1
.ret:
  ret


;; write to the client fd
;;
;; args:
;;   rdi - clients fd to read from
;;   rsi - buffer pointer
;;   rdx - no. of bytes to write / buffer len
;;
;; ret:
;;   rax - `0` on success and `-1` on error
write_full:
.write_loop:
  cmp rdx, 0
  jle .done

  mov rax, SYS_WRITE
  syscall

  test rax, rax
  js .err
  jz .write_loop                ; continue if 0 bytes are written/sent

  sub rdx, rax
  add rsi, rax

  jmp .write_loop
.err:
  mov rax, -1
  jmp .ret
.done:
  mov rax, 0
.ret:
  ret

close_client:
  mov rax, SYS_CLOSE
  mov rdi, [client_fd]
  syscall

  jmp server_loop

error_exit:
  mov rax, SYS_EXIT
  mov rdi, 1
  syscall
