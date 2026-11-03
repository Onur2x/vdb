	.file "VDbTypes.pas"
# Begin asmlist al_typedconsts

.section .data.n_TC_$VDBTYPES_$$_VDB_SCHEMA_KEY,"d"
	.balign 8
.globl	TC_$VDBTYPES_$$_VDB_SCHEMA_KEY
TC_$VDBTYPES_$$_VDB_SCHEMA_KEY:
	.long	0,0
# End asmlist al_typedconsts
# Begin asmlist al_rtti

.section .rodata.n_RTTI_$VDBTYPES_$$_TPRIVKIND,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TPRIVKIND
RTTI_$VDBTYPES_$$_TPRIVKIND:
	.byte	3,9
	.ascii	"TPrivKind"
	.byte	1
	.long	0,5,0
	.byte	6
	.ascii	"pkNone"
	.byte	8
	.ascii	"pkSelect"
	.byte	8
	.ascii	"pkInsert"
	.byte	8
	.ascii	"pkUpdate"
	.byte	8
	.ascii	"pkDelete"
	.byte	5
	.ascii	"pkAll"
	.byte	8
	.ascii	"VDbTypes"
	.byte	0

.section .rodata.n_RTTI_$VDBTYPES_$$_TPRIVKIND_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TPRIVKIND_s2o
RTTI_$VDBTYPES_$$_TPRIVKIND_s2o:
	.long	6,5
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+67
	.long	4
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+58
	.long	2
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+40
	.long	0
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+24
	.long	1
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+31
	.long	3
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+49

.section .rodata.n_RTTI_$VDBTYPES_$$_TPRIVKIND_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TPRIVKIND_o2s
RTTI_$VDBTYPES_$$_TPRIVKIND_o2s:
	.long	0
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+24
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+31
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+40
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+49
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+58
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND+67

.section .rodata.n_RTTI_$VDBTYPES_$$_TSTRARRAY,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TSTRARRAY
RTTI_$VDBTYPES_$$_TSTRARRAY:
	.byte	21,9
	.ascii	"TStrArray"
	.long	4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	256
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TSTRMATRIX,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TSTRMATRIX
RTTI_$VDBTYPES_$$_TSTRMATRIX:
	.byte	21,10
	.ascii	"TStrMatrix"
	.long	4
	.long	RTTI_$VDBTYPES_$$_TSTRARRAY$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TSTRARRAY$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TINTARRAY,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TINTARRAY
RTTI_$VDBTYPES_$$_TINTARRAY:
	.byte	21,9
	.ascii	"TIntArray"
	.long	4
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.long	3,0
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TBYTEARRAY,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TBYTEARRAY
RTTI_$VDBTYPES_$$_TBYTEARRAY:
	.byte	21,10
	.ascii	"TByteArray"
	.long	1
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	17,0
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_TCOLDEF,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TCOLDEF
INIT_$VDBTYPES_$$_TCOLDEF:
	.byte	13,7
	.ascii	"TColDef"
	.long	0,48,0,0,4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	16
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	24

.section .rodata.n_RTTI_$VDBTYPES_$$_TCOLDEF,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TCOLDEF
RTTI_$VDBTYPES_$$_TCOLDEF:
	.byte	13,7
	.ascii	"TColDef"
	.long	INIT_$VDBTYPES_$$_TCOLDEF
	.long	48,14
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.long	5
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.long	6
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.long	7
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	12
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	16
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.long	20
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	24
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	28
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.long	32
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.long	36
	.long	RTTI_$SYSTEM_$$_QWORD$indirect
	.long	40

.section .rodata.n_INIT_$VDBTYPES_$$_TFKDEF,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TFKDEF
INIT_$VDBTYPES_$$_TFKDEF:
	.byte	13,6
	.ascii	"TFkDef"
	.long	0,24,0,0,4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	12
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	16

.section .rodata.n_RTTI_$VDBTYPES_$$_TFKDEF,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TFKDEF
RTTI_$VDBTYPES_$$_TFKDEF:
	.byte	13,6
	.ascii	"TFkDef"
	.long	INIT_$VDBTYPES_$$_TFKDEF
	.long	24,6
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	12
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	16
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	20

.section .rodata.n_RTTI_$VDBTYPES_$$_TONCONFLICTACTION,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TONCONFLICTACTION
RTTI_$VDBTYPES_$$_TONCONFLICTACTION:
	.byte	3,17
	.ascii	"TOnConflictAction"
	.byte	1
	.long	0,2,0
	.byte	7
	.ascii	"ocaNone"
	.byte	12
	.ascii	"ocaDoNothing"
	.byte	11
	.ascii	"ocaDoUpdate"
	.byte	8
	.ascii	"VDbTypes"
	.byte	0

.section .rodata.n_RTTI_$VDBTYPES_$$_TONCONFLICTACTION_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TONCONFLICTACTION_s2o
RTTI_$VDBTYPES_$$_TONCONFLICTACTION_s2o:
	.long	3,1
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION+40
	.long	2
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION+53
	.long	0
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION+32

.section .rodata.n_RTTI_$VDBTYPES_$$_TONCONFLICTACTION_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TONCONFLICTACTION_o2s
RTTI_$VDBTYPES_$$_TONCONFLICTACTION_o2s:
	.long	0
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION+32
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION+40
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION+53

.section .rodata.n_RTTI_$VDBTYPES_$$_TINSERTORACTION,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TINSERTORACTION
RTTI_$VDBTYPES_$$_TINSERTORACTION:
	.byte	3,15
	.ascii	"TInsertOrAction"
	.byte	1
	.long	0,5,0
	.byte	7
	.ascii	"ioaNone"
	.byte	10
	.ascii	"ioaReplace"
	.byte	9
	.ascii	"ioaIgnore"
	.byte	8
	.ascii	"ioaAbort"
	.byte	7
	.ascii	"ioaFail"
	.byte	11
	.ascii	"ioaRollback"
	.byte	8
	.ascii	"VDbTypes"
	.byte	0

.section .rodata.n_RTTI_$VDBTYPES_$$_TINSERTORACTION_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TINSERTORACTION_s2o
RTTI_$VDBTYPES_$$_TINSERTORACTION_s2o:
	.long	6,3
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+59
	.long	4
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+68
	.long	2
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+49
	.long	0
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+30
	.long	1
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+38
	.long	5
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+76

.section .rodata.n_RTTI_$VDBTYPES_$$_TINSERTORACTION_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TINSERTORACTION_o2s
RTTI_$VDBTYPES_$$_TINSERTORACTION_o2s:
	.long	0
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+30
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+38
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+49
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+59
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+68
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION+76

.section .rodata.n_INIT_$VDBTYPES_$$_TSETEXPR,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TSETEXPR
INIT_$VDBTYPES_$$_TSETEXPR:
	.byte	13,8
	.ascii	"TSetExpr"
	.long	0,20,0,0,1
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	16

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETEXPR,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TSETEXPR
RTTI_$VDBTYPES_$$_TSETEXPR:
	.byte	13,8
	.ascii	"TSetExpr"
	.long	INIT_$VDBTYPES_$$_TSETEXPR
	.long	20,5
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_CHAR$indirect
	.long	12
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	16

.section .rodata.n_INIT_$VDBTYPES_$$_TSETEXPRS,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TSETEXPRS
INIT_$VDBTYPES_$$_TSETEXPRS:
	.byte	21,9
	.ascii	"TSetExprs"
	.long	20
	.long	INIT_$VDBTYPES_$$_TSETEXPR$indirect
	.long	-1
	.long	INIT_$VDBTYPES_$$_TSETEXPR$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETEXPRS,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TSETEXPRS
RTTI_$VDBTYPES_$$_TSETEXPRS:
	.byte	21,9
	.ascii	"TSetExprs"
	.long	20
	.long	RTTI_$VDBTYPES_$$_TSETEXPR$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TSETEXPR$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_TSETVALUEPAIR,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TSETVALUEPAIR
INIT_$VDBTYPES_$$_TSETVALUEPAIR:
	.byte	13,13
	.ascii	"TSetValuePair"
	.long	0,8,0,0,1
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETVALUEPAIR,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TSETVALUEPAIR
RTTI_$VDBTYPES_$$_TSETVALUEPAIR:
	.byte	13,13
	.ascii	"TSetValuePair"
	.long	INIT_$VDBTYPES_$$_TSETVALUEPAIR
	.long	8,2
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4

.section .rodata.n_INIT_$VDBTYPES_$$_TSETVALUEPAIRS,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TSETVALUEPAIRS
INIT_$VDBTYPES_$$_TSETVALUEPAIRS:
	.byte	21,14
	.ascii	"TSetValuePairs"
	.long	8
	.long	INIT_$VDBTYPES_$$_TSETVALUEPAIR$indirect
	.long	-1
	.long	INIT_$VDBTYPES_$$_TSETVALUEPAIR$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETVALUEPAIRS,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TSETVALUEPAIRS
RTTI_$VDBTYPES_$$_TSETVALUEPAIRS:
	.byte	21,14
	.ascii	"TSetValuePairs"
	.long	8
	.long	RTTI_$VDBTYPES_$$_TSETVALUEPAIR$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TSETVALUEPAIR$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_TWHERECOND,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TWHERECOND
INIT_$VDBTYPES_$$_TWHERECOND:
	.byte	13,10
	.ascii	"TWhereCond"
	.long	0,20,0,0,3
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	12
	.long	RTTI_$VDBTYPES_$$_TSTRARRAY$indirect
	.long	16

.section .rodata.n_RTTI_$VDBTYPES_$$_TWHERECOND,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TWHERECOND
RTTI_$VDBTYPES_$$_TWHERECOND:
	.byte	13,10
	.ascii	"TWhereCond"
	.long	INIT_$VDBTYPES_$$_TWHERECOND
	.long	20,5
	.long	RTTI_$SYSTEM_$$_LONGINT$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	12
	.long	RTTI_$VDBTYPES_$$_TSTRARRAY$indirect
	.long	16

.section .rodata.n_INIT_$VDBTYPES_$$_TWHEREGROUP,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TWHEREGROUP
INIT_$VDBTYPES_$$_TWHEREGROUP:
	.byte	21,11
	.ascii	"TWhereGroup"
	.long	20
	.long	INIT_$VDBTYPES_$$_TWHERECOND$indirect
	.long	-1
	.long	INIT_$VDBTYPES_$$_TWHERECOND$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TWHEREGROUP,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TWHEREGROUP
RTTI_$VDBTYPES_$$_TWHEREGROUP:
	.byte	21,11
	.ascii	"TWhereGroup"
	.long	20
	.long	RTTI_$VDBTYPES_$$_TWHERECOND$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TWHERECOND$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_TWHEREGROUPS,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TWHEREGROUPS
INIT_$VDBTYPES_$$_TWHEREGROUPS:
	.byte	21,12
	.ascii	"TWhereGroups"
	.long	4
	.long	INIT_$VDBTYPES_$$_TWHEREGROUP$indirect
	.long	-1
	.long	INIT_$VDBTYPES_$$_TWHEREGROUP$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TWHEREGROUPS,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TWHEREGROUPS
RTTI_$VDBTYPES_$$_TWHEREGROUPS:
	.byte	21,12
	.ascii	"TWhereGroups"
	.long	4
	.long	RTTI_$VDBTYPES_$$_TWHEREGROUP$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TWHEREGROUP$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_TFKARRAY,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TFKARRAY
INIT_$VDBTYPES_$$_TFKARRAY:
	.byte	21,8
	.ascii	"TFkArray"
	.long	24
	.long	INIT_$VDBTYPES_$$_TFKDEF$indirect
	.long	-1
	.long	INIT_$VDBTYPES_$$_TFKDEF$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TFKARRAY,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TFKARRAY
RTTI_$VDBTYPES_$$_TFKARRAY:
	.byte	21,8
	.ascii	"TFkArray"
	.long	24
	.long	RTTI_$VDBTYPES_$$_TFKDEF$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TFKDEF$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGEREVENT,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TTRIGGEREVENT
RTTI_$VDBTYPES_$$_TTRIGGEREVENT:
	.byte	3,13
	.ascii	"TTriggerEvent"
	.byte	1
	.long	0,2,0
	.byte	8
	.ascii	"teInsert"
	.byte	8
	.ascii	"teUpdate"
	.byte	8
	.ascii	"teDelete"
	.byte	8
	.ascii	"VDbTypes"
	.byte	0

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGEREVENT_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGEREVENT_s2o
RTTI_$VDBTYPES_$$_TTRIGGEREVENT_s2o:
	.long	3,2
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT+46
	.long	0
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT+28
	.long	1
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT+37

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGEREVENT_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGEREVENT_o2s
RTTI_$VDBTYPES_$$_TTRIGGEREVENT_o2s:
	.long	0
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT+28
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT+37
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT+46

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERTIMING,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TTRIGGERTIMING
RTTI_$VDBTYPES_$$_TTRIGGERTIMING:
	.byte	3,14
	.ascii	"TTriggerTiming"
	.byte	1
	.long	0,2,0
	.byte	8
	.ascii	"ttBefore"
	.byte	7
	.ascii	"ttAfter"
	.byte	11
	.ascii	"ttInsteadOf"
	.byte	8
	.ascii	"VDbTypes"
	.byte	0

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERTIMING_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERTIMING_s2o
RTTI_$VDBTYPES_$$_TTRIGGERTIMING_s2o:
	.long	3,1
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING+38
	.long	0
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING+29
	.long	2
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING+46

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERTIMING_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERTIMING_o2s
RTTI_$VDBTYPES_$$_TTRIGGERTIMING_o2s:
	.long	0
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING+29
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING+38
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING+46

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERFOREACH,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH
RTTI_$VDBTYPES_$$_TTRIGGERFOREACH:
	.byte	3,15
	.ascii	"TTriggerForEach"
	.byte	1
	.long	0,1,0
	.byte	5
	.ascii	"tfRow"
	.byte	11
	.ascii	"tfStatement"
	.byte	8
	.ascii	"VDbTypes"
	.byte	0

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_s2o
RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_s2o:
	.long	2,0
	.long	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH+30
	.long	1
	.long	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH+36

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_o2s
RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_o2s:
	.long	0
	.long	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH+30
	.long	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH+36

.section .rodata.n_RTTI_$VDBTYPES_$$_def0000001E,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_def0000001E
RTTI_$VDBTYPES_$$_def0000001E:
	.byte	21,0
	.long	1
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	17,0
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_TTRIGGERDEF,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TTRIGGERDEF
INIT_$VDBTYPES_$$_TTRIGGERDEF:
	.byte	13,11
	.ascii	"TTriggerDef"
	.long	0,24,0,0,3
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4
	.long	RTTI_$VDBTYPES_$$_def0000001E$indirect
	.long	12

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERDEF,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TTRIGGERDEF
RTTI_$VDBTYPES_$$_TTRIGGERDEF:
	.byte	13,11
	.ascii	"TTriggerDef"
	.long	INIT_$VDBTYPES_$$_TTRIGGERDEF
	.long	24,7
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	9
	.long	RTTI_$VDBTYPES_$$_def0000001E$indirect
	.long	12
	.long	RTTI_$SYSTEM_$$_TOBJECT$indirect
	.long	16
	.long	RTTI_$SYSTEM_$$_TOBJECT$indirect
	.long	20

.section .rodata.n_INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER
INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER:
	.byte	13,18
	.ascii	"TFunctionParameter"
	.long	0,16,0,0,2
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4

.section .rodata.n_RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER
RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER:
	.byte	13,18
	.ascii	"TFunctionParameter"
	.long	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER
	.long	16,4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_BYTE$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_TOBJECT$indirect
	.long	12

.section .rodata.n_INIT_$VDBTYPES_$$_TFUNCTIONPARAMARRAY,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TFUNCTIONPARAMARRAY
INIT_$VDBTYPES_$$_TFUNCTIONPARAMARRAY:
	.byte	21,19
	.ascii	"TFunctionParamArray"
	.long	16
	.long	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.long	-1
	.long	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TFUNCTIONPARAMARRAY,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMARRAY
RTTI_$VDBTYPES_$$_TFUNCTIONPARAMARRAY:
	.byte	21,19
	.ascii	"TFunctionParamArray"
	.long	16
	.long	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_def00000022,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_def00000022
INIT_$VDBTYPES_$$_def00000022:
	.byte	21,0
	.long	16
	.long	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.long	-1
	.long	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_INIT_$VDBTYPES_$$_TFUNCTIONDEF,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TFUNCTIONDEF
INIT_$VDBTYPES_$$_TFUNCTIONDEF:
	.byte	13,12
	.ascii	"TFunctionDef"
	.long	0,24,0,0,4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	INIT_$VDBTYPES_$$_def00000022$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	12

.section .rodata.n_RTTI_$VDBTYPES_$$_def00000022,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_def00000022
RTTI_$VDBTYPES_$$_def00000022:
	.byte	21,0
	.long	16
	.long	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.long	-1
	.long	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
	.byte	8
	.ascii	"VDbTypes"

.section .rodata.n_RTTI_$VDBTYPES_$$_TFUNCTIONDEF,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TFUNCTIONDEF
RTTI_$VDBTYPES_$$_TFUNCTIONDEF:
	.byte	13,12
	.ascii	"TFunctionDef"
	.long	INIT_$VDBTYPES_$$_TFUNCTIONDEF
	.long	24,6
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$VDBTYPES_$$_def00000022$indirect
	.long	4
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	8
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	12
	.long	RTTI_$SYSTEM_$$_TOBJECT$indirect
	.long	16
	.long	RTTI_$SYSTEM_$$_BOOLEAN$indirect
	.long	20

.section .rodata.n_INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT,"d"
	.balign 8
.globl	INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT
INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT:
	.byte	13,17
	.ascii	"TUpdateAssignment"
	.long	0,8,0,0,1
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0

.section .rodata.n_RTTI_$VDBTYPES_$$_TUPDATEASSIGNMENT,"d"
	.balign 8
.globl	RTTI_$VDBTYPES_$$_TUPDATEASSIGNMENT
RTTI_$VDBTYPES_$$_TUPDATEASSIGNMENT:
	.byte	13,17
	.ascii	"TUpdateAssignment"
	.long	INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT
	.long	8,2
	.long	RTTI_$SYSTEM_$$_ANSISTRING$indirect
	.long	0
	.long	RTTI_$SYSTEM_$$_TOBJECT$indirect
	.long	4
# End asmlist al_rtti
# Begin asmlist al_indirectglobals

.section .rodata.n_RTTI_$VDBTYPES_$$_TPRIVKIND,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TPRIVKIND$indirect
RTTI_$VDBTYPES_$$_TPRIVKIND$indirect:
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND

.section .rodata.n_RTTI_$VDBTYPES_$$_TPRIVKIND_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TPRIVKIND_s2o$indirect
RTTI_$VDBTYPES_$$_TPRIVKIND_s2o$indirect:
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND_s2o

.section .rodata.n_RTTI_$VDBTYPES_$$_TPRIVKIND_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TPRIVKIND_o2s$indirect
RTTI_$VDBTYPES_$$_TPRIVKIND_o2s$indirect:
	.long	RTTI_$VDBTYPES_$$_TPRIVKIND_o2s

.section .rodata.n_RTTI_$VDBTYPES_$$_TSTRARRAY,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TSTRARRAY$indirect
RTTI_$VDBTYPES_$$_TSTRARRAY$indirect:
	.long	RTTI_$VDBTYPES_$$_TSTRARRAY

.section .rodata.n_RTTI_$VDBTYPES_$$_TSTRMATRIX,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TSTRMATRIX$indirect
RTTI_$VDBTYPES_$$_TSTRMATRIX$indirect:
	.long	RTTI_$VDBTYPES_$$_TSTRMATRIX

.section .rodata.n_RTTI_$VDBTYPES_$$_TINTARRAY,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TINTARRAY$indirect
RTTI_$VDBTYPES_$$_TINTARRAY$indirect:
	.long	RTTI_$VDBTYPES_$$_TINTARRAY

.section .rodata.n_RTTI_$VDBTYPES_$$_TBYTEARRAY,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TBYTEARRAY$indirect
RTTI_$VDBTYPES_$$_TBYTEARRAY$indirect:
	.long	RTTI_$VDBTYPES_$$_TBYTEARRAY

.section .rodata.n_INIT_$VDBTYPES_$$_TCOLDEF,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TCOLDEF$indirect
INIT_$VDBTYPES_$$_TCOLDEF$indirect:
	.long	INIT_$VDBTYPES_$$_TCOLDEF

.section .rodata.n_RTTI_$VDBTYPES_$$_TCOLDEF,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TCOLDEF$indirect
RTTI_$VDBTYPES_$$_TCOLDEF$indirect:
	.long	RTTI_$VDBTYPES_$$_TCOLDEF

.section .rodata.n_INIT_$VDBTYPES_$$_TFKDEF,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TFKDEF$indirect
INIT_$VDBTYPES_$$_TFKDEF$indirect:
	.long	INIT_$VDBTYPES_$$_TFKDEF

.section .rodata.n_RTTI_$VDBTYPES_$$_TFKDEF,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TFKDEF$indirect
RTTI_$VDBTYPES_$$_TFKDEF$indirect:
	.long	RTTI_$VDBTYPES_$$_TFKDEF

.section .rodata.n_RTTI_$VDBTYPES_$$_TONCONFLICTACTION,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TONCONFLICTACTION$indirect
RTTI_$VDBTYPES_$$_TONCONFLICTACTION$indirect:
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION

.section .rodata.n_RTTI_$VDBTYPES_$$_TONCONFLICTACTION_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TONCONFLICTACTION_s2o$indirect
RTTI_$VDBTYPES_$$_TONCONFLICTACTION_s2o$indirect:
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION_s2o

.section .rodata.n_RTTI_$VDBTYPES_$$_TONCONFLICTACTION_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TONCONFLICTACTION_o2s$indirect
RTTI_$VDBTYPES_$$_TONCONFLICTACTION_o2s$indirect:
	.long	RTTI_$VDBTYPES_$$_TONCONFLICTACTION_o2s

.section .rodata.n_RTTI_$VDBTYPES_$$_TINSERTORACTION,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TINSERTORACTION$indirect
RTTI_$VDBTYPES_$$_TINSERTORACTION$indirect:
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION

.section .rodata.n_RTTI_$VDBTYPES_$$_TINSERTORACTION_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TINSERTORACTION_s2o$indirect
RTTI_$VDBTYPES_$$_TINSERTORACTION_s2o$indirect:
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION_s2o

.section .rodata.n_RTTI_$VDBTYPES_$$_TINSERTORACTION_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TINSERTORACTION_o2s$indirect
RTTI_$VDBTYPES_$$_TINSERTORACTION_o2s$indirect:
	.long	RTTI_$VDBTYPES_$$_TINSERTORACTION_o2s

.section .rodata.n_INIT_$VDBTYPES_$$_TSETEXPR,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TSETEXPR$indirect
INIT_$VDBTYPES_$$_TSETEXPR$indirect:
	.long	INIT_$VDBTYPES_$$_TSETEXPR

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETEXPR,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TSETEXPR$indirect
RTTI_$VDBTYPES_$$_TSETEXPR$indirect:
	.long	RTTI_$VDBTYPES_$$_TSETEXPR

.section .rodata.n_INIT_$VDBTYPES_$$_TSETEXPRS,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TSETEXPRS$indirect
INIT_$VDBTYPES_$$_TSETEXPRS$indirect:
	.long	INIT_$VDBTYPES_$$_TSETEXPRS

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETEXPRS,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TSETEXPRS$indirect
RTTI_$VDBTYPES_$$_TSETEXPRS$indirect:
	.long	RTTI_$VDBTYPES_$$_TSETEXPRS

.section .rodata.n_INIT_$VDBTYPES_$$_TSETVALUEPAIR,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TSETVALUEPAIR$indirect
INIT_$VDBTYPES_$$_TSETVALUEPAIR$indirect:
	.long	INIT_$VDBTYPES_$$_TSETVALUEPAIR

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETVALUEPAIR,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TSETVALUEPAIR$indirect
RTTI_$VDBTYPES_$$_TSETVALUEPAIR$indirect:
	.long	RTTI_$VDBTYPES_$$_TSETVALUEPAIR

.section .rodata.n_INIT_$VDBTYPES_$$_TSETVALUEPAIRS,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TSETVALUEPAIRS$indirect
INIT_$VDBTYPES_$$_TSETVALUEPAIRS$indirect:
	.long	INIT_$VDBTYPES_$$_TSETVALUEPAIRS

.section .rodata.n_RTTI_$VDBTYPES_$$_TSETVALUEPAIRS,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TSETVALUEPAIRS$indirect
RTTI_$VDBTYPES_$$_TSETVALUEPAIRS$indirect:
	.long	RTTI_$VDBTYPES_$$_TSETVALUEPAIRS

.section .rodata.n_INIT_$VDBTYPES_$$_TWHERECOND,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TWHERECOND$indirect
INIT_$VDBTYPES_$$_TWHERECOND$indirect:
	.long	INIT_$VDBTYPES_$$_TWHERECOND

.section .rodata.n_RTTI_$VDBTYPES_$$_TWHERECOND,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TWHERECOND$indirect
RTTI_$VDBTYPES_$$_TWHERECOND$indirect:
	.long	RTTI_$VDBTYPES_$$_TWHERECOND

.section .rodata.n_INIT_$VDBTYPES_$$_TWHEREGROUP,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TWHEREGROUP$indirect
INIT_$VDBTYPES_$$_TWHEREGROUP$indirect:
	.long	INIT_$VDBTYPES_$$_TWHEREGROUP

.section .rodata.n_RTTI_$VDBTYPES_$$_TWHEREGROUP,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TWHEREGROUP$indirect
RTTI_$VDBTYPES_$$_TWHEREGROUP$indirect:
	.long	RTTI_$VDBTYPES_$$_TWHEREGROUP

.section .rodata.n_INIT_$VDBTYPES_$$_TWHEREGROUPS,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TWHEREGROUPS$indirect
INIT_$VDBTYPES_$$_TWHEREGROUPS$indirect:
	.long	INIT_$VDBTYPES_$$_TWHEREGROUPS

.section .rodata.n_RTTI_$VDBTYPES_$$_TWHEREGROUPS,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TWHEREGROUPS$indirect
RTTI_$VDBTYPES_$$_TWHEREGROUPS$indirect:
	.long	RTTI_$VDBTYPES_$$_TWHEREGROUPS

.section .rodata.n_INIT_$VDBTYPES_$$_TFKARRAY,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TFKARRAY$indirect
INIT_$VDBTYPES_$$_TFKARRAY$indirect:
	.long	INIT_$VDBTYPES_$$_TFKARRAY

.section .rodata.n_RTTI_$VDBTYPES_$$_TFKARRAY,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TFKARRAY$indirect
RTTI_$VDBTYPES_$$_TFKARRAY$indirect:
	.long	RTTI_$VDBTYPES_$$_TFKARRAY

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGEREVENT,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGEREVENT$indirect
RTTI_$VDBTYPES_$$_TTRIGGEREVENT$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGEREVENT_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGEREVENT_s2o$indirect
RTTI_$VDBTYPES_$$_TTRIGGEREVENT_s2o$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT_s2o

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGEREVENT_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGEREVENT_o2s$indirect
RTTI_$VDBTYPES_$$_TTRIGGEREVENT_o2s$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGEREVENT_o2s

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERTIMING,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERTIMING$indirect
RTTI_$VDBTYPES_$$_TTRIGGERTIMING$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERTIMING_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERTIMING_s2o$indirect
RTTI_$VDBTYPES_$$_TTRIGGERTIMING_s2o$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING_s2o

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERTIMING_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERTIMING_o2s$indirect
RTTI_$VDBTYPES_$$_TTRIGGERTIMING_o2s$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGERTIMING_o2s

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERFOREACH,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH$indirect
RTTI_$VDBTYPES_$$_TTRIGGERFOREACH$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_s2o,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_s2o$indirect
RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_s2o$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_s2o

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_o2s,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_o2s$indirect
RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_o2s$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGERFOREACH_o2s

.section .rodata.n_RTTI_$VDBTYPES_$$_def0000001E,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_def0000001E$indirect
RTTI_$VDBTYPES_$$_def0000001E$indirect:
	.long	RTTI_$VDBTYPES_$$_def0000001E

.section .rodata.n_INIT_$VDBTYPES_$$_TTRIGGERDEF,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TTRIGGERDEF$indirect
INIT_$VDBTYPES_$$_TTRIGGERDEF$indirect:
	.long	INIT_$VDBTYPES_$$_TTRIGGERDEF

.section .rodata.n_RTTI_$VDBTYPES_$$_TTRIGGERDEF,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TTRIGGERDEF$indirect
RTTI_$VDBTYPES_$$_TTRIGGERDEF$indirect:
	.long	RTTI_$VDBTYPES_$$_TTRIGGERDEF

.section .rodata.n_INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect:
	.long	INIT_$VDBTYPES_$$_TFUNCTIONPARAMETER

.section .rodata.n_RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect
RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER$indirect:
	.long	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMETER

.section .rodata.n_INIT_$VDBTYPES_$$_TFUNCTIONPARAMARRAY,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TFUNCTIONPARAMARRAY$indirect
INIT_$VDBTYPES_$$_TFUNCTIONPARAMARRAY$indirect:
	.long	INIT_$VDBTYPES_$$_TFUNCTIONPARAMARRAY

.section .rodata.n_RTTI_$VDBTYPES_$$_TFUNCTIONPARAMARRAY,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMARRAY$indirect
RTTI_$VDBTYPES_$$_TFUNCTIONPARAMARRAY$indirect:
	.long	RTTI_$VDBTYPES_$$_TFUNCTIONPARAMARRAY

.section .rodata.n_INIT_$VDBTYPES_$$_def00000022,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_def00000022$indirect
INIT_$VDBTYPES_$$_def00000022$indirect:
	.long	INIT_$VDBTYPES_$$_def00000022

.section .rodata.n_INIT_$VDBTYPES_$$_TFUNCTIONDEF,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TFUNCTIONDEF$indirect
INIT_$VDBTYPES_$$_TFUNCTIONDEF$indirect:
	.long	INIT_$VDBTYPES_$$_TFUNCTIONDEF

.section .rodata.n_RTTI_$VDBTYPES_$$_def00000022,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_def00000022$indirect
RTTI_$VDBTYPES_$$_def00000022$indirect:
	.long	RTTI_$VDBTYPES_$$_def00000022

.section .rodata.n_RTTI_$VDBTYPES_$$_TFUNCTIONDEF,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TFUNCTIONDEF$indirect
RTTI_$VDBTYPES_$$_TFUNCTIONDEF$indirect:
	.long	RTTI_$VDBTYPES_$$_TFUNCTIONDEF

.section .rodata.n_INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT,"d"
	.balign 4
.globl	INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT$indirect
INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT$indirect:
	.long	INIT_$VDBTYPES_$$_TUPDATEASSIGNMENT

.section .rodata.n_RTTI_$VDBTYPES_$$_TUPDATEASSIGNMENT,"d"
	.balign 4
.globl	RTTI_$VDBTYPES_$$_TUPDATEASSIGNMENT$indirect
RTTI_$VDBTYPES_$$_TUPDATEASSIGNMENT$indirect:
	.long	RTTI_$VDBTYPES_$$_TUPDATEASSIGNMENT
# End asmlist al_indirectglobals

