;;
;; An event driven, non blocking echo server in x86
;; assembly w/ nasm.
;;

global _start

%define SYS_EXIT 60

section .text
_start:
  mov rax, SYS_EXIT
  mov rdi, 0
  syscall
