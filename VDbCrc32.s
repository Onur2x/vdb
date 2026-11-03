	.file "VDbCrc32.pas"
# Begin asmlist al_procedures

.section .text.n_vdbcrc32_$$_buildtbl,"x"
	.balign 16,0x90
VDBCRC32_$$_BUILDTBL:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-12(%esp),%esp
	movl	$-1,-4(%ebp)
	.balign 8,0x90
.Lj5:
	movl	-4(%ebp),%eax
	leal	1(%eax),%eax
	movl	%eax,-4(%ebp)
	movl	-4(%ebp),%eax
	movl	%eax,-12(%ebp)
	movl	$-1,-8(%ebp)
	.balign 8,0x90
.Lj8:
	movl	-8(%ebp),%eax
	leal	1(%eax),%eax
	movl	%eax,-8(%ebp)
	movl	-12(%ebp),%eax
	andl	$1,%eax
	testl	$-1,%eax
	jne	.Lj11
	jmp	.Lj12
.Lj11:
	movl	-12(%ebp),%eax
	shrl	$1,%eax
	xorl	$-306674912,%eax
	movl	%eax,-12(%ebp)
	jmp	.Lj13
.Lj12:
	movl	-12(%ebp),%eax
	shrl	$1,%eax
	movl	%eax,-12(%ebp)
.Lj13:
	cmpl	$7,-8(%ebp)
	jge	.Lj10
	jmp	.Lj8
.Lj10:
	movl	-4(%ebp),%edx
	movl	-12(%ebp),%eax
	movl	%eax,U_$VDBCRC32_$$_T(,%edx,4)
	cmpl	$255,-4(%ebp)
	jge	.Lj7
	jmp	.Lj5
.Lj7:
	movl	$0,-8(%ebp)
	.balign 8,0x90
.Lj14:
	movl	-8(%ebp),%eax
	leal	1(%eax),%eax
	movl	%eax,-8(%ebp)
	movl	$-1,-4(%ebp)
	.balign 8,0x90
.Lj17:
	movl	-4(%ebp),%eax
	leal	1(%eax),%eax
	movl	%eax,-4(%ebp)
	movl	-8(%ebp),%eax
	leal	-1(%eax),%eax
	shll	$10,%eax
	movl	-4(%ebp),%edx
	movl	U_$VDBCRC32_$$_T(%eax,%edx,4),%eax
	andl	$255,%eax
	movl	-8(%ebp),%edx
	leal	-1(%edx),%edx
	shll	$10,%edx
	movl	-4(%ebp),%ecx
	movl	U_$VDBCRC32_$$_T(%edx,%ecx,4),%edx
	shrl	$8,%edx
	xorl	U_$VDBCRC32_$$_T(,%eax,4),%edx
	movl	-8(%ebp),%eax
	shll	$10,%eax
	movl	-4(%ebp),%ecx
	movl	%edx,U_$VDBCRC32_$$_T(%eax,%ecx,4)
	cmpl	$255,-4(%ebp)
	jge	.Lj19
	jmp	.Lj17
.Lj19:
	cmpl	$7,-8(%ebp)
	jge	.Lj16
	jmp	.Lj14
.Lj16:
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32init$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32INIT$$LONGWORD
VDBCRC32_$$_VDBCRC32INIT$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-4(%esp),%esp
	movl	$-1,-4(%ebp)
	movl	-4(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32updateptrslow$longword$pbyte$longint$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32UPDATEPTRSLOW$LONGWORD$PBYTE$LONGINT$$LONGWORD
VDBCRC32_$$_VDBCRC32UPDATEPTRSLOW$LONGWORD$PBYTE$LONGINT$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-20(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	%edx,-8(%ebp)
	movl	%ecx,-12(%ebp)
	cmpl	$0,-12(%ebp)
	jle	.Lj24
	jmp	.Lj25
.Lj25:
	cmpl	$0,-8(%ebp)
	je	.Lj24
	jmp	.Lj26
.Lj24:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
	jmp	.Lj22
	.balign 4,0x90
.Lj26:
	movl	-12(%ebp),%eax
	leal	-1(%eax),%eax
	cmpl	$0,%eax
	jge	.Lj27
	jmp	.Lj28
.Lj27:
	movl	$-1,-20(%ebp)
	.balign 8,0x90
.Lj29:
	movl	-20(%ebp),%edx
	leal	1(%edx),%edx
	movl	%edx,-20(%ebp)
	movl	-8(%ebp),%ecx
	movl	-20(%ebp),%edx
	movzbl	(%ecx,%edx,1),%edx
	xorl	-4(%ebp),%edx
	movzbl	%dl,%edx
	movl	-4(%ebp),%ecx
	shrl	$8,%ecx
	xorl	U_$VDBCRC32_$$_T(,%edx,4),%ecx
	movl	%ecx,-4(%ebp)
	cmpl	-20(%ebp),%eax
	jle	.Lj31
	jmp	.Lj29
.Lj31:
	.balign 4,0x90
.Lj28:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
.Lj22:
	movl	-16(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32updateptr$longword$pbyte$longint$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32UPDATEPTR$LONGWORD$PBYTE$LONGINT$$LONGWORD
VDBCRC32_$$_VDBCRC32UPDATEPTR$LONGWORD$PBYTE$LONGINT$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-20(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	%edx,-8(%ebp)
	movl	%ecx,-12(%ebp)
	cmpl	$0,-12(%ebp)
	jle	.Lj34
	jmp	.Lj35
.Lj35:
	cmpl	$0,-8(%ebp)
	je	.Lj34
	jmp	.Lj36
.Lj34:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
	jmp	.Lj32
	.balign 4,0x90
.Lj36:
	jmp	.Lj38
	.balign 8,0x90
.Lj37:
	movl	-8(%ebp),%eax
	leal	-20(%ebp),%edx
	movl	$4,%ecx
	call	SYSTEM_$$_MOVE$formal$formal$LONGINT
	movl	-4(%ebp),%edx
	movl	-20(%ebp),%eax
	xorl	%edx,%eax
	movl	%eax,-4(%ebp)
	movl	-4(%ebp),%eax
	shrl	$8,%eax
	andl	$255,%eax
	movl	-4(%ebp),%edx
	andl	$255,%edx
	movl	U_$VDBCRC32_$$_T+6144(,%eax,4),%ecx
	movl	U_$VDBCRC32_$$_T+7168(,%edx,4),%eax
	xorl	%ecx,%eax
	movl	-4(%ebp),%edx
	shrl	$16,%edx
	andl	$255,%edx
	xorl	U_$VDBCRC32_$$_T+5120(,%edx,4),%eax
	movl	-4(%ebp),%edx
	shrl	$24,%edx
	andl	$255,%edx
	xorl	U_$VDBCRC32_$$_T+4096(,%edx,4),%eax
	movl	-8(%ebp),%edx
	movzbl	4(%edx),%edx
	xorl	U_$VDBCRC32_$$_T+3072(,%edx,4),%eax
	movl	-8(%ebp),%edx
	movzbl	5(%edx),%edx
	xorl	U_$VDBCRC32_$$_T+2048(,%edx,4),%eax
	movl	-8(%ebp),%edx
	movzbl	6(%edx),%edx
	xorl	U_$VDBCRC32_$$_T+1024(,%edx,4),%eax
	movl	-8(%ebp),%edx
	movzbl	7(%edx),%edx
	xorl	U_$VDBCRC32_$$_T(,%edx,4),%eax
	movl	%eax,-4(%ebp)
	addl	$8,-8(%ebp)
	subl	$8,-12(%ebp)
.Lj38:
	cmpl	$8,-12(%ebp)
	jge	.Lj37
	jmp	.Lj39
.Lj39:
	jmp	.Lj41
	.balign 8,0x90
.Lj40:
	movl	-8(%ebp),%eax
	movzbl	(%eax),%eax
	xorl	-4(%ebp),%eax
	movzbl	%al,%eax
	movl	-4(%ebp),%edx
	shrl	$8,%edx
	xorl	U_$VDBCRC32_$$_T(,%eax,4),%edx
	movl	%edx,-4(%ebp)
	addl	$1,-8(%ebp)
	subl	$1,-12(%ebp)
.Lj41:
	cmpl	$0,-12(%ebp)
	jg	.Lj40
	jmp	.Lj42
.Lj42:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
.Lj32:
	movl	-16(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32updatebytes$longword$tbytes$longint$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32UPDATEBYTES$LONGWORD$TBYTES$LONGINT$$LONGWORD
VDBCRC32_$$_VDBCRC32UPDATEBYTES$LONGWORD$TBYTES$LONGINT$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-16(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	%edx,-8(%ebp)
	movl	%ecx,-12(%ebp)
	cmpl	$0,-12(%ebp)
	jle	.Lj45
	jmp	.Lj46
.Lj46:
	movl	-8(%ebp),%eax
	testl	%eax,%eax
	je	.Lj48
	movl	-4(%eax),%eax
	addl	$1,%eax
.Lj48:
	testl	$-1,%eax
	je	.Lj45
	jmp	.Lj47
.Lj45:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
	jmp	.Lj43
	.balign 4,0x90
.Lj47:
	movl	-8(%ebp),%eax
	testl	%eax,%eax
	je	.Lj49
	movl	-4(%eax),%eax
	addl	$1,%eax
.Lj49:
	cmpl	-12(%ebp),%eax
	jl	.Lj50
	jmp	.Lj51
.Lj50:
	movl	-8(%ebp),%eax
	testl	%eax,%eax
	je	.Lj52
	movl	-4(%eax),%eax
	addl	$1,%eax
.Lj52:
	movl	%eax,-12(%ebp)
	.balign 4,0x90
.Lj51:
	movl	-8(%ebp),%edx
	movl	-12(%ebp),%ecx
	movl	-4(%ebp),%eax
	call	VDBCRC32_$$_VDBCRC32UPDATEPTR$LONGWORD$PBYTE$LONGINT$$LONGWORD
	movl	%eax,-16(%ebp)
.Lj43:
	movl	-16(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32update$longword$formal$longint$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32UPDATE$LONGWORD$formal$LONGINT$$LONGWORD
VDBCRC32_$$_VDBCRC32UPDATE$LONGWORD$formal$LONGINT$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-16(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	%edx,-8(%ebp)
	movl	%ecx,-12(%ebp)
	cmpl	$0,-12(%ebp)
	jle	.Lj55
	jmp	.Lj56
.Lj55:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
	jmp	.Lj53
	.balign 4,0x90
.Lj56:
	movl	-8(%ebp),%edx
	movl	-12(%ebp),%ecx
	movl	-4(%ebp),%eax
	call	VDBCRC32_$$_VDBCRC32UPDATEPTR$LONGWORD$PBYTE$LONGINT$$LONGWORD
	movl	%eax,-16(%ebp)
.Lj53:
	movl	-16(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32ofbytes$tbytes$longint$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32OFBYTES$TBYTES$LONGINT$$LONGWORD
VDBCRC32_$$_VDBCRC32OFBYTES$TBYTES$LONGINT$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-12(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	%edx,-8(%ebp)
	cmpl	$0,-8(%ebp)
	jle	.Lj59
	jmp	.Lj60
.Lj59:
	movl	$0,-12(%ebp)
	jmp	.Lj57
	.balign 4,0x90
.Lj60:
	movl	-8(%ebp),%ecx
	movl	-4(%ebp),%edx
	movl	$-1,%eax
	call	VDBCRC32_$$_VDBCRC32UPDATEBYTES$LONGWORD$TBYTES$LONGINT$$LONGWORD
	notl	%eax
	movl	%eax,-12(%ebp)
.Lj57:
	movl	-12(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32of$formal$longint$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32OF$formal$LONGINT$$LONGWORD
VDBCRC32_$$_VDBCRC32OF$formal$LONGINT$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-12(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	%edx,-8(%ebp)
	cmpl	$0,-8(%ebp)
	jle	.Lj63
	jmp	.Lj64
.Lj63:
	movl	$0,-12(%ebp)
	jmp	.Lj61
	.balign 4,0x90
.Lj64:
	movl	-4(%ebp),%eax
	movl	%eax,%edx
	movl	-8(%ebp),%ecx
	movl	$-1,%eax
	call	VDBCRC32_$$_VDBCRC32UPDATE$LONGWORD$formal$LONGINT$$LONGWORD
	notl	%eax
	movl	%eax,-12(%ebp)
.Lj61:
	movl	-12(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbcrc32_$$_vdbcrc32final$longword$$longword,"x"
	.balign 16,0x90
.globl	VDBCRC32_$$_VDBCRC32FINAL$LONGWORD$$LONGWORD
VDBCRC32_$$_VDBCRC32FINAL$LONGWORD$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-8(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	-4(%ebp),%eax
	notl	%eax
	movl	%eax,-8(%ebp)
	movl	-8(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n__vdbcrc32_$$_init$,"x"
	.balign 16,0x90
.globl	INIT$_$VDBCRC32
INIT$_$VDBCRC32:
.globl	_VDBCRC32_$$_init$
_VDBCRC32_$$_init$:
	pushl	%ebp
	movl	%esp,%ebp
	call	VDBCRC32_$$_BUILDTBL
	movl	%ebp,%esp
	popl	%ebp
	ret
# End asmlist al_procedures
# Begin asmlist al_globals

.section .bss
	.balign 4
U_$VDBCRC32_$$_T:
	.zero 8192
# End asmlist al_globals

