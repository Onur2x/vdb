	.file "VDbSync.pas"
# Begin asmlist al_procedures

.section .text.n_vdbsync_$$_lockbookinit,"x"
	.balign 16,0x90
VDBSYNC_$$_LOCKBOOKINIT:
	pushl	%ebp
	movl	%esp,%ebp
	cmpb	$0,TC_$VDBSYNC_$$_GLOCKINIT
	jne	.Lj5
	jmp	.Lj6
.Lj5:
	jmp	.Lj3
	.balign 4,0x90
.Lj6:
	movl	$U_$VDBSYNC_$$_GLOCKCS,%eax
	call	SYSTEM_$$_INITCRITICALSECTION$TRTLCRITICALSECTION
	movb	$1,TC_$VDBSYNC_$$_GLOCKINIT
.Lj3:
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_lockslotof$nativeuint$boolean$$longint,"x"
	.balign 16,0x90
VDBSYNC_$$_LOCKSLOTOF$NATIVEUINT$BOOLEAN$$LONGINT:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-20(%esp),%esp
	movl	%eax,-4(%ebp)
	movb	%dl,-8(%ebp)
	movl	$-1,-12(%ebp)
	movl	$-1,-20(%ebp)
	movl	$-1,-16(%ebp)
	.balign 8,0x90
.Lj9:
	movl	-16(%ebp),%eax
	leal	1(%eax),%eax
	movl	%eax,-16(%ebp)
	movl	-16(%ebp),%eax
	cmpb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	jne	.Lj12
	jmp	.Lj13
.Lj12:
	movl	-16(%ebp),%eax
	movl	U_$VDBSYNC_$$_GLOCKSLOTS(,%eax,8),%eax
	cmpl	-4(%ebp),%eax
	je	.Lj14
	jmp	.Lj13
.Lj14:
	movl	-16(%ebp),%eax
	movl	%eax,-12(%ebp)
	jmp	.Lj7
	.balign 4,0x90
.Lj13:
	movl	-16(%ebp),%eax
	cmpb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	je	.Lj15
	jmp	.Lj16
.Lj15:
	cmpl	$0,-20(%ebp)
	jl	.Lj17
	jmp	.Lj16
.Lj17:
	movl	-16(%ebp),%eax
	movl	%eax,-20(%ebp)
	.balign 4,0x90
.Lj16:
	cmpl	$63,-16(%ebp)
	jge	.Lj11
	jmp	.Lj9
.Lj11:
	cmpb	$0,-8(%ebp)
	jne	.Lj18
	jmp	.Lj19
.Lj18:
	cmpl	$0,-20(%ebp)
	jl	.Lj20
	jmp	.Lj21
.Lj20:
.Lj22:
	movl	$.Ld1,%ecx
	movl	$1,%edx
	movl	$VMT_$SYSUTILS_$$_EXCEPTION,%eax
	call	SYSUTILS$_$EXCEPTION_$__$$_CREATE$ANSISTRING$$EXCEPTION
	movl	$.Lj22,%edx
	movl	%ebp,%ecx
	call	fpc_raiseexception
	.balign 4,0x90
.Lj21:
	movl	-20(%ebp),%edx
	movl	-4(%ebp),%eax
	movl	%eax,U_$VDBSYNC_$$_GLOCKSLOTS(,%edx,8)
	movl	-20(%ebp),%eax
	movb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+4(,%eax,8)
	movl	-20(%ebp),%eax
	movb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	movl	-20(%ebp),%eax
	movl	%eax,-12(%ebp)
	.balign 4,0x90
.Lj19:
.Lj7:
	movl	-12(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync$_$vdblockheld$thandlestream$boolean$$boolean_$$_fin$0000001d,"x"
	.balign 16,0x90
VDBSYNC$_$VDBLOCKHELD$THANDLESTREAM$BOOLEAN$$BOOLEAN_$$_fin$0000001D:
	pushl	%ebp
	movl	%eax,%ebp
	leal	-4(%esp),%esp
	pushl	$U_$VDBSYNC_$$_GLOCKCS
	call	_$dll$kernel32$LeaveCriticalSection
	leal	4(%esp),%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdblockheld$thandlestream$boolean$$boolean,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBLOCKHELD$THANDLESTREAM$BOOLEAN$$BOOLEAN
VDBSYNC_$$_VDBLOCKHELD$THANDLESTREAM$BOOLEAN$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-16(%esp),%esp
	movl	%eax,-4(%ebp)
	movl	%edx,-8(%ebp)
	movl	-8(%ebp),%eax
	movb	$0,(%eax)
	movb	$0,-12(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj27
	jmp	.Lj28
.Lj27:
	jmp	.Lj23
	.balign 4,0x90
.Lj28:
	call	VDBSYNC_$$_LOCKBOOKINIT
	pushl	$U_$VDBSYNC_$$_GLOCKCS
	call	_$dll$kernel32$EnterCriticalSection
	xorl	%eax,%eax
	pushl	$VDBSYNC$_$VDBLOCKHELD$THANDLESTREAM$BOOLEAN$$BOOLEAN_$$_fin$0000001D
	pushl	%ebp
	pushl	$__FPC_finally_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	-4(%ebp),%eax
	movl	4(%eax),%eax
	movb	$0,%dl
	call	VDBSYNC_$$_LOCKSLOTOF$NATIVEUINT$BOOLEAN$$LONGINT
	movl	%eax,-16(%ebp)
	cmpl	$0,-16(%ebp)
	jge	.Lj32
	jmp	.Lj33
.Lj32:
	movl	-16(%ebp),%eax
	movb	U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8),%al
	movb	%al,-12(%ebp)
	movl	-16(%ebp),%eax
	movl	-8(%ebp),%edx
	movb	U_$VDBSYNC_$$_GLOCKSLOTS+4(,%eax,8),%al
	movb	%al,(%edx)
	.balign 4,0x90
.Lj33:
	xorl	%eax,%eax
	popl	%edx
	addl	$12,%esp
	movl	%edx,%fs:(%eax)
	movl	%ebp,%eax
	call	VDBSYNC$_$VDBLOCKHELD$THANDLESTREAM$BOOLEAN$$BOOLEAN_$$_fin$0000001D
.Lj23:
	movb	-12(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbflushstream$thandlestream,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBFLUSHSTREAM$THANDLESTREAM
VDBSYNC_$$_VDBFLUSHSTREAM$THANDLESTREAM:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-4(%esp),%esp
	movl	%eax,-4(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj36
	jmp	.Lj37
.Lj36:
	jmp	.Lj34
	.balign 4,0x90
.Lj37:
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$FlushFileBuffers
	testl	%eax,%eax
	je	.Lj38
	jmp	.Lj39
.Lj38:
	call	SYSUTILS_$$_RAISELASTOSERROR
	.balign 4,0x90
.Lj39:
.Lj34:
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
	je	.Lj42
	jmp	.Lj43
.Lj42:
	jmp	.Lj40
	.balign 4,0x90
.Lj43:
.Lj40:
	movb	-8(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync$_$vdblockstream$thandlestream$boolean$$boolean_$$_fin$0000001e,"x"
	.balign 16,0x90
VDBSYNC$_$VDBLOCKSTREAM$THANDLESTREAM$BOOLEAN$$BOOLEAN_$$_fin$0000001E:
	pushl	%ebp
	movl	%eax,%ebp
	leal	-4(%esp),%esp
	pushl	$U_$VDBSYNC_$$_GLOCKCS
	call	_$dll$kernel32$LeaveCriticalSection
	leal	4(%esp),%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdblockstream$thandlestream$boolean$$boolean,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBLOCKSTREAM$THANDLESTREAM$BOOLEAN$$BOOLEAN
VDBSYNC_$$_VDBLOCKSTREAM$THANDLESTREAM$BOOLEAN$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-40(%esp),%esp
	movl	%eax,-4(%ebp)
	movb	%dl,-8(%ebp)
	movb	$0,-12(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj48
	jmp	.Lj49
.Lj48:
	jmp	.Lj44
	.balign 4,0x90
.Lj49:
	call	VDBSYNC_$$_LOCKBOOKINIT
	pushl	$U_$VDBSYNC_$$_GLOCKCS
	call	_$dll$kernel32$EnterCriticalSection
	xorl	%eax,%eax
	pushl	$VDBSYNC$_$VDBLOCKSTREAM$THANDLESTREAM$BOOLEAN$$BOOLEAN_$$_fin$0000001E
	pushl	%ebp
	pushl	$__FPC_finally_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	-4(%ebp),%eax
	movl	4(%eax),%eax
	movb	$1,%dl
	call	VDBSYNC_$$_LOCKSLOTOF$NATIVEUINT$BOOLEAN$$LONGINT
	movl	%eax,-40(%ebp)
	movl	-40(%ebp),%eax
	cmpb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	jne	.Lj53
	jmp	.Lj54
.Lj53:
	movl	-40(%ebp),%eax
	cmpb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+4(,%eax,8)
	jne	.Lj55
	jmp	.Lj56
.Lj55:
	cmpb	$0,-8(%ebp)
	je	.Lj57
	jmp	.Lj56
.Lj57:
	leal	-32(%ebp),%eax
	movb	$0,%cl
	movl	$20,%edx
	call	SYSTEM_$$_FILLCHAR$formal$LONGINT$BYTE
	leal	-32(%ebp),%eax
	pushl	%eax
	pushl	$-1
	pushl	$-1
	pushl	$0
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$UnlockFileEx
	movl	-40(%ebp),%eax
	movb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	movl	-40(%ebp),%eax
	movb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+4(,%eax,8)
	jmp	.Lj58
.Lj56:
	movb	$1,-12(%ebp)
	jmp	.Lj52
.Lj58:
	.balign 4,0x90
.Lj54:
	leal	-32(%ebp),%eax
	movb	$0,%cl
	movl	$20,%edx
	call	SYSTEM_$$_FILLCHAR$formal$LONGINT$BYTE
	cmpb	$0,-8(%ebp)
	jne	.Lj59
	jmp	.Lj60
.Lj59:
	movl	$1,-36(%ebp)
	jmp	.Lj61
.Lj60:
	movl	$3,-36(%ebp)
.Lj61:
	leal	-32(%ebp),%eax
	pushl	%eax
	pushl	$-1
	pushl	$-1
	pushl	$0
	pushl	-36(%ebp)
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$LockFileEx
	orl	%eax,%eax
	setneb	%al
	movb	%al,-12(%ebp)
	cmpb	$0,-12(%ebp)
	jne	.Lj62
	jmp	.Lj63
.Lj62:
	movl	-40(%ebp),%eax
	movb	$1,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	movl	-40(%ebp),%eax
	movb	-8(%ebp),%dl
	movb	%dl,U_$VDBSYNC_$$_GLOCKSLOTS+4(,%eax,8)
	jmp	.Lj64
.Lj63:
.Lj64:
	xorl	%eax,%eax
	popl	%edx
	addl	$12,%esp
	movl	%edx,%fs:(%eax)
	movl	%ebp,%eax
	call	VDBSYNC$_$VDBLOCKSTREAM$THANDLESTREAM$BOOLEAN$$BOOLEAN_$$_fin$0000001E
	jmp	.Lj51
.Lj52:
	call	_FPC_leave
	jmp	.Lj44
.Lj51:
.Lj44:
	movb	-12(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync$_$vdbunlockstream$thandlestream_$$_fin$0000001f,"x"
	.balign 16,0x90
VDBSYNC$_$VDBUNLOCKSTREAM$THANDLESTREAM_$$_fin$0000001F:
	pushl	%ebp
	movl	%eax,%ebp
	leal	-4(%esp),%esp
	pushl	$U_$VDBSYNC_$$_GLOCKCS
	call	_$dll$kernel32$LeaveCriticalSection
	leal	4(%esp),%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbunlockstream$thandlestream,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBUNLOCKSTREAM$THANDLESTREAM
VDBSYNC_$$_VDBUNLOCKSTREAM$THANDLESTREAM:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-28(%esp),%esp
	movl	%eax,-4(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj69
	jmp	.Lj70
.Lj69:
	jmp	.Lj65
	.balign 4,0x90
.Lj70:
	call	VDBSYNC_$$_LOCKBOOKINIT
	pushl	$U_$VDBSYNC_$$_GLOCKCS
	call	_$dll$kernel32$EnterCriticalSection
	xorl	%eax,%eax
	pushl	$VDBSYNC$_$VDBUNLOCKSTREAM$THANDLESTREAM_$$_fin$0000001F
	pushl	%ebp
	pushl	$__FPC_finally_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	-4(%ebp),%eax
	movl	4(%eax),%eax
	movb	$0,%dl
	call	VDBSYNC_$$_LOCKSLOTOF$NATIVEUINT$BOOLEAN$$LONGINT
	movl	%eax,-28(%ebp)
	cmpl	$0,-28(%ebp)
	jl	.Lj74
	jmp	.Lj75
.Lj75:
	movl	-28(%ebp),%eax
	cmpb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	je	.Lj74
	jmp	.Lj76
.Lj74:
	jmp	.Lj73
	.balign 4,0x90
.Lj76:
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
	movl	-28(%ebp),%eax
	movb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+5(,%eax,8)
	movl	-28(%ebp),%eax
	movb	$0,U_$VDBSYNC_$$_GLOCKSLOTS+4(,%eax,8)
	xorl	%eax,%eax
	popl	%edx
	addl	$12,%esp
	movl	%edx,%fs:(%eax)
	movl	%ebp,%eax
	call	VDBSYNC$_$VDBUNLOCKSTREAM$THANDLESTREAM_$$_fin$0000001F
	jmp	.Lj72
.Lj73:
	call	_FPC_leave
	jmp	.Lj65
.Lj72:
.Lj65:
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbprocesstoken$$ansistring,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBPROCESSTOKEN$$ANSISTRING
VDBSYNC_$$_VDBPROCESSTOKEN$$ANSISTRING:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-272(%esp),%esp
	movl	%eax,-4(%ebp)
	call	_$dll$kernel32$GetCurrentProcessId
	movl	$0,%edx
	movl	%eax,-16(%ebp)
	movl	%edx,-12(%ebp)
	pushl	-12(%ebp)
	pushl	-16(%ebp)
	movl	$255,%ecx
	leal	-272(%ebp),%edx
	movl	$-1,%eax
	call	fpc_shortstr_qword
	movl	-4(%ebp),%ecx
	movw	$0,%dx
	leal	-272(%ebp),%eax
	call	fpc_shortstr_to_ansistr
	movl	-4(%ebp),%eax
	movb	$0,%cl
	movw	$0,%dx
	call	SYSTEM_$$_SETCODEPAGE$RAWBYTESTRING$WORD$BOOLEAN
	movl	-4(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdblockgenreserve$thandlestream$$boolean,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBLOCKGENRESERVE$THANDLESTREAM$$BOOLEAN
VDBSYNC_$$_VDBLOCKGENRESERVE$THANDLESTREAM$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-28(%esp),%esp
	movl	%eax,-4(%ebp)
	movb	$0,-8(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj82
	jmp	.Lj83
.Lj82:
	jmp	.Lj80
	.balign 4,0x90
.Lj83:
	leal	-28(%ebp),%eax
	movb	$0,%cl
	movl	$20,%edx
	call	SYSTEM_$$_FILLCHAR$formal$LONGINT$BYTE
	movl	$65536,-20(%ebp)
	movl	$0,-16(%ebp)
	leal	-28(%ebp),%eax
	pushl	%eax
	pushl	$0
	pushl	$1
	pushl	$0
	pushl	$3
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$LockFileEx
	orl	%eax,%eax
	setneb	%al
	movb	%al,-8(%ebp)
.Lj80:
	movb	-8(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbunlockgenreserve$thandlestream,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBUNLOCKGENRESERVE$THANDLESTREAM
VDBSYNC_$$_VDBUNLOCKGENRESERVE$THANDLESTREAM:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-24(%esp),%esp
	movl	%eax,-4(%ebp)
	cmpl	$0,-4(%ebp)
	je	.Lj86
	jmp	.Lj87
.Lj86:
	jmp	.Lj84
	.balign 4,0x90
.Lj87:
	leal	-24(%ebp),%eax
	movb	$0,%cl
	movl	$20,%edx
	call	SYSTEM_$$_FILLCHAR$formal$LONGINT$BYTE
	movl	$65536,-16(%ebp)
	movl	$0,-12(%ebp)
	leal	-24(%ebp),%eax
	pushl	%eax
	pushl	$0
	pushl	$1
	pushl	$0
	movl	-4(%ebp),%eax
	pushl	4(%eax)
	call	_$dll$kernel32$UnlockFileEx
.Lj84:
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync$_$vdbfilebytes$ansistring$$int64_$$_fin$00000020,"x"
	.balign 16,0x90
VDBSYNC$_$VDBFILEBYTES$ANSISTRING$$INT64_$$_fin$00000020:
	pushl	%ebp
	movl	%eax,%ebp
	movl	-20(%ebp),%eax
	call	SYSTEM$_$TOBJECT_$__$$_FREE
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbfilebytes$ansistring$$int64,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBFILEBYTES$ANSISTRING$$INT64
VDBSYNC_$$_VDBFILEBYTES$ANSISTRING$$INT64:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-20(%esp),%esp
	pushl	%ebx
	pushl	%esi
	pushl	%edi
	movl	%eax,-4(%ebp)
	movl	$-1,-16(%ebp)
	movl	$-1,-12(%ebp)
	movl	-4(%ebp),%eax
	movb	$1,%dl
	call	SYSUTILS_$$_FILEEXISTS$RAWBYTESTRING$BOOLEAN$$BOOLEAN
	testb	%al,%al
	je	.Lj92
	jmp	.Lj93
.Lj92:
	jmp	.Lj88
	.balign 4,0x90
.Lj93:
	xorl	%eax,%eax
	pushl	$.Lj96
	pushl	%ebp
	pushl	$__FPC_except_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	pushl	$64
	movl	-4(%ebp),%ecx
	movl	$1,%edx
	movl	$VMT_$CLASSES_$$_TFILESTREAM,%eax
	call	CLASSES$_$TFILESTREAM_$__$$_CREATE$ANSISTRING$WORD$$TFILESTREAM
	movl	%eax,-20(%ebp)
	xorl	%eax,%eax
	pushl	$VDBSYNC$_$VDBFILEBYTES$ANSISTRING$$INT64_$$_fin$00000020
	pushl	%ebp
	pushl	$__FPC_finally_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	-20(%ebp),%eax
	movl	-20(%ebp),%edx
	movl	(%edx),%edx
	call	*112(%edx)
	movl	%eax,-16(%ebp)
	movl	%edx,-12(%ebp)
	xorl	%eax,%eax
	popl	%edx
	addl	$12,%esp
	movl	%edx,%fs:(%eax)
	movl	%ebp,%eax
	call	VDBSYNC$_$VDBFILEBYTES$ANSISTRING$$INT64_$$_fin$00000020
	xorl	%edx,%edx
	popl	%eax
	addl	$12,%esp
	movl	%eax,%fs:(%edx)
	jmp	.Lj97
.Lj96:
	movl	$-1,-16(%ebp)
	movl	$-1,-12(%ebp)
	call	FPC_DONEEXCEPTION
.Lj97:
.Lj88:
	movl	-12(%ebp),%edx
	movl	-16(%ebp),%eax
	popl	%edi
	popl	%esi
	popl	%ebx
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbsync_$$_vdbopenstreamnoflock$ansistring$boolean$boolean$$thandlestream,"x"
	.balign 16,0x90
.globl	VDBSYNC_$$_VDBOPENSTREAMNOFLOCK$ANSISTRING$BOOLEAN$BOOLEAN$$THANDLESTREAM
VDBSYNC_$$_VDBOPENSTREAMNOFLOCK$ANSISTRING$BOOLEAN$BOOLEAN$$THANDLESTREAM:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-16(%esp),%esp
	movl	%eax,-4(%ebp)
	movb	%dl,-8(%ebp)
	movb	%cl,-12(%ebp)
	cmpb	$0,-8(%ebp)
	jne	.Lj104
	jmp	.Lj105
.Lj104:
	pushl	$64
	movl	-4(%ebp),%ecx
	movl	$1,%edx
	movl	$VMT_$CLASSES_$$_TFILESTREAM,%eax
	call	CLASSES$_$TFILESTREAM_$__$$_CREATE$ANSISTRING$WORD$$TFILESTREAM
	movl	%eax,-16(%ebp)
	jmp	.Lj106
.Lj105:
	cmpb	$0,-12(%ebp)
	jne	.Lj107
	jmp	.Lj108
.Lj107:
	pushl	$65344
	movl	-4(%ebp),%ecx
	movl	$1,%edx
	movl	$VMT_$CLASSES_$$_TFILESTREAM,%eax
	call	CLASSES$_$TFILESTREAM_$__$$_CREATE$ANSISTRING$WORD$$TFILESTREAM
	movl	%eax,-16(%ebp)
	jmp	.Lj109
.Lj108:
	pushl	$66
	movl	-4(%ebp),%ecx
	movl	$1,%edx
	movl	$VMT_$CLASSES_$$_TFILESTREAM,%eax
	call	CLASSES$_$TFILESTREAM_$__$$_CREATE$ANSISTRING$WORD$$TFILESTREAM
	movl	%eax,-16(%ebp)
.Lj109:
.Lj106:
	movl	-16(%ebp),%eax
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
	je	.Lj112
	jmp	.Lj113
.Lj112:
	jmp	.Lj110
	.balign 4,0x90
.Lj113:
	call	_$dll$kernel32$GetLastError
	movl	%eax,-12(%ebp)
	cmpl	$32,-12(%ebp)
	je	.Lj114
	jmp	.Lj115
.Lj115:
	cmpl	$33,-12(%ebp)
	je	.Lj114
	jmp	.Lj116
.Lj114:
	movb	$1,-8(%ebp)
	jmp	.Lj117
.Lj116:
	movb	$0,-8(%ebp)
.Lj117:
.Lj110:
	movb	-8(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret
# End asmlist al_procedures
# Begin asmlist al_globals

.section .bss
	.balign 4
U_$VDBSYNC_$$_GLOCKCS:
	.zero 24

.section .bss
	.balign 4
U_$VDBSYNC_$$_GLOCKSLOTS:
	.zero 512
# End asmlist al_globals
# Begin asmlist al_typedconsts

.section .data.n_TC_$VDBSYNC_$$_GLOCKINIT,"d"
TC_$VDBSYNC_$$_GLOCKINIT:
	.byte	0

.section .rodata.n_.Ld1,"d"
	.balign 4
.Ld1$strlab:
	.short	0,1
	.long	-1,51
.Ld1:
	.ascii	"VDbSync: kilit defteri dolu (cok fazla acik handle)"
	.ascii	"\000"
# End asmlist al_typedconsts

