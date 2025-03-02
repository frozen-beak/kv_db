global _start

%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_CLOSE 3
%define SYS_POLL 7
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_SETSOCKOPT 54
%define SYS_LISTEN 50
%define SYS_EXIT 60
%define SYS_FCNTL 72

%define SOL_SOCKET 1
%define SO_REUSEADDR 2
%define POLLIN 0x0001
%define POLLOUT 0x0004
%define POLLERR 0x0008
%define POLLHUP 0x0010
%define F_SETFL 4
%define O_NONBLOCK 0x800
%define MAX_EVENTS 128
%define BUFFER_SIZE 1024

section .bss
  pollfds resb MAX_EVENTS * 8
  sock resq 1
  nfds resq 1
  buffer resb BUFFER_SIZE
  read_buffer resb MAX_EVENTS * BUFFER_SIZE
  write_buffer resb MAX_EVENTS * BUFFER_SIZE
  read_offsets resq MAX_EVENTS
  write_offsets resq MAX_EVENTS
  write_lengths resq MAX_EVENTS

section .data
  reuseaddr_val dd 1
  sockaddr_in:
      dw 2
      dw 0x391B
      dd 0
      dq 0

section .text
_start:
  ; Create socket
  mov rax, SYS_SOCKET
  mov rdi, 2
  mov rsi, 1
  xor rdx, rdx
  syscall
  test rax, rax
  js exit
  mov [sock], rax

  ; Set socket options
  mov rax, SYS_SETSOCKOPT
  mov rdi, [sock]
  mov rsi, SOL_SOCKET
  mov rdx, SO_REUSEADDR
  lea r10, [reuseaddr_val]
  mov r8, 4
  syscall
  test rax, rax
  js exit

  ; Bind socket
  mov rax, SYS_BIND
  mov rdi, [sock]
  lea rsi, [sockaddr_in]
  mov rdx, 16
  syscall
  test rax, rax
  js exit

  ; Listen
  mov rax, SYS_LISTEN
  mov rdi, [sock]
  mov rsi, MAX_EVENTS
  syscall
  test rax, rax
  js exit

  ; Non-blocking
  mov rax, SYS_FCNTL
  mov rdi, [sock]
  mov rsi, F_SETFL
  mov rdx, O_NONBLOCK
  syscall

  ; Init pollfds
  mov eax, dword [sock]
  mov dword [pollfds], eax
  mov word [pollfds+4], POLLIN
  mov word [pollfds+6], 0
  mov qword [nfds], 1

poll_loop:
  mov rax, SYS_POLL
  lea rdi, [pollfds]
  mov rsi, [nfds]
  mov rdx, -1
  syscall
  test rax, rax
  js exit

  ; Check listening socket
  movzx eax, word [pollfds+6]
  test eax, POLLIN
  jz process_clients

  ; Accept new connection
  mov rax, SYS_ACCEPT
  mov rdi, [sock]
  xor rsi, rsi
  xor rdx, rdx
  syscall
  cmp rax, 0
  jl process_clients
  mov r10, rax

  ; Set non-blocking
  mov rax, SYS_FCNTL
  mov rdi, r10
  mov rsi, F_SETFL
  mov rdx, O_NONBLOCK
  syscall

  ; Add to pollfds
  mov rbx, [nfds]
  cmp rbx, MAX_EVENTS
  jae .close_client
  mov r8, rbx
  shl r8, 3
  lea r9, [pollfds+r8]
  mov [r9], r10d
  mov word [r9+4], POLLIN
  mov word [r9+6], 0

  ; Init buffers
  mov qword [read_offsets+rbx*8], 0
  mov qword [write_offsets+rbx*8], 0
  mov qword [write_lengths+rbx*8], 0
  inc qword [nfds]
  jmp process_clients

.close_client:
  mov rax, SYS_CLOSE
  mov rdi, r10
  syscall

process_clients:
  mov rbx, 1

client_loop:
  mov rax, [nfds]
  cmp rbx, rax
  jge poll_loop

  mov r8, rbx
  shl r8, 3
  lea r9, [pollfds+r8]
  movzx eax, word [r9+6]

  ; Check errors
  test eax, POLLERR|POLLHUP
  jnz remove_client

  ; Check POLLIN
  test eax, POLLIN
  jnz handle_read

  ; Check POLLOUT
  test eax, POLLOUT
  jnz handle_write
  jmp next_client

handle_read:
  ; Read data
  mov rax, SYS_READ
  mov edi, dword [r9]
  lea rsi, [buffer]
  mov rdx, BUFFER_SIZE
  syscall

  ; Handle read results
  cmp rax, 0
  jl read_error
  je remove_client

  ; Copy to write buffer
  mov rcx, [write_offsets+rbx*8]
  add rcx, [write_lengths+rbx*8]
  cmp rcx, BUFFER_SIZE
  jae remove_client ; Buffer full

  mov rax, rbx
  imul rax, BUFFER_SIZE
  lea rdi, [write_buffer+rax]
  add rdi, [write_offsets+rbx*8]
  add rdi, [write_lengths+rbx*8]
  lea rsi, [buffer]
  mov rcx, rax
  rep movsb

  ; Update write length
  add [write_lengths+rbx*8], rax

  ; Enable POLLOUT
  or word [r9+4], POLLOUT
  jmp handle_write_after_read

read_error:
  cmp rax, -11 ; EAGAIN
  jne remove_client
  jmp next_client

handle_write:
  ; Get write params
  mov rcx, [write_lengths+rbx*8]
  test rcx, rcx
  jz clear_pollout

  ; Prepare write
  mov rax, rbx
  imul rax, BUFFER_SIZE
  lea rsi, [write_buffer+rax]
  add rsi, [write_offsets+rbx*8]
  mov rax, SYS_WRITE
  mov edi, dword [r9]
  mov rdx, rcx
  syscall

  ; Handle write results
  cmp rax, 0
  jl write_error

  ; Update buffers
  sub [write_lengths+rbx*8], rax
  add [write_offsets+rbx*8], rax

  ; Check if done
  cmp qword [write_lengths+rbx*8], 0
  jne next_client
  mov qword [write_offsets+rbx*8], 0
  and word [r9+4], ~POLLOUT
  jmp next_client

write_error:
  cmp rax, -11 ; EAGAIN
  je next_client

remove_client:
  ; Close socket
  mov rax, SYS_CLOSE
  mov edi, dword [r9]
  syscall

  ; Replace with last entry
  mov r10, [nfds]
  dec r10
  cmp rbx, r10
  je .decrement

  ; Copy pollfd
  mov r11, r10
  shl r11, 3
  mov rax, [pollfds+r11]
  mov [pollfds+r8], rax

  ; Copy buffers
  ; Read buffer
  mov rax, r10
  imul rax, BUFFER_SIZE
  lea rsi, [read_buffer+rax]

  mov rax, rbx
  imul rax, BUFFER_SIZE
  lea rdi, [read_buffer+rax]

  mov rcx, BUFFER_SIZE
  rep movsb

  ; Write buffer
  mov rax, r10
  imul rax, BUFFER_SIZE
  lea rsi, [write_buffer+rax]

  mov rax, rbx
  imul rax, BUFFER_SIZE
  lea rdi, [write_buffer+rax]

  mov rcx, BUFFER_SIZE
  rep movsb

  ; Copy metadata
  mov rax, [read_offsets+r10*8]
  mov [read_offsets+rbx*8], rax
  mov rax, [write_offsets+r10*8]
  mov [write_offsets+rbx*8], rax
  mov rax, [write_lengths+r10*8]
  mov [write_lengths+rbx*8], rax

.decrement:
  mov [nfds], r10
  jmp client_loop_continue

handle_write_after_read:
  ; Same as handle_write but after read
  jmp handle_write

clear_pollout:
  and word [r9+4], ~POLLOUT
  jmp next_client

next_client:
  inc rbx

client_loop_continue:
  jmp client_loop

exit:
  mov rax, SYS_EXIT
  mov rdi, 0
  syscall
