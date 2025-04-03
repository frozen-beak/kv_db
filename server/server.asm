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

  ;; read header from the client fd
  mov rdi, [client_fd]
  lea rsi, [buffer]
  mov rdx, 4                    ; assume header to be a C INT i.e i32
  mov rax, SYS_READ
  syscall

  ;; write back to client fd
  lea rsi, [buffer]
  mov rdx, 4
  mov rdi, [client_fd]
  mov rax, SYS_WRITE
  syscall

  ;; fall through and close the client anyways

close_client:
  mov rax, SYS_CLOSE
  mov rdi, [client_fd]
  syscall

  jmp server_loop

;; reads exactly `n` bytes from conn fd into buffer
;;
;; args:
;;   rdi - client fd to read from
;;   rsi - buffer pointer
;;   rdx - `n` or no. of bytes to read
;;
;; ret:
;;   rax - 0 on success, -1 on EOF/error
read_full:
.read_loop:
  ;; check if `n` is 0
  cmp rdx, 0
  jle .done

  ;; read from client fd
  mov rax, SYS_READ
  syscall

  ;; check for read errors (rax < 0)
  test rax, rax
  js .error

  sub rdx, rax                  ; subtract no. of bytes read from `n`
  add rsi, rax                  ; advance buffer pointer by no. of bytes read

  jmp .read_loop
.done:
  mov rax, 0
  jmp .ret
.error:
  mov rax, -1
.ret:
  ret

;; write exactly `n` bytes from buf to conn fd
;;
;; args:
;;   rdi - clients fd
;;   rsi - pointer to buffer
;;   rdx - `n` or no of bytes to write
;;
;; ret:
;;   rax: 0 on success and -1 on error
write_all:
.write_loop:
  ;; check if `n` is 0
  cmp rdx, 0
  jle .done

  ;; write to client
  mov rax, SYS_WRITE
  syscall

  ;; check for write errors (rax < 0 && EOF)
  test rax, rax
  js .error

  sub rdx, rax                  ; subtract no. of bytes read from `n`
  add rsi, rax                  ; advance buffer pointer by no of bytes read

  jmp .write_loop
.done:
  mov rax, 0
  jmp .ret
.error:
  mov rax, -1
.ret:
  ret

error_exit:
  mov rax, SYS_EXIT
  mov rdi, 1
  syscall
