	.file "VDbErr.pas"
# Begin asmlist al_procedures

.section .text.n_vdberr$_$evdbexception_$__$$_create$tvdberrorcode$ansistring$$evdbexception,"x"
	.balign 16,0x90
.globl	VDBERR$_$EVDBEXCEPTION_$__$$_CREATE$TVDBERRORCODE$ANSISTRING$$EVDBEXCEPTION
VDBERR$_$EVDBEXCEPTION_$__$$_CREATE$TVDBERRORCODE$ANSISTRING$$EVDBEXCEPTION:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-16(%esp),%esp
	pushl	%ebx
	pushl	%esi
	pushl	%edi
	movl	%eax,-12(%ebp)
	movl	%edx,-8(%ebp)
	movb	%cl,-4(%ebp)
	cmpl	$1,-8(%ebp)
	je	.Lj5
	jmp	.Lj6
.Lj5:
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%edx
	call	*52(%edx)
	movl	%eax,-12(%ebp)
	.balign 4,0x90
.Lj6:
	cmpl	$0,-12(%ebp)
	je	.Lj7
	jmp	.Lj8
.Lj7:
	jmp	.Lj3
	.balign 4,0x90
.Lj8:
	xorl	%eax,%eax
	pushl	$.Lj11
	pushl	%ebp
	pushl	$__FPC_except_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	$-1,-16(%ebp)
	movl	8(%ebp),%ecx
	movl	-12(%ebp),%eax
	movl	$0,%edx
	call	SYSUTILS$_$EXCEPTION_$__$$_CREATE$ANSISTRING$$EXCEPTION
	movl	-12(%ebp),%eax
	movb	-4(%ebp),%dl
	movb	%dl,12(%eax)
	movl	$1,-16(%ebp)
	cmpl	$0,-12(%ebp)
	jne	.Lj15
	jmp	.Lj16
.Lj15:
	cmpl	$0,-8(%ebp)
	jne	.Lj17
	jmp	.Lj16
.Lj17:
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%edx
	movl	(%edx),%edx
	call	*68(%edx)
	.balign 4,0x90
.Lj16:
	xorl	%edx,%edx
	popl	%eax
	addl	$12,%esp
	movl	%eax,%fs:(%edx)
	jmp	.Lj12
.Lj11:
	cmpl	$0,-8(%ebp)
	jne	.Lj18
	jmp	.Lj19
.Lj18:
	movl	-16(%ebp),%edx
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%ecx
	movl	(%ecx),%ecx
	call	*48(%ecx)
	.balign 4,0x90
.Lj19:
	call	fpc_reraise
	call	FPC_DONEEXCEPTION
.Lj12:
.Lj3:
	movl	-12(%ebp),%eax
	popl	%edi
	popl	%esi
	popl	%ebx
	movl	%ebp,%esp
	popl	%ebp
	ret	$4

.section .text.n_vdberr$_$evdbexception_$__$$_createfmt$tvdberrorcode$ansistring$array_of_const$$evdbexception,"x"
	.balign 16,0x90
.globl	VDBERR$_$EVDBEXCEPTION_$__$$_CREATEFMT$TVDBERRORCODE$ANSISTRING$array_of_const$$EVDBEXCEPTION
VDBERR$_$EVDBEXCEPTION_$__$$_CREATEFMT$TVDBERRORCODE$ANSISTRING$array_of_const$$EVDBEXCEPTION:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-16(%esp),%esp
	pushl	%ebx
	pushl	%esi
	pushl	%edi
	movl	%eax,-12(%ebp)
	movl	%edx,-8(%ebp)
	movb	%cl,-4(%ebp)
	cmpl	$1,-8(%ebp)
	je	.Lj22
	jmp	.Lj23
.Lj22:
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%edx
	call	*52(%edx)
	movl	%eax,-12(%ebp)
	.balign 4,0x90
.Lj23:
	cmpl	$0,-12(%ebp)
	je	.Lj24
	jmp	.Lj25
.Lj24:
	jmp	.Lj20
	.balign 4,0x90
.Lj25:
	xorl	%eax,%eax
	pushl	$.Lj28
	pushl	%ebp
	pushl	$__FPC_except_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	$-1,-16(%ebp)
	movl	12(%ebp),%eax
	pushl	%eax
	pushl	8(%ebp)
	movl	16(%ebp),%ecx
	movl	-12(%ebp),%eax
	movl	$0,%edx
	call	SYSUTILS$_$EXCEPTION_$__$$_CREATEFMT$ANSISTRING$array_of_const$$EXCEPTION
	movl	-12(%ebp),%eax
	movb	-4(%ebp),%dl
	movb	%dl,12(%eax)
	movl	$1,-16(%ebp)
	cmpl	$0,-12(%ebp)
	jne	.Lj32
	jmp	.Lj33
.Lj32:
	cmpl	$0,-8(%ebp)
	jne	.Lj34
	jmp	.Lj33
.Lj34:
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%edx
	movl	(%edx),%edx
	call	*68(%edx)
	.balign 4,0x90
.Lj33:
	xorl	%eax,%eax
	popl	%edx
	addl	$12,%esp
	movl	%edx,%fs:(%eax)
	jmp	.Lj29
.Lj28:
	cmpl	$0,-8(%ebp)
	jne	.Lj35
	jmp	.Lj36
.Lj35:
	movl	-16(%ebp),%edx
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%ecx
	movl	(%ecx),%ecx
	call	*48(%ecx)
	.balign 4,0x90
.Lj36:
	call	fpc_reraise
	call	FPC_DONEEXCEPTION
.Lj29:
.Lj20:
	movl	-12(%ebp),%eax
	popl	%edi
	popl	%esi
	popl	%ebx
	movl	%ebp,%esp
	popl	%ebp
	ret	$12

.section .text.n_vdberr_$$_vdberrorname$tvdberrorcode$$ansistring,"x"
	.balign 16,0x90
.globl	VDBERR_$$_VDBERRORNAME$TVDBERRORCODE$$ANSISTRING
VDBERR_$$_VDBERRORNAME$TVDBERRORCODE$$ANSISTRING:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-8(%esp),%esp
	movb	%al,-4(%ebp)
	movl	%edx,-8(%ebp)
	movb	-4(%ebp),%al
	testb	%al,%al
	je	.Lj41
	subb	$1,%al
	je	.Lj42
	subb	$1,%al
	je	.Lj43
	subb	$1,%al
	je	.Lj44
	subb	$1,%al
	je	.Lj45
	subb	$1,%al
	je	.Lj46
	subb	$1,%al
	je	.Lj47
	subb	$1,%al
	je	.Lj48
	subb	$1,%al
	je	.Lj49
	subb	$1,%al
	je	.Lj50
	subb	$1,%al
	je	.Lj51
	subb	$1,%al
	je	.Lj52
	subb	$1,%al
	je	.Lj53
	subb	$1,%al
	je	.Lj54
	subb	$1,%al
	je	.Lj55
	subb	$1,%al
	je	.Lj56
	subb	$1,%al
	je	.Lj57
	subb	$1,%al
	je	.Lj58
	subb	$1,%al
	je	.Lj59
	subb	$1,%al
	je	.Lj60
	subb	$1,%al
	je	.Lj61
	subb	$1,%al
	je	.Lj62
	subb	$1,%al
	je	.Lj63
	subb	$1,%al
	je	.Lj64
	subb	$1,%al
	je	.Lj65
	subb	$1,%al
	je	.Lj66
	subb	$1,%al
	je	.Lj67
	subb	$1,%al
	je	.Lj68
	subb	$1,%al
	je	.Lj69
	subb	$1,%al
	je	.Lj70
	subb	$1,%al
	je	.Lj71
	subb	$1,%al
	je	.Lj72
	subb	$1,%al
	je	.Lj73
	subb	$1,%al
	je	.Lj74
	subb	$1,%al
	je	.Lj75
	jmp	.Lj40
	.balign 4,0x90
.Lj41:
	movl	-8(%ebp),%eax
	movl	$.Ld1,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj42:
	movl	-8(%ebp),%eax
	movl	$.Ld2,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj43:
	movl	-8(%ebp),%eax
	movl	$.Ld3,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj44:
	movl	-8(%ebp),%eax
	movl	$.Ld4,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj45:
	movl	-8(%ebp),%eax
	movl	$.Ld5,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj46:
	movl	-8(%ebp),%eax
	movl	$.Ld6,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj47:
	movl	-8(%ebp),%eax
	movl	$.Ld7,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj48:
	movl	-8(%ebp),%eax
	movl	$.Ld8,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj49:
	movl	-8(%ebp),%eax
	movl	$.Ld9,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj50:
	movl	-8(%ebp),%eax
	movl	$.Ld10,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj51:
	movl	-8(%ebp),%eax
	movl	$.Ld11,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj52:
	movl	-8(%ebp),%eax
	movl	$.Ld12,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj53:
	movl	-8(%ebp),%eax
	movl	$.Ld13,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj54:
	movl	-8(%ebp),%eax
	movl	$.Ld14,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj55:
	movl	-8(%ebp),%eax
	movl	$.Ld15,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj56:
	movl	-8(%ebp),%eax
	movl	$.Ld16,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj57:
	movl	-8(%ebp),%eax
	movl	$.Ld17,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj58:
	movl	-8(%ebp),%eax
	movl	$.Ld18,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj59:
	movl	-8(%ebp),%eax
	movl	$.Ld19,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj60:
	movl	-8(%ebp),%eax
	movl	$.Ld20,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj61:
	movl	-8(%ebp),%eax
	movl	$.Ld21,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj62:
	movl	-8(%ebp),%eax
	movl	$.Ld22,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj63:
	movl	-8(%ebp),%eax
	movl	$.Ld23,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj64:
	movl	-8(%ebp),%eax
	movl	$.Ld24,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj65:
	movl	-8(%ebp),%eax
	movl	$.Ld25,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj66:
	movl	-8(%ebp),%eax
	movl	$.Ld26,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj67:
	movl	-8(%ebp),%eax
	movl	$.Ld27,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj68:
	movl	-8(%ebp),%eax
	movl	$.Ld28,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj69:
	movl	-8(%ebp),%eax
	movl	$.Ld29,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj70:
	movl	-8(%ebp),%eax
	movl	$.Ld30,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj71:
	movl	-8(%ebp),%eax
	movl	$.Ld31,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj72:
	movl	-8(%ebp),%eax
	movl	$.Ld32,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj73:
	movl	-8(%ebp),%eax
	movl	$.Ld33,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj74:
	movl	-8(%ebp),%eax
	movl	$.Ld34,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj75:
	movl	-8(%ebp),%eax
	movl	$.Ld35,%edx
	call	fpc_ansistr_assign
	jmp	.Lj39
	.balign 4,0x90
.Lj40:
	movl	-8(%ebp),%eax
	movl	$.Ld2,%edx
	call	fpc_ansistr_assign
	.balign 4,0x90
.Lj39:
	movl	%ebp,%esp
	popl	%ebp
	ret
# End asmlist al_procedures
# Begin asmlist al_globals

.section .rodata.n_VMT_$VDBERR_$$_EVDBEXCEPTION,"d"
	.balign 4
.globl	VMT_$VDBERR_$$_EVDBEXCEPTION
VMT_$VDBERR_$$_EVDBEXCEPTION:
	.long	16,-16
	.long	VMT_$SYSUTILS_$$_EXCEPTION$indirect
	.long	.Ld36
	.long	0,0,0
	.long	RTTI_$VDBERR_$$_EVDBEXCEPTION
	.long	0,0,0,0
	.long	SYSTEM$_$TOBJECT_$__$$_DESTROY
	.long	SYSTEM$_$TOBJECT_$__$$_NEWINSTANCE$$TOBJECT
	.long	SYSTEM$_$TOBJECT_$__$$_FREEINSTANCE
	.long	SYSTEM$_$TOBJECT_$__$$_SAFECALLEXCEPTION$TOBJECT$POINTER$$HRESULT
	.long	SYSTEM$_$TOBJECT_$__$$_DEFAULTHANDLER$formal
	.long	SYSTEM$_$TOBJECT_$__$$_AFTERCONSTRUCTION
	.long	SYSTEM$_$TOBJECT_$__$$_BEFOREDESTRUCTION
	.long	SYSTEM$_$TOBJECT_$__$$_DEFAULTHANDLERSTR$formal
	.long	SYSTEM$_$TOBJECT_$__$$_DISPATCH$formal
	.long	SYSTEM$_$TOBJECT_$__$$_DISPATCHSTR$formal
	.long	SYSTEM$_$TOBJECT_$__$$_EQUALS$TOBJECT$$BOOLEAN
	.long	SYSTEM$_$TOBJECT_$__$$_GETHASHCODE$$LONGINT
	.long	SYSUTILS$_$EXCEPTION_$__$$_TOSTRING$$ANSISTRING
	.long	SYSUTILS$_$EXCEPTION_$__$$_GETBASEEXCEPTION$$EXCEPTION
	.long	0
# End asmlist al_globals
# Begin asmlist al_const

.section .rodata.n_VMT_$VDBERR_$$_EVDBEXCEPTION,"d"
	.balign 4
.Ld36:
	.byte	13
	.ascii	"EVDbException"
# End asmlist al_const
# Begin asmlist al_typedconsts

.section .rodata.n_.Ld1,"d"
	.balign 4
.Ld1$strlab:
	.short	0,1
	.long	-1,6
.Ld1:
	.ascii	"ecNone\000"

.section .rodata.n_.Ld2,"d"
	.balign 4
.Ld2$strlab:
	.short	0,1
	.long	-1,9
.Ld2:
	.ascii	"ecGeneral\000"

.section .rodata.n_.Ld3,"d"
	.balign 4
.Ld3$strlab:
	.short	0,1
	.long	-1,17
.Ld3:
	.ascii	"ecDatabaseNotOpen\000"

.section .rodata.n_.Ld4,"d"
	.balign 4
.Ld4$strlab:
	.short	0,1
	.long	-1,18
.Ld4:
	.ascii	"ecDatabaseNotFound\000"

.section .rodata.n_.Ld5,"d"
	.balign 4
.Ld5$strlab:
	.short	0,1
	.long	-1,16
.Ld5:
	.ascii	"ecDatabaseExists\000"

.section .rodata.n_.Ld6,"d"
	.balign 4
.Ld6$strlab:
	.short	0,1
	.long	-1,16
.Ld6:
	.ascii	"ecDatabaseLocked\000"

.section .rodata.n_.Ld7,"d"
	.balign 4
.Ld7$strlab:
	.short	0,1
	.long	-1,9
.Ld7:
	.ascii	"ecIOError\000"

.section .rodata.n_.Ld8,"d"
	.balign 4
.Ld8$strlab:
	.short	0,1
	.long	-1,9
.Ld8:
	.ascii	"ecCorrupt\000"

.section .rodata.n_.Ld9,"d"
	.balign 4
.Ld9$strlab:
	.short	0,1
	.long	-1,15
.Ld9:
	.ascii	"ecHashCollision\000"

.section .rodata.n_.Ld10,"d"
	.balign 4
.Ld10$strlab:
	.short	0,1
	.long	-1,14
.Ld10:
	.ascii	"ecInvalidState\000"

.section .rodata.n_.Ld11,"d"
	.balign 4
.Ld11$strlab:
	.short	0,1
	.long	-1,7
.Ld11:
	.ascii	"ecLimit\000"

.section .rodata.n_.Ld12,"d"
	.balign 4
.Ld12$strlab:
	.short	0,1
	.long	-1,15
.Ld12:
	.ascii	"ecTableNotFound\000"

.section .rodata.n_.Ld13,"d"
	.balign 4
.Ld13$strlab:
	.short	0,1
	.long	-1,13
.Ld13:
	.ascii	"ecTableExists\000"

.section .rodata.n_.Ld14,"d"
	.balign 4
.Ld14$strlab:
	.short	0,1
	.long	-1,16
.Ld14:
	.ascii	"ecColumnNotFound\000"

.section .rodata.n_.Ld15,"d"
	.balign 4
.Ld15$strlab:
	.short	0,1
	.long	-1,14
.Ld15:
	.ascii	"ecColumnExists\000"

.section .rodata.n_.Ld16,"d"
	.balign 4
.Ld16$strlab:
	.short	0,1
	.long	-1,15
.Ld16:
	.ascii	"ecIndexNotFound\000"

.section .rodata.n_.Ld17,"d"
	.balign 4
.Ld17$strlab:
	.short	0,1
	.long	-1,13
.Ld17:
	.ascii	"ecIndexExists\000"

.section .rodata.n_.Ld18,"d"
	.balign 4
.Ld18$strlab:
	.short	0,1
	.long	-1,15
.Ld18:
	.ascii	"ecSchemaCorrupt\000"

.section .rodata.n_.Ld19,"d"
	.balign 4
.Ld19$strlab:
	.short	0,1
	.long	-1,13
.Ld19:
	.ascii	"ecInvalidName\000"

.section .rodata.n_.Ld20,"d"
	.balign 4
.Ld20$strlab:
	.short	0,1
	.long	-1,21
.Ld20:
	.ascii	"ecDuplicatePrimaryKey\000"

.section .rodata.n_.Ld21,"d"
	.balign 4
.Ld21$strlab:
	.short	0,1
	.long	-1,17
.Ld21:
	.ascii	"ecUniqueViolation\000"

.section .rodata.n_.Ld22,"d"
	.balign 4
.Ld22$strlab:
	.short	0,1
	.long	-1,18
.Ld22:
	.ascii	"ecNotNullViolation\000"

.section .rodata.n_.Ld23,"d"
	.balign 4
.Ld23$strlab:
	.short	0,1
	.long	-1,16
.Ld23:
	.ascii	"ecCheckViolation\000"

.section .rodata.n_.Ld24,"d"
	.balign 4
.Ld24$strlab:
	.short	0,1
	.long	-1,21
.Ld24:
	.ascii	"ecForeignKeyViolation\000"

.section .rodata.n_.Ld25,"d"
	.balign 4
.Ld25$strlab:
	.short	0,1
	.long	-1,14
.Ld25:
	.ascii	"ecTypeMismatch\000"

.section .rodata.n_.Ld26,"d"
	.balign 4
.Ld26$strlab:
	.short	0,1
	.long	-1,11
.Ld26:
	.ascii	"ecMathError\000"

.section .rodata.n_.Ld27,"d"
	.balign 4
.Ld27$strlab:
	.short	0,1
	.long	-1,17
.Ld27:
	.ascii	"ecInvalidArgument\000"

.section .rodata.n_.Ld28,"d"
	.balign 4
.Ld28$strlab:
	.short	0,1
	.long	-1,13
.Ld28:
	.ascii	"ecSyntaxError\000"

.section .rodata.n_.Ld29,"d"
	.balign 4
.Ld29$strlab:
	.short	0,1
	.long	-1,13
.Ld29:
	.ascii	"ecUnsupported\000"

.section .rodata.n_.Ld30,"d"
	.balign 4
.Ld30$strlab:
	.short	0,1
	.long	-1,18
.Ld30:
	.ascii	"ecTransactionState\000"

.section .rodata.n_.Ld31,"d"
	.balign 4
.Ld31$strlab:
	.short	0,1
	.long	-1,20
.Ld31:
	.ascii	"ecDuplicateSavepoint\000"

.section .rodata.n_.Ld32,"d"
	.balign 4
.Ld32$strlab:
	.short	0,1
	.long	-1,19
.Ld32:
	.ascii	"ecSavepointNotFound\000"

.section .rodata.n_.Ld33,"d"
	.balign 4
.Ld33$strlab:
	.short	0,1
	.long	-1,13
.Ld33:
	.ascii	"ecPoolTimeout\000"

.section .rodata.n_.Ld34,"d"
	.balign 4
.Ld34$strlab:
	.short	0,1
	.long	-1,12
.Ld34:
	.ascii	"ecPoolClosed\000"

.section .rodata.n_.Ld35,"d"
	.balign 4
.Ld35$strlab:
	.short	0,1
	.long	-1,11
.Ld35:
	.ascii	"ecJsonError\000"
# End asmlist al_typedconsts
# Begin asmlist al_rtti

.section .rodata.n_RTTI_$VDBERR_$$_TVDBERRORCODE,"d"
	.balign 8
.globl	RTTI_$VDBERR_$$_TVDBERRORCODE
RTTI_$VDBERR_$$_TVDBERRORCODE:
	.byte	3,13
	.ascii	"TVDbErrorCode"
	.byte	1
	.long	0,34,0
	.byte	6
	.ascii	"ecNone"
	.byte	9
	.ascii	"ecGeneral"
	.byte	17
	.ascii	"ecDatabaseNotOpen"
	.byte	18
	.ascii	"ecDatabaseNotFound"
	.byte	16
	.ascii	"ecDatabaseExists"
	.byte	16
	.ascii	"ecDatabaseLocked"
	.byte	9
	.ascii	"ecIOError"
	.byte	9
	.ascii	"ecCorrupt"
	.byte	15
	.ascii	"ecHashCollision"
	.byte	14
	.ascii	"ecInvalidState"
	.byte	7
	.ascii	"ecLimit"
	.byte	15
	.ascii	"ecTableNotFound"
	.byte	13
	.ascii	"ecTableExists"
	.byte	16
	.ascii	"ecColumnNotFound"
	.byte	14
	.ascii	"ecColumnExists"
	.byte	15
	.ascii	"ecIndexNotFound"
	.byte	13
	.ascii	"ecIndexExists"
	.byte	15
	.ascii	"ecSchemaCorrupt"
	.byte	13
	.ascii	"ecInvalidName"
	.byte	21
	.ascii	"ecDuplicatePrimaryKey"
	.byte	17
	.ascii	"ecUniqueViolation"
	.byte	18
	.ascii	"ecNotNullViolation"
	.byte	16
	.ascii	"ecCheckViolation"
	.byte	21
	.ascii	"ecForeignKeyViolation"
	.byte	14
	.ascii	"ecTypeMismatch"
	.byte	11
	.ascii	"ecMathError"
	.byte	17
	.ascii	"ecInvalidArgument"
	.byte	13
	.ascii	"ecSyntaxError"
	.byte	13
	.ascii	"ecUnsupported"
	.byte	18
	.ascii	"ecTransactionState"
	.byte	20
	.ascii	"ecDuplicateSavepoint"
	.byte	19
	.ascii	"ecSavepointNotFound"
	.byte	13
	.ascii	"ecPoolTimeout"
	.byte	12
	.ascii	"ecPoolClosed"
	.byte	11
	.ascii	"ecJsonError"
	.byte	6
	.ascii	"VDbErr"
	.byte	0

.section .rodata.n_RTTI_$VDBERR_$$_TVDBERRORCODE_s2o,"d"
	.balign 4
.globl	RTTI_$VDBERR_$$_TVDBERRORCODE_s2o
RTTI_$VDBERR_$$_TVDBERRORCODE_s2o:
	.long	35,22
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+356
	.long	14
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+222
	.long	13
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+205
	.long	7
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+126
	.long	4
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+82
	.long	5
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+99
	.long	3
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+63
	.long	2
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+45
	.long	19
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+297
	.long	30
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+487
	.long	23
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+373
	.long	1
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+35
	.long	8
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+136
	.long	16
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+253
	.long	15
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+237
	.long	26
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+422
	.long	18
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+283
	.long	9
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+152
	.long	6
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+116
	.long	34
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+555
	.long	10
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+167
	.long	25
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+410
	.long	0
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+28
	.long	21
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+337
	.long	33
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+542
	.long	32
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+528
	.long	31
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+508
	.long	17
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+267
	.long	27
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+440
	.long	12
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+191
	.long	11
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+175
	.long	29
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+468
	.long	24
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+395
	.long	20
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+319
	.long	28
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+454

.section .rodata.n_RTTI_$VDBERR_$$_TVDBERRORCODE_o2s,"d"
	.balign 4
.globl	RTTI_$VDBERR_$$_TVDBERRORCODE_o2s
RTTI_$VDBERR_$$_TVDBERRORCODE_o2s:
	.long	0
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+28
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+35
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+45
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+63
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+82
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+99
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+116
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+126
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+136
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+152
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+167
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+175
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+191
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+205
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+222
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+237
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+253
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+267
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+283
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+297
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+319
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+337
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+356
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+373
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+395
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+410
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+422
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+440
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+454
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+468
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+487
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+508
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+528
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+542
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE+555

.section .rodata.n_INIT_$VDBERR_$$_EVDBEXCEPTION,"d"
	.balign 8
.globl	INIT_$VDBERR_$$_EVDBEXCEPTION
INIT_$VDBERR_$$_EVDBEXCEPTION:
	.byte	15,13
	.ascii	"EVDbException"
	.long	0,4,0,0,0

.section .rodata.n_RTTI_$VDBERR_$$_EVDBEXCEPTION,"d"
	.balign 8
.globl	RTTI_$VDBERR_$$_EVDBEXCEPTION
RTTI_$VDBERR_$$_EVDBEXCEPTION:
	.byte	15,13
	.ascii	"EVDbException"
	.long	VMT_$VDBERR_$$_EVDBEXCEPTION
	.long	RTTI_$SYSUTILS_$$_EXCEPTION$indirect
	.short	0
	.byte	6
	.ascii	"VDbErr"
	.short	0
# End asmlist al_rtti
# Begin asmlist al_indirectglobals

.section .rodata.n_VMT_$VDBERR_$$_EVDBEXCEPTION,"d"
	.balign 4
.globl	VMT_$VDBERR_$$_EVDBEXCEPTION$indirect
VMT_$VDBERR_$$_EVDBEXCEPTION$indirect:
	.long	VMT_$VDBERR_$$_EVDBEXCEPTION

.section .rodata.n_RTTI_$VDBERR_$$_TVDBERRORCODE,"d"
	.balign 4
.globl	RTTI_$VDBERR_$$_TVDBERRORCODE$indirect
RTTI_$VDBERR_$$_TVDBERRORCODE$indirect:
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE

.section .rodata.n_RTTI_$VDBERR_$$_TVDBERRORCODE_s2o,"d"
	.balign 4
.globl	RTTI_$VDBERR_$$_TVDBERRORCODE_s2o$indirect
RTTI_$VDBERR_$$_TVDBERRORCODE_s2o$indirect:
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE_s2o

.section .rodata.n_RTTI_$VDBERR_$$_TVDBERRORCODE_o2s,"d"
	.balign 4
.globl	RTTI_$VDBERR_$$_TVDBERRORCODE_o2s$indirect
RTTI_$VDBERR_$$_TVDBERRORCODE_o2s$indirect:
	.long	RTTI_$VDBERR_$$_TVDBERRORCODE_o2s

.section .rodata.n_INIT_$VDBERR_$$_EVDBEXCEPTION,"d"
	.balign 4
.globl	INIT_$VDBERR_$$_EVDBEXCEPTION$indirect
INIT_$VDBERR_$$_EVDBEXCEPTION$indirect:
	.long	INIT_$VDBERR_$$_EVDBEXCEPTION

.section .rodata.n_RTTI_$VDBERR_$$_EVDBEXCEPTION,"d"
	.balign 4
.globl	RTTI_$VDBERR_$$_EVDBEXCEPTION$indirect
RTTI_$VDBERR_$$_EVDBEXCEPTION$indirect:
	.long	RTTI_$VDBERR_$$_EVDBEXCEPTION
# End asmlist al_indirectglobals

