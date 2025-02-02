;;
;; An event driven, non blocking echo server in x86
;; assembly w/ nasm.
;;

global _start

%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_CLOSE 3
%define SYS_POLL 7
%define SYS_SOCKET 41
%define SYS_ACCEPT 43
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_EXIT 60
%define SYS_FCNTL 72

%define MAX_CLIENTS 1024
%define POLLIN 0x0001
%define POLLOUT 0x0004
%define POLLERR 0x0008
%define F_SETFL 3
%define O_NONBLOCK 0x4000

section .text
_start:
  mov rax, SYS_EXIT
  mov rdi, 0
  syscall
