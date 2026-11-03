	.file "VDbBackendApi.pas"
# Begin asmlist al_procedures

.section .text.n_vdbbackendapi_$$_vdbbackendsessionid$$longword,"x"
	.balign 16,0x90
.globl	VDBBACKENDAPI_$$_VDBBACKENDSESSIONID$$LONGWORD
VDBBACKENDAPI_$$_VDBBACKENDSESSIONID$$LONGWORD:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-4(%esp),%esp
	cmpl	$0,TC_$VDBBACKENDAPI_$$_VDBSESSIONIDFUNC
	jne	.Lj5
	jmp	.Lj6
.Lj5:
	call	*TC_$VDBBACKENDAPI_$$_VDBSESSIONIDFUNC
	movl	%eax,-4(%ebp)
	jmp	.Lj7
.Lj6:
	movl	$0,-4(%ebp)
.Lj7:
	movl	-4(%ebp),%eax
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbbackendapi$_$tvdbbackendkvstore_$_create$ivdbbackend$$tvdbbackendkvstore_$$_fin$000000ef,"x"
	.balign 16,0x90
VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$_CREATE$IVDBBACKEND$$TVDBBACKENDKVSTORE_$$_fin$000000EF:
	pushl	%ebp
	movl	%eax,%ebp
	leal	-4(%ebp),%eax
	call	fpc_intf_decr_ref
	popl	%ebp
	ret

.section .text.n_vdbbackendapi$_$tvdbbackendkvstore_$__$$_create$ivdbbackend$$tvdbbackendkvstore,"x"
	.balign 16,0x90
.globl	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_CREATE$IVDBBACKEND$$TVDBBACKENDKVSTORE
VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_CREATE$IVDBBACKEND$$TVDBBACKENDKVSTORE:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-16(%esp),%esp
	pushl	%ebx
	pushl	%esi
	pushl	%edi
	movl	%eax,-12(%ebp)
	movl	%edx,-8(%ebp)
	movl	%ecx,-4(%ebp)
	movl	-4(%ebp),%eax
	call	fpc_intf_incr_ref
	cmpl	$1,-8(%ebp)
	je	.Lj12
	jmp	.Lj13
.Lj12:
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%edx
	call	*52(%edx)
	movl	%eax,-12(%ebp)
	.balign 4,0x90
.Lj13:
	cmpl	$0,-12(%ebp)
	je	.Lj14
	jmp	.Lj15
.Lj14:
	jmp	.Lj8
	.balign 4,0x90
.Lj15:
	xorl	%eax,%eax
	pushl	$.Lj18
	pushl	%ebp
	pushl	$__FPC_except_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	$-1,-16(%ebp)
	xorl	%eax,%eax
	pushl	$VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$_CREATE$IVDBBACKEND$$TVDBBACKENDKVSTORE_$$_fin$000000EF
	pushl	%ebp
	pushl	$__FPC_finally_handler
	pushl	%fs:(%eax)
	movl	%esp,%fs:(%eax)
	movl	-12(%ebp),%eax
	movl	$0,%edx
	call	SYSTEM$_$TOBJECT_$__$$_CREATE$$TOBJECT
	cmpl	$0,-4(%ebp)
	je	.Lj23
	jmp	.Lj24
.Lj23:
.Lj25:
	movl	$.Ld1,%ecx
	movl	$1,%edx
	movl	$VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,%eax
	call	SYSUTILS$_$EXCEPTION_$__$$_CREATE$ANSISTRING$$EXCEPTION
	movl	$.Lj25,%edx
	movl	%ebp,%ecx
	call	fpc_raiseexception
	.balign 4,0x90
.Lj24:
	movl	-12(%ebp),%eax
	leal	16(%eax),%eax
	movl	-4(%ebp),%edx
	call	fpc_intf_assign
	xorl	%edx,%edx
	popl	%eax
	addl	$12,%esp
	movl	%eax,%fs:(%edx)
	movl	%ebp,%eax
	call	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$_CREATE$IVDBBACKEND$$TVDBBACKENDKVSTORE_$$_fin$000000EF
	movl	$1,-16(%ebp)
	cmpl	$0,-12(%ebp)
	jne	.Lj26
	jmp	.Lj27
.Lj26:
	cmpl	$0,-8(%ebp)
	jne	.Lj28
	jmp	.Lj27
.Lj28:
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%edx
	movl	(%edx),%edx
	call	*68(%edx)
	.balign 4,0x90
.Lj27:
	xorl	%edx,%edx
	popl	%eax
	addl	$12,%esp
	movl	%eax,%fs:(%edx)
	jmp	.Lj19
.Lj18:
	cmpl	$0,-8(%ebp)
	jne	.Lj29
	jmp	.Lj30
.Lj29:
	movl	-16(%ebp),%edx
	movl	-12(%ebp),%eax
	movl	-12(%ebp),%ecx
	movl	(%ecx),%ecx
	call	*48(%ecx)
	.balign 4,0x90
.Lj30:
	call	fpc_reraise
	call	FPC_DONEEXCEPTION
.Lj19:
.Lj8:
	movl	-12(%ebp),%eax
	popl	%edi
	popl	%esi
	popl	%ebx
	movl	%ebp,%esp
	popl	%ebp
	ret

.section .text.n_vdbbackendapi$_$tvdbbackendkvstore_$__$$_put$qword$tbytes,"x"
	.balign 16,0x90
.globl	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_PUT$QWORD$TBYTES
VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_PUT$QWORD$TBYTES:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-8(%esp),%esp
	movl	%eax,-8(%ebp)
	movl	%edx,-4(%ebp)
	pushl	12(%ebp)
	pushl	8(%ebp)
	movl	-8(%ebp),%eax
	movl	16(%eax),%eax
	movl	-4(%ebp),%edx
	movl	-8(%ebp),%ecx
	movl	16(%ecx),%ecx
	movl	(%ecx),%ecx
	call	*12(%ecx)
	movl	%ebp,%esp
	popl	%ebp
	ret	$8

.section .text.n_vdbbackendapi$_$tvdbbackendkvstore_$__$$_get$qword$tbytes$$boolean,"x"
	.balign 16,0x90
.globl	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_GET$QWORD$TBYTES$$BOOLEAN
VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_GET$QWORD$TBYTES$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-12(%esp),%esp
	pushl	%ebx
	movl	%eax,-8(%ebp)
	movl	%edx,-4(%ebp)
	movl	-4(%ebp),%eax
	movl	$0,(%eax)
	movl	-4(%ebp),%ebx
	movl	$RTTI_$SYSUTILS_$$_TBYTES,%edx
	movl	%ebx,%eax
	call	fpc_finalize
	pushl	12(%ebp)
	pushl	8(%ebp)
	movl	%ebx,%edx
	movl	-8(%ebp),%eax
	movl	16(%eax),%eax
	movl	-8(%ebp),%ecx
	movl	16(%ecx),%ecx
	movl	(%ecx),%ecx
	call	*20(%ecx)
	movb	%al,-12(%ebp)
	movb	-12(%ebp),%al
	popl	%ebx
	movl	%ebp,%esp
	popl	%ebp
	ret	$8

.section .text.n_vdbbackendapi$_$tvdbbackendkvstore_$__$$_delete$qword$$boolean,"x"
	.balign 16,0x90
.globl	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_DELETE$QWORD$$BOOLEAN
VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_DELETE$QWORD$$BOOLEAN:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-8(%esp),%esp
	movl	%eax,-4(%ebp)
	pushl	12(%ebp)
	pushl	8(%ebp)
	movl	-4(%ebp),%eax
	movl	16(%eax),%eax
	movl	-4(%ebp),%edx
	movl	16(%edx),%edx
	movl	(%edx),%edx
	call	*24(%edx)
	movb	%al,-8(%ebp)
	movb	-8(%ebp),%al
	movl	%ebp,%esp
	popl	%ebp
	ret	$8

.section .text.n_vdbbackendapi$_$tvdbbackendkvstore_$__$$_scanall$tqwordarray$tvalarray$longint,"x"
	.balign 16,0x90
.globl	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_SCANALL$TQWORDARRAY$TVALARRAY$LONGINT
VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_SCANALL$TQWORDARRAY$TVALARRAY$LONGINT:
	pushl	%ebp
	movl	%esp,%ebp
	leal	-12(%esp),%esp
	pushl	%ebx
	pushl	%esi
	pushl	%edi
	movl	%eax,-12(%ebp)
	movl	%edx,-4(%ebp)
	movl	%ecx,-8(%ebp)
	movl	-4(%ebp),%eax
	movl	$0,(%eax)
	movl	-8(%ebp),%eax
	movl	$0,(%eax)
	movl	-4(%ebp),%ebx
	movl	$RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY,%edx
	movl	%ebx,%eax
	call	fpc_finalize
	movl	-8(%ebp),%esi
	movl	$RTTI_$VDBBACKENDAPI_$$_TVALARRAY,%edx
	movl	%esi,%eax
	call	fpc_finalize
	pushl	8(%ebp)
	movl	%esi,%edi
	movl	%edi,%ecx
	movl	%ebx,%edx
	movl	-12(%ebp),%eax
	movl	16(%eax),%eax
	movl	-12(%ebp),%esi
	movl	16(%esi),%esi
	movl	(%esi),%esi
	call	*36(%esi)
	popl	%edi
	popl	%esi
	popl	%ebx
	movl	%ebp,%esp
	popl	%ebp
	ret	$4

.section .text.n_WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_0_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$_QUERYINTERFACE$TGUID$formal$$CRCF90CD3F4,"x"
	.balign 16,0x90
.globl	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_0_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$_QUERYINTERFACE$TGUID$formal$$CRCF90CD3F4
WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_0_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$_QUERYINTERFACE$TGUID$formal$$CRCF90CD3F4:
	subl	$20,4(%esp)
	jmp	SYSTEM$_$TINTERFACEDOBJECT_$__$$_QUERYINTERFACE$TGUID$formal$$LONGINT

.section .text.n_WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_1_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__ADDREF$$LONGINT,"x"
	.balign 16,0x90
.globl	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_1_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__ADDREF$$LONGINT
WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_1_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__ADDREF$$LONGINT:
	subl	$20,4(%esp)
	jmp	SYSTEM$_$TINTERFACEDOBJECT_$__$$__ADDREF$$LONGINT

.section .text.n_WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_2_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__RELEASE$$LONGINT,"x"
	.balign 16,0x90
.globl	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_2_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__RELEASE$$LONGINT
WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_2_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__RELEASE$$LONGINT:
	subl	$20,4(%esp)
	jmp	SYSTEM$_$TINTERFACEDOBJECT_$__$$__RELEASE$$LONGINT

.section .text.n_WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_3_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_PUT$QWORD$TBYTES,"x"
	.balign 16,0x90
.globl	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_3_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_PUT$QWORD$TBYTES
WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_3_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_PUT$QWORD$TBYTES:
	subl	$20,%eax
	jmp	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_PUT$QWORD$TBYTES

.section .text.n_WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_4_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_GET$QWORD$TBYTES$$BO$CRCC31482F8,"x"
	.balign 16,0x90
.globl	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_4_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_GET$QWORD$TBYTES$$BO$CRCC31482F8
WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_4_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_GET$QWORD$TBYTES$$BO$CRCC31482F8:
	subl	$20,%eax
	jmp	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_GET$QWORD$TBYTES$$BOOLEAN

.section .text.n_WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_5_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_DELETE$QWORD$$BOOLEA$CRC4366831A,"x"
	.balign 16,0x90
.globl	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_5_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_DELETE$QWORD$$BOOLEA$CRC4366831A
WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_5_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_DELETE$QWORD$$BOOLEA$CRC4366831A:
	subl	$20,%eax
	jmp	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_DELETE$QWORD$$BOOLEAN

.section .text.n_WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_6_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_SCANALL$TQWORDARRAY$$CRCD05A3244,"x"
	.balign 16,0x90
.globl	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_6_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_SCANALL$TQWORDARRAY$$CRCD05A3244
WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_6_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_SCANALL$TQWORDARRAY$$CRCD05A3244:
	subl	$20,%eax
	jmp	VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_SCANALL$TQWORDARRAY$TVALARRAY$LONGINT
# End asmlist al_procedures
# Begin asmlist al_globals

.section .rodata.n_IID_$VDBBACKENDAPI_$$_IVDBKVSTORE,"d"
	.balign 4
.globl	IID_$VDBBACKENDAPI_$$_IVDBKVSTORE
IID_$VDBBACKENDAPI_$$_IVDBKVSTORE:
	.long	1837837937
	.short	19482,20334
	.byte	158,59,122,92,13,47,26,68

.section .rodata.n_IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE,"d"
	.balign 4
.globl	IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE
IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE:
	.byte	38
	.ascii	"{6D8B2E71-4C1A-4F6E-9E3B-7A5C0D2F1A44}"

.section .rodata.n_IID_$VDBBACKENDAPI_$$_IVDBBACKEND,"d"
	.balign 4
.globl	IID_$VDBBACKENDAPI_$$_IVDBBACKEND
IID_$VDBBACKENDAPI_$$_IVDBBACKEND:
	.long	-1260271710
	.short	40753,19816
	.byte	142,90,44,123,29,144,78,86

.section .rodata.n_IIDSTR_$VDBBACKENDAPI_$$_IVDBBACKEND,"d"
	.balign 4
.globl	IIDSTR_$VDBBACKENDAPI_$$_IVDBBACKEND
IIDSTR_$VDBBACKENDAPI_$$_IVDBBACKEND:
	.byte	38
	.ascii	"{B4E1C7A2-9F31-4D68-8E5A-2C7B1D904E56}"

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,"d"
	.balign 4
.globl	VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI
VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI:
	.long	12,-12
	.long	VMT_$SYSUTILS_$$_EXCEPTION$indirect
	.long	.Ld2
	.long	0,0,0
	.long	RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI
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

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 4
.globl	VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE
VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE:
	.long	24,-24
	.long	VMT_$SYSTEM_$$_TINTERFACEDOBJECT$indirect
	.long	.Ld3
	.long	0,0,0
	.long	RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE
	.long	INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE
	.long	0
	.long	.Ld5
	.long	0
	.long	SYSTEM$_$TINTERFACEDOBJECT_$__$$_DESTROY
	.long	SYSTEM$_$TINTERFACEDOBJECT_$__$$_NEWINSTANCE$$TOBJECT
	.long	SYSTEM$_$TOBJECT_$__$$_FREEINSTANCE
	.long	SYSTEM$_$TOBJECT_$__$$_SAFECALLEXCEPTION$TOBJECT$POINTER$$HRESULT
	.long	SYSTEM$_$TOBJECT_$__$$_DEFAULTHANDLER$formal
	.long	SYSTEM$_$TINTERFACEDOBJECT_$__$$_AFTERCONSTRUCTION
	.long	SYSTEM$_$TINTERFACEDOBJECT_$__$$_BEFOREDESTRUCTION
	.long	SYSTEM$_$TOBJECT_$__$$_DEFAULTHANDLERSTR$formal
	.long	SYSTEM$_$TOBJECT_$__$$_DISPATCH$formal
	.long	SYSTEM$_$TOBJECT_$__$$_DISPATCHSTR$formal
	.long	SYSTEM$_$TOBJECT_$__$$_EQUALS$TOBJECT$$BOOLEAN
	.long	SYSTEM$_$TOBJECT_$__$$_GETHASHCODE$$LONGINT
	.long	SYSTEM$_$TOBJECT_$__$$_TOSTRING$$ANSISTRING
	.long	0
# End asmlist al_globals
# Begin asmlist al_const

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,"d"
	.balign 4
.Ld2:
	.byte	14
	.ascii	"EVdbBackendApi"

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 4
.Ld3:
	.byte	18
	.ascii	"TVdbBackendKvStore"

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 4
.Ld4:
	.long	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_0_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$_QUERYINTERFACE$TGUID$formal$$CRCF90CD3F4
	.long	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_1_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__ADDREF$$LONGINT
	.long	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_2_$_SYSTEM$_$TINTERFACEDOBJECT_$__$$__RELEASE$$LONGINT
	.long	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_3_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_PUT$QWORD$TBYTES
	.long	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_4_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_GET$QWORD$TBYTES$$BO$CRCC31482F8
	.long	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_5_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_DELETE$QWORD$$BOOLEA$CRC4366831A
	.long	WRPR_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE_$_IVDBKVSTORE_$_6_$_VDBBACKENDAPI$_$TVDBBACKENDKVSTORE_$__$$_SCANALL$TQWORDARRAY$$CRCD05A3244

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 4
.Ld5:
	.long	1
	.long	IID_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect
	.long	.Ld4
	.long	20
	.long	IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect
	.long	0
# End asmlist al_const
# Begin asmlist al_typedconsts

.section .data.n_TC_$VDBBACKENDAPI_$$_VDBSESSIONIDFUNC,"d"
	.balign 4
.globl	TC_$VDBBACKENDAPI_$$_VDBSESSIONIDFUNC
TC_$VDBBACKENDAPI_$$_VDBSESSIONIDFUNC:
	.long	0

.section .rodata.n_.Ld1,"d"
	.balign 4
.Ld1$strlab:
	.short	0,1
	.long	-1,31
.Ld1:
	.ascii	"TVdbBackendKvStore: backend nil\000"
# End asmlist al_typedconsts
# Begin asmlist al_rtti

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY
RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY:
	.byte	21,11
	.ascii	"TQWordArray"
	.long	8
	.long	RTTI_$SYSTEM_$$_QWORD$indirect
	.long	21,0
	.byte	13
	.ascii	"VDbBackendApi"

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVALARRAY,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TVALARRAY
RTTI_$VDBBACKENDAPI_$$_TVALARRAY:
	.byte	21,9
	.ascii	"TValArray"
	.long	4
	.long	RTTI_$SYSUTILS_$$_TBYTES$indirect
	.long	-1
	.long	RTTI_$SYSUTILS_$$_TBYTES$indirect
	.byte	13
	.ascii	"VDbBackendApi"

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBROWTAGFUNC,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBROWTAGFUNC
RTTI_$VDBBACKENDAPI_$$_TVDBROWTAGFUNC:
	.byte	23,14
	.ascii	"TVDbRowTagFunc"
	.byte	0,0
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.byte	2
	.short	0
	.long	RTTI_$SYSTEM_$$_PBYTE$indirect
	.byte	10
	.ascii	"PlainValue"
	.short	0
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.byte	8
	.ascii	"ValueLen"

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBRAWCB,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBRAWCB
RTTI_$VDBBACKENDAPI_$$_TVDBRAWCB:
	.byte	23,9
	.ascii	"TVDbRawCb"
	.byte	0,0
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.byte	4
	.short	0
	.long	RTTI_$SYSTEM_$$_QWORD$indirect
	.byte	3
	.ascii	"Key"
	.short	0
	.long	RTTI_$SYSTEM_$$_PBYTE$indirect
	.byte	3
	.ascii	"Buf"
	.short	0
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.byte	3
	.ascii	"Len"
	.short	0
	.long	RTTI_$SYSTEM_$$_POINTER$indirect
	.byte	4
	.ascii	"User"

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBRAWPAGECB,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBRAWPAGECB
RTTI_$VDBBACKENDAPI_$$_TVDBRAWPAGECB:
	.byte	23,13
	.ascii	"TVDbRawPageCb"
	.byte	0,0
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.byte	5
	.short	0
	.long	RTTI_$SYSTEM_$$_QWORD$indirect
	.byte	3
	.ascii	"Key"
	.short	0
	.long	RTTI_$SYSTEM_$$_PBYTE$indirect
	.byte	3
	.ascii	"Buf"
	.short	0
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.byte	3
	.ascii	"Len"
	.short	0
	.long	RTTI_$SYSTEM_$$_LONGWORD$indirect
	.byte	6
	.ascii	"PageNo"
	.short	0
	.long	RTTI_$SYSTEM_$$_POINTER$indirect
	.byte	4
	.ascii	"User"

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TDBCOMMITHOOK,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TDBCOMMITHOOK
RTTI_$VDBBACKENDAPI_$$_TDBCOMMITHOOK:
	.byte	6,13
	.ascii	"TDbCommitHook"
	.byte	0,1
	.short	640
	.byte	5
	.ascii	"$self"
	.byte	7
	.ascii	"Pointer"
	.byte	0
	.long	RTTI_$SYSTEM_$$_POINTER$indirect

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBSESSIONIDFUNC,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBSESSIONIDFUNC
RTTI_$VDBBACKENDAPI_$$_TVDBSESSIONIDFUNC:
	.byte	23,17
	.ascii	"TVdbSessionIdFunc"
	.byte	0,0
	.long	RTTI_$SYSTEM_$$_LONGWORD$indirect
	.byte	0

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_IVDBKVSTORE,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_IVDBKVSTORE
RTTI_$VDBBACKENDAPI_$$_IVDBKVSTORE:
	.byte	14,11
	.ascii	"IVDbKvStore"
	.long	RTTI_$SYSTEM_$$_IUNKNOWN$indirect
	.byte	1
	.long	1837837937
	.short	19482,20334
	.byte	158,59,122,92,13,47,26,68,13
	.ascii	"VDbBackendApi"
	.short	0,4,65535

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND
RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND:
	.byte	14,11
	.ascii	"IVDbBackend"
	.long	RTTI_$SYSTEM_$$_IUNKNOWN$indirect
	.byte	1
	.long	-1260271710
	.short	40753,19816
	.byte	142,90,44,123,29,144,78,86,13
	.ascii	"VDbBackendApi"
	.short	0,74,65535

.section .rodata.n_INIT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,"d"
	.balign 8
.globl	INIT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI
INIT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI:
	.byte	15,14
	.ascii	"EVdbBackendApi"
	.long	0,4,0,0,0

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI
RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI:
	.byte	15,14
	.ascii	"EVdbBackendApi"
	.long	VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI
	.long	RTTI_$SYSUTILS_$$_EXCEPTION$indirect
	.short	0
	.byte	13
	.ascii	"VDbBackendApi"
	.short	0

.section .rodata.n_INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 8
.globl	INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE
INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE:
	.byte	15,18
	.ascii	"TVdbBackendKvStore"
	.long	0,4,0,0,1
	.long	RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND$indirect
	.long	16

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 8
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE
RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE:
	.byte	15,18
	.ascii	"TVdbBackendKvStore"
	.long	VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE
	.long	RTTI_$SYSTEM_$$_TINTERFACEDOBJECT$indirect
	.short	0
	.byte	13
	.ascii	"VDbBackendApi"
	.short	0
# End asmlist al_rtti
# Begin asmlist al_indirectglobals

.section .rodata.n_IID_$VDBBACKENDAPI_$$_IVDBKVSTORE,"d"
	.balign 4
.globl	IID_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect
IID_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect:
	.long	IID_$VDBBACKENDAPI_$$_IVDBKVSTORE

.section .rodata.n_IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE,"d"
	.balign 4
.globl	IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect
IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect:
	.long	IIDSTR_$VDBBACKENDAPI_$$_IVDBKVSTORE

.section .rodata.n_IID_$VDBBACKENDAPI_$$_IVDBBACKEND,"d"
	.balign 4
.globl	IID_$VDBBACKENDAPI_$$_IVDBBACKEND$indirect
IID_$VDBBACKENDAPI_$$_IVDBBACKEND$indirect:
	.long	IID_$VDBBACKENDAPI_$$_IVDBBACKEND

.section .rodata.n_IIDSTR_$VDBBACKENDAPI_$$_IVDBBACKEND,"d"
	.balign 4
.globl	IIDSTR_$VDBBACKENDAPI_$$_IVDBBACKEND$indirect
IIDSTR_$VDBBACKENDAPI_$$_IVDBBACKEND$indirect:
	.long	IIDSTR_$VDBBACKENDAPI_$$_IVDBBACKEND

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,"d"
	.balign 4
.globl	VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI$indirect
VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI$indirect:
	.long	VMT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI

.section .rodata.n_VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 4
.globl	VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE$indirect
VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE$indirect:
	.long	VMT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY$indirect
RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TQWORDARRAY

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVALARRAY,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TVALARRAY$indirect
RTTI_$VDBBACKENDAPI_$$_TVALARRAY$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TVALARRAY

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBROWTAGFUNC,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBROWTAGFUNC$indirect
RTTI_$VDBBACKENDAPI_$$_TVDBROWTAGFUNC$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TVDBROWTAGFUNC

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBRAWCB,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBRAWCB$indirect
RTTI_$VDBBACKENDAPI_$$_TVDBRAWCB$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TVDBRAWCB

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBRAWPAGECB,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBRAWPAGECB$indirect
RTTI_$VDBBACKENDAPI_$$_TVDBRAWPAGECB$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TVDBRAWPAGECB

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TDBCOMMITHOOK,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TDBCOMMITHOOK$indirect
RTTI_$VDBBACKENDAPI_$$_TDBCOMMITHOOK$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TDBCOMMITHOOK

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBSESSIONIDFUNC,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBSESSIONIDFUNC$indirect
RTTI_$VDBBACKENDAPI_$$_TVDBSESSIONIDFUNC$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TVDBSESSIONIDFUNC

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_IVDBKVSTORE,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect
RTTI_$VDBBACKENDAPI_$$_IVDBKVSTORE$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_IVDBKVSTORE

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND$indirect
RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_IVDBBACKEND

.section .rodata.n_INIT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,"d"
	.balign 4
.globl	INIT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI$indirect
INIT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI$indirect:
	.long	INIT_$VDBBACKENDAPI_$$_EVDBBACKENDAPI

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI$indirect
RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_EVDBBACKENDAPI

.section .rodata.n_INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 4
.globl	INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE$indirect
INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE$indirect:
	.long	INIT_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE

.section .rodata.n_RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE,"d"
	.balign 4
.globl	RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE$indirect
RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE$indirect:
	.long	RTTI_$VDBBACKENDAPI_$$_TVDBBACKENDKVSTORE
# End asmlist al_indirectglobals

