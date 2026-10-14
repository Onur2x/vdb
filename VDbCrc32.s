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
	movl	-4(%ebp),%eax
	movl	-12(%ebp),%edx
	movl	%edx,U_$VDBCRC32_$$_T0(,%eax,4)
	cmpl	$255,-4(%ebp)
	jge	.Lj7
	jmp	.Lj5
.Lj7:
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
	jle	.Lj18
	jmp	.Lj19
.Lj19:
	cmpl	$0,-8(%ebp)
	je	.Lj18
	jmp	.Lj20
.Lj18:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
	jmp	.Lj16
	.balign 4,0x90
.Lj20:
	movl	-12(%ebp),%eax
	leal	-1(%eax),%eax
	cmpl	$0,%eax
	jge	.Lj21
	jmp	.Lj22
.Lj21:
	movl	$-1,-20(%ebp)
	.balign 8,0x90
.Lj23:
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
	xorl	U_$VDBCRC32_$$_T0(,%edx,4),%ecx
	movl	%ecx,-4(%ebp)
	cmpl	-20(%ebp),%eax
	jle	.Lj25
	jmp	.Lj23
.Lj25:
	.balign 4,0x90
.Lj22:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
.Lj16:
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
	jle	.Lj28
	jmp	.Lj29
.Lj29:
	movl	-8(%ebp),%eax
	testl	%eax,%eax
	je	.Lj31
	movl	-4(%eax),%eax
	addl	$1,%eax
.Lj31:
	testl	$-1,%eax
	je	.Lj28
	jmp	.Lj30
.Lj28:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
	jmp	.Lj26
	.balign 4,0x90
.Lj30:
	movl	-8(%ebp),%eax
	testl	%eax,%eax
	je	.Lj32
	movl	-4(%eax),%eax
	addl	$1,%eax
.Lj32:
	cmpl	-12(%ebp),%eax
	jl	.Lj33
	jmp	.Lj34
.Lj33:
	movl	-8(%ebp),%eax
	testl	%eax,%eax
	je	.Lj35
	movl	-4(%eax),%eax
	addl	$1,%eax
.Lj35:
	movl	%eax,-12(%ebp)
	.balign 4,0x90
.Lj34:
	movl	-8(%ebp),%edx
	movl	-12(%ebp),%ecx
	movl	-4(%ebp),%eax
	call	VDBCRC32_$$_VDBCRC32UPDATEPTR$LONGWORD$PBYTE$LONGINT$$LONGWORD
	movl	%eax,-16(%ebp)
.Lj26:
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
	jle	.Lj38
	jmp	.Lj39
.Lj38:
	movl	-4(%ebp),%eax
	movl	%eax,-16(%ebp)
	jmp	.Lj36
	.balign 4,0x90
.Lj39:
	movl	-8(%ebp),%edx
	movl	-12(%ebp),%ecx
	movl	-4(%ebp),%eax
	call	VDBCRC32_$$_VDBCRC32UPDATEPTR$LONGWORD$PBYTE$LONGINT$$LONGWORD
	movl	%eax,-16(%ebp)
.Lj36:
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
	jle	.Lj42
	jmp	.Lj43
.Lj42:
	movl	$0,-12(%ebp)
	jmp	.Lj40
	.balign 4,0x90
.Lj43:
	movl	-8(%ebp),%ecx
	movl	-4(%ebp),%edx
	movl	$-1,%eax
	call	VDBCRC32_$$_VDBCRC32UPDATEBYTES$LONGWORD$TBYTES$LONGINT$$LONGWORD
	notl	%eax
	movl	%eax,-12(%ebp)
.Lj40:
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
	jle	.Lj46
	jmp	.Lj47
.Lj46:
	movl	$0,-12(%ebp)
	jmp	.Lj44
	.balign 4,0x90
.Lj47:
	movl	-4(%ebp),%eax
	movl	%eax,%edx
	movl	-8(%ebp),%ecx
	movl	$-1,%eax
	call	VDBCRC32_$$_VDBCRC32UPDATE$LONGWORD$formal$LONGINT$$LONGWORD
	notl	%eax
	movl	%eax,-12(%ebp)
.Lj44:
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
U_$VDBCRC32_$$_T0:
	.zero 1024
# End asmlist al_globals

