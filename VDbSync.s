	.file "VDbSync.pas"
# Begin asmlist al_procedures

.section .text.n_vdbsync_$$_vdbflushstream$tfilestream,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBFLUSHSTREAM$TFILESTREAM
VDBSYNC_$$_VDBFLUSHSTREAM$TFILESTREAM:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-4(%esp),%esp
	movl	%eax,-4(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj5
	jmp	.Lj6
.Lj5:
	jmp	.Lj3
	.balign 4,0x90
.Lj6:
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$FlushFileBuffers
	testl	%eax,%eax
	je	.Lj7
	jmp	.Lj8
.Lj7:
	call	SYSUTILS_$$_RAISELASTOSERROR
	.balign 4,0x90
.Lj8:
.Lj3:
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbflushdir$ansistring$$boolean,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBFLUSHDIR$ANSISTRING$$BOOLEAN
VDBSYNC_$$_VDBFLUSHDIR$ANSISTRING$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-8(%esp),%esp
	movl	%eax,-4(%ebp)
	movb	$1,-8(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj11
	jmp	.Lj12
.Lj11:
	jmp	.Lj9
	.balign 4,0x90
.Lj12:
.Lj9:
	movb	-8(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdblockstream$tfilestream$$boolean,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBLOCKSTREAM$TFILESTREAM$$BOOLEAN
VDBSYNC_$$_VDBLOCKSTREAM$TFILESTREAM$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-28(%esp),%esp
	movl	%eax,-4(%ebp)
	movb	$0,-8(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj15
	jmp	.Lj16
.Lj15:
	jmp	.Lj13
	.balign 4,0x90
.Lj16:
	leal	-28(%ebp),%eax
	movb	$0,%cl
	movl	$20,%edx
	call	SYSTEM_$$_FILLCHAR$formal$LONGINT$BYTE
	leal	-28(%ebp),%eax
	pushl	%eax
	pushl	$-1
	pushl	$-1
	pushl	$0
	pushl	$3
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$LockFileEx
	orl	%eax,%eax
	setneb	%al
	movb	%al,-8(%ebp)
.Lj13:
	movb	-8(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbunlockstream$tfilestream,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBUNLOCKSTREAM$TFILESTREAM
VDBSYNC_$$_VDBUNLOCKSTREAM$TFILESTREAM:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-24(%esp),%esp
	movl	%eax,-4(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj19
	jmp	.Lj20
.Lj19:
	jmp	.Lj17
	.balign 4,0x90
.Lj20:
	leal	-24(%ebp),%eax
	movb	$0,%cl
	movl	$20,%edx
	call	SYSTEM_$$_FILLCHAR$formal$LONGINT$BYTE
	leal	-24(%ebp),%eax
	pushl	%eax
	pushl	$-1
	pushl	$-1
	pushl	$0
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$UnlockFileEx
.Lj17:
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbissharingviolation$tobject$$boolean,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBISSHARINGVIOLATION$TOBJECT$$BOOLEAN
VDBSYNC_$$_VDBISSHARINGVIOLATION$TOBJECT$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-12(%esp),%esp
	movl	%eax,-4(%ebp)
	movb	$0,-8(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj23
	jmp	.Lj24
.Lj23:
	jmp	.Lj21
	.balign 4,0x90
.Lj24:
	call	_$dll$kernel32$GetLastError
	movl	%eax,-12(%ebp)
	cmpl	$32,-12(%ebp)
	je	.Lj25
	jmp	.Lj26
.Lj26:
	cmpl	$33,-12(%ebp)
	je	.Lj25
	jmp	.Lj27
.Lj25:
	movb	$1,-8(%ebp)
	jmp	.Lj28
.Lj27:
	movb	$0,-8(%ebp)
.Lj28:
.Lj21:
	movb	-8(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret
# End asmlist al_procedures

