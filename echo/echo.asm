global _start

%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_CLOSE 3
%define SYS_POLL 7
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_SETSOCKETOPT 54
%define SYS_LISTEN 50
%define SYS_EXIT 60
%define SYS_FCNTL 72

;; socket options constants
%define SOL_SOCKET 1
%define SO_REUSEADDR 2

;; poll(2) events (the pollfd struct has: int fd, short events, short revents)
%define POLLIN 0x0001

;; fcntl flags (F_SETFL is used to set the file descriptor flags)
%define F_SETFL 4
%define O_NONBLOCK 0x800        ; non block flag on linux

;; max no. of connections allowed
%define MAX_EVENTS 128

;; error values
%define POLLERR 0x0008
%define POLLHUP 0x0010

section .bss
  ;; pollfds array: each entry is 8 bytes:
  ;;   4 bytes: file descriptor (int)
  ;;   2 bytes: events (short)
  ;;   2 bytes: revents (short)
  pollfds resb MAX_EVENTS * 8

  sock resq 1                   ; listening socket
  nfds resq 1                   ; no. of valid pollfd entries currently in use
  buffer resb 1024              ; temp data buffer

section .data
  reuseaddr_val dd 1            ; int (VALUE = 1) for setsocketopt()

  ;;
  ;; `sockaddr_in` struct (16 bytes) w/ IPv4 port 6969 and INADDR_ANY
  ;;
  ;; struct:
  ;;
  ;;   sa_family:   2 bytes
  ;;   sin_port:    2 bytes
  ;;   sin_addr:    4 bytes
  ;;   padding:     8 bytes
  ;;
  sockaddr_in:
      dw 2                           ; AF_INET
      dw 0x391B                      ; port 6969 in big-endian (0x391B => 6969)
      dd 0                           ; sin_addr (INADDR_ANY)
      dq 0                           ; padding (8 bytes)

section .text
_start:
  ;;
  ;; create a listening socket
  ;;
  ;; `socket(AF_INET, SOCK_STREAM, 0)`
  ;;
  mov rax, SYS_SOCKET
  mov rdi, 2                    ; AF_INET
  mov rsi, 1                    ; SOCK_STREAM
  xor rdx, rdx                  ; protocol(0)
  syscall

  ;; check for socket errors
  test rax, rax
  js exit

  ;; save socket fd
  mov [sock], rax

  ;;
  ;; set socket options
  ;;
  ;; `setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseaddr_val, 4)`
  ;;
  mov rax, SYS_SETSOCKETOPT
  mov rdi, [sock]               ; socket fd
  mov rsi, SOL_SOCKET           ; level
  mov rdx, SO_REUSEADDR         ; option name
  lea r10, [reuseaddr_val]      ; pointer to the value
  mov r8, 4
  syscall

  ;; check for `setsocketopt` errors
  test rax, rax
  js exit

  ;;
  ;; bind the socket
  ;;
  ;; `bind(sock, sockaddr_in, 16)`
  ;;
  mov rax, SYS_BIND
  mov rdi, [sock]
  lea rsi, [sockaddr_in]
  mov rdx, 16
  syscall

  ;; check for bind errors
  test rax, rax
  js exit

  ;;
  ;; listen to socket
  ;;
  mov rax, SYS_LISTEN
  mov rdi, [sock]
  mov rsi, MAX_EVENTS
  syscall

  ;; check for listen errors
  cmp rax, 0
  jl exit

  ;;
  ;; set the listening socket to nonblocking
  ;;
  mov rax, SYS_FCNTL
  mov rdi, [sock]
  mov rsi, F_SETFL
  mov rdx, O_NONBLOCK
  syscall

  ;;
  ;; init the `pollfd` array
  ;;
  ;; - Put the listening socket at 0th index
  ;; - And set fallowing options for it
  ;;   - .fd = sock
  ;;   - .events = POLLIN,
  ;;   - .revents = 0
  ;;
  mov eax, dword [sock]
  mov dword [pollfds], eax         ; fd = sock
  mov word [pollfds + 4], POLLIN   ; events = POLLIN (should listen)
  mov word [pollfds + 6], 0        ; revents = 0

  ;; update the count to 1
  mov qword [nfds], 1           ; nfds = 1

poll_loop:
  ;;
  ;; call poll (infinite timeoue i.e. -1)
  ;;
  ;; `poll(pollfds, nfds, timeout=-1)`
  ;;
  mov rax, SYS_POLL
  lea rdi, [pollfds]
  mov rsi, qword [nfds]
  mov rdx, -1
  syscall

  ;; check for `poll` errors
  test rax, rax
  js exit

  ;; check if listening socket has an event
  movzx eax, word [pollfds + 6] ; revents of listening socket i.e. pollfds[0]
  test eax, POLLIN
  jz skip_accept

  ;;
  ;; accept new connection
  ;;
  ;; `accept(sock, NULL, NULL)`
  ;;
  mov rax, SYS_ACCEPT
  mov rdi, [sock]
  xor rsi, rsi
  xor rdx, rdx
  syscall

  ;; check for accept errors
  cmp rax, 0
  jz skip_accept

  ;; save new client fd in r10
  mov r10, rax

  ;; set the new client connection to non-blocking
  mov rax, SYS_FCNTL
  mov rdi, r10
  mov rsi, F_SETFL
  mov rdx, O_NONBLOCK
  syscall

  ;;
  ;; add new client connection to `pollfds` array
  ;;
  ;; first need ti check if the MAX_EVENTS limit is reached
  ;; or not
  ;;

  mov rbx, qword [nfds]         ; current connection count

  ;; check if MAX_EVENTS limit is reached
  cmp rbx, MAX_EVENTS
  jae .close_client_new         ; if too many, close the new connection

  ;;
  ;; calculate index of new connection for `pollfds`
  ;;
  ;; formula -> `pollfds + (rbx * 8)`
  ;;
  mov r8, rbx
  shl r8, 3
  lea r9, [pollfds + r8]
  mov dword [r9], r10d          ; new clients fd
  mov word [r9 + 4], POLLIN     ; events = POLLIN
  mov word [r9 + 6], 0          ; revents = 0

  ;; increment connection count
  inc qword [nfds]

  jmp skip_accept

.close_client_new:
  mov rax, SYS_CLOSE
  mov rdi, r10
  syscall

skip_accept:
  ;; iterate over client sockets (pollfds indices 1..nfds-1)
  mov rbx, 1

client_loop:
  ;; read current no. of connections
  mov rax, qword [nfds]

  ;; check if `nfds <= 1`, if yes exit the loop
  cmp rbx, rax
  jge poll_loop_end

  ;; calculate index of pollfds[rbx]
  ;;
  ;; offset = rbx * 8 (each pollfd is 8 bytes)
  ;;
  mov r8, rbx
  shl r8, 3
  lea r9, [pollfds + r8]

  ;; check if the current client has an event (revents & POLLIN)
  movzx eax, word [r9 + 6]
  test eax, POLLIN | POLLHUP | POLLERR
  jz next_client                ; continue to next client

  ;;
  ;; read from current client
  ;;
  ;; `read(fd, buffer, 1024)`
  ;;
  mov rax, SYS_READ
  mov edi, dword [r9]           ; client fd (using `dword` because pollfd.fd is 32-bit)
  lea rsi, [buffer]
  mov edx, 1024
  syscall

  ;; check for read errors (rax <= 0), can be err/EOF
  cmp rax, 0
  jle .remove_client

  ;; check if client wants to close the connection
  cmp rax, 1
  je .check_quit

  ;; check quit command with newline
  cmp rax, 2
  je .check_quit_newline

  jmp .echo_client

.check_quit:
  cmp byte [buffer], 'q'
  jne .echo_client

  jmp .remove_client

.check_quit_newline:
  cmp byte [buffer], 'q'
  jne .echo_client

  cmp byte [buffer + 1], 0x0a   ; check for newline character
  jne .echo_client

  jmp .remove_client

.echo_client:
  ;;
  ;; echo back to client
  ;;
  ;; `write(fd, buffer, <number of bytes read>)`
  ;;
  mov rdx, rax
  mov rax, SYS_WRITE
  mov edi, dword [r9]           ; client fd
  lea rsi, [buffer]
  syscall

  ;; check for write errors (rax <= 0)
  test rax, rax
  js .remove_client

  ;; continue the loop
  jmp next_client

.remove_client:
  ;; close the client socket
  mov rax, SYS_CLOSE
  mov edi, dword [r9]           ; client fd
  syscall

  ;; remove client from `pollfds` by replacing it w/ the last one
  mov r10, qword [nfds]
  dec r10                       ; last index (nfds -= 1)

  ;; if this is already an last entry, then just decrment the nfds
  cmp rbx, r10
  je .decrement_nfds

  mov r11, r10
  shl r11, 3
  lea r12, [pollfds + r11]

  ;; copy the last entry into current one
  mov rax, qword [r12]
  mov qword [r9], rax

.decrement_nfds:
  mov qword [nfds], r10         ; update the current count in memory

  ;; NOTE: Do not increment rbx here because a new entry has been
  ;; copied into the current slot.
  jmp client_loop_continue

next_client:
  inc rbx

client_loop_continue:
  jmp client_loop

poll_loop_end:
  jmp poll_loop

exit:
  mov rax, SYS_EXIT
  mov rdi, 1
  syscall
