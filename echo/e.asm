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
%define POLLOUT 0x0004

;; fcntl flags (F_SETFL is used to set the file descriptor flags)
%define F_SETFL 4
%define O_NONBLOCK 0x800        ; non block flag on linux

;; max no. of connections allowed
%define MAX_EVENTS 128

;; error values
%define POLLERR 0x0008
%define POLLHUP 0x0010

;; struc for each client connection
struc client_data
    .read_buffer:   resb 1024
    .write_buffer:  resb 1024
    .write_count:   resq 1
    .write_offset:  resq 1
endstruc

section .bss
  ;; pollfds array: each entry is 8 bytes:
  ;;   4 bytes: file descriptor (int)
  ;;   2 bytes: events (short)
  ;;   2 bytes: revents (short)
  pollfds resb MAX_EVENTS * 8

  sock resq 1                   ; listening socket
  nfds resq 1                   ; no. of valid pollfd entries currently in use

  clients resb MAX_EVENTS * client_data_size ; Per-client buffers

section .data
  client_data_dummy:  istruc client_data
  iend

  client_data_size equ $ - client_data_dummy

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
  jz check_clients

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
  jz check_clients

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

  jmp check_clients

.close_client_new:
  mov rax, SYS_CLOSE
  mov rdi, r10
  syscall

check_clients:
  ;; iterate over client sockets (pollfds indices 1..nfds-1)
  mov rbx, 1

client_loop:
  cmp rbx, [nfds]
  jge poll_loop

  ;; Get pollfd entry
  mov r8, rbx
  shl r8, 3
  lea r9, [pollfds + r8]

  ;; Get client data (index = rbx - 1)
  mov r15, rbx
  dec r15 ; 0-based client index
  imul r15, client_data_size
  lea r14, [clients + r15]

  ;; Check events
  movzx eax, word [r9 + 6]
  test eax, POLLIN
  jnz handle_read
  test eax, POLLOUT
  jnz handle_write
  test eax, (POLLERR | POLLHUP)
  jnz close_client

  inc rbx ; Move to next client
  jmp client_loop

handle_read:
  ;; Read into client's read buffer
  mov rax, SYS_READ
  mov edi, [r9]
  lea rsi, [r14 + client_data.read_buffer]
  mov rdx, 1024
  syscall

  test rax, rax
  jle close_client

  ;; Check for "q\n" command
  cmp rax, 2
  jne .copy_to_write
  cmp byte [r14 + client_data.read_buffer], 'q'
  jne .copy_to_write
  cmp byte [r14 + client_data.read_buffer + 1], 0x0a
  je close_client

.copy_to_write:
  ;; Copy to write buffer
  mov rcx, rax
  lea rdi, [r14 + client_data.write_buffer]
  lea rsi, [r14 + client_data.read_buffer]
  rep movsb

  mov [r14 + client_data.write_count], rax
  mov qword [r14 + client_data.write_offset], 0

  ;; Enable POLLOUT monitoring
  or word [r9 + 4], POLLOUT
  jmp next_client

handle_write:
  ;; get write params
  mov rcx, [r14 + client_data.write_count]
  mov rdx, [r14 + client_data.write_offset]

  cmp rcx, rdx
  je write_done

  sub rcx, rdx
  lea rsi, [r14 + client_data.write_buffer + rdx]
  mov edi, [r9]

  mov rax, SYS_WRITE
  mov rdx, rcx
  syscall

  test rax, rax
  jle close_client

  add [r14 + client_data.write_offset], rax
  jmp next_client

write_done:
  ;; disable POLLOUT monitoring
  and word [r9 + 4], ~POLLOUT
  jmp next_client

close_client:
  ;; close the client socket
  mov rax, SYS_CLOSE
  mov edi, dword [r9]           ; client fd
  syscall

  ;; remove client from `pollfds` by replacing it with the last one
  mov r10, qword [nfds]
  dec r10                       ; last index (nfds -= 1)

  ;; if this is already the last entry, just decrement nfds
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

  ;; Do not increment rbx here as the current slot has new data
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
