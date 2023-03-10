
;--- page handling
;--- handles physical memory, address space and un/committed memory

		.486P

		option proc:private
		option casemap:none

		include hdpmi.inc
		include external.inc

?XMSALLOCRM    = 1	;std 1, alloc 1. EMB in real mode (XMS-Mode only)
?CLEARACCBIT   = 0	;std 0, on entry clear ACC-Bit for all PTEs in 1. MB
?FREEPDIRPM    = 0	;std 0, on exit reset CR3 in protected mode (?)
?VCPIALLOC	   = 1	;std 1, alloc VCPI mem if no XMS host found
?RESPAGES	   = 4	;std 4, small reserve, do not alloc these pages
?ZEROFILL	   = 0	;std 0, 1=do zero fill all committed pages
?USEE820	   = 0	;std 0, use int 15h, ax=e820 to get extmem in raw mode
?USEE801	   = 1	;std 1, use int 15h, ax=e801 to get extmem in raw mode
?FREEVCPIPAGES = 1	;std 1, free all VCPI pages in pm_exitserver_rm
?FREEXMSINRM   = 1	;std 1, free XMS blocks in pm_exitserver_rm
?NOVCPIANDXMS  = 1	;std 1, 1=avoid using VCPI if XMS host exists
?FREEXMSDYN    = 1	;std 1, 1=free XMS blocks dynamically
?SETCOPYPTE    = 0	;std 0, 1=support set+copy PTEs
?XMSBLOCKCNT   = 1	;std 1, 1=count XMS blocks to improve alloc strategy

@seg _TEXT32
@seg _TEXT16
@seg _DATA16
@seg VDATA16
@seg CDATA16
@seg _ITEXT16
@seg SEG16

ifndef ?USEINVLPG
?USEINVLPG = 0 		;use invlpg opcode (80486+)
endif

;--- PHYSBLK: describes a block of physical memory
;--- there is always just 1 item with free pages
;--- and it is stored in PhysBlk  variable

PHYSBLK	struct
pNext	dd ?	;ptr next block
dwBase	dd ?	;base address of block
dwSize	dd ?	;size in pages
dwFree	dd ?	;pages allocated
union
dwHandle dd ?        
struct
wHandle	dw ?	;handle (XMS+DOS)
bFlags  db ?
		db ?
ends
ends
PHYSBLK	ends

;--- bFlags

PBF_XMS		equ 1	;is a XMS handle
PBF_I15		equ 2	;is a I15 block (no handle)
PBF_DOS		equ 4	;is a DOS block
PBF_TOPDOWN	equ 8	;get memory from top to bottom (i15)
PBF_LINEAR 	equ 40h	;dwBase is linear, not physical
PBF_INUSE   equ PBF_XMS or PBF_I15 or PBF_DOS


;*** Flags in paging tables

; 001=present/not present
; 002=read-write/read-only
; 004=user/system
; 008=PWT (cache write through) 586+
; 010=PCD (cache disable) 586+
; 020=accessed (read access)
; 040=dirty (write access)
; 080=reserved
; 100=reserved
; 200=available
; 400=available : is _XMSFLAG_
; 800=available	: is _VCPIFLAG_

if ?SAFEPAGETABS
?PAGETABLEATTR	= PTF_PRESENT or PTF_WRITEABLE
else
?PAGETABLEATTR	= PTF_PRESENT or PTF_WRITEABLE or PTF_USER
endif

_XMSFLAG_		= 4h	;page src xms (+i15 +dos)
_VCPIFLAG_		= 8h	;page src vcpi

?SYSTEMSPACE	= 0FF8h ;offset in page dir for system area (std FF8=0xFF800000)	
?SYSPGDIRAREA	= 2*4	;2 system page tables (sys pagetab 0+1)

; memory structure as implemented by page manager:
; - page directory is mapped at end of system area (FFBFF000)
; - page tables are mapped in linear region FFC00000-FFFFFFFF
; - page table sys area 1 (FFC00000-FFFFFFFF) is at FFC00xxx (page map table)
; - page table sys area 0 (FF800000-FFBFFFFF) is at FFC01xxx
; - page tables user space (00000000-FF7FFFFF) begin at FFC02xxx
; - variables:
; - pPageDir	= FFBFF000
; - pPageTables = FFC00000
; - pPageTab0	= FFC02000
; - pPagesStart = FFC00000

_DATA16 segment

pPageDir	 dd 0		;linear address page dir
pPageTables  dd 0		;linear address start page tables (FFC00000)
pPageTab0	 dd 0		;linear address page table 0
pPagesStart  dd 0		;linear address of 4 MB region where page tables
						;  are mapped (0 on startup, later FFC00000)
dwOfsPgTab0  dd 0		;is used to calc total address space (const!)

;--- system address space (FF800000-FFBFFFFF)
;--- the space is allocated by using 2 pointers, SysAddrSpace
;--- and SysAddrSpace2 (one upwards, the other downwards)

;--- the first is used to alloc space for code, GDT, LDT, IDT, ...
;--- the second is used to alloc space for mapped page dir
;--- + client save states

SysAddrSpace dd 0		;init: bottom of sys addr space (FF801000)
SysAddrSpace2 dd 0		;init: top of sys address space (FFC00000)
SysAddrSize  dd 0		;free pages in system region

startvdata label byte

;--- physical memory
;--- the page pool are uncommitted PTEs which are
;--- stored in the page tables. the pool is scanned from top to bottom

; client address space:
; - pMaxPageTab = FFC02440 on startup (corresponds to linear address 110000h)
; after 8 MB address space allocation vars are:
; - pMaxPageTab = FFC04440 (= linear address 910000h)


dwPagePool	dd 0		;uncommitted PTEs (XMS+I15) in page pool
pPoolMax	dd 0		;top of page pool
pMaxPageTab  dd 0		;linear address free space in page table region

PhysBlk		PHYSBLK <0>	;linked list of physical memory blocks allocated

if ?VCPIALLOC
dwVCPIPages dd 0		;count allocated VCPI pages (just as info)
endif

if ?FREEXMSINRM
pXMSHdls	dw 0		;XMS handle pointer in host stack (exit server)
endif
if ?FREEVCPIPAGES
pVCPIPages	dw 0		;VCPI pages in host stack (exit server)
endif
if ?FREEPDIRPM
orgcr3		dd 0		;original cr3
cr3flgs	 	dw 0		;save bits 0-11 of CR3 phys entry here
endif
if ?XMSBLOCKCNT
bXMSBlocks	db 0
endif
		align 4
endvdata	label byte

_DATA16 ends

CDATA16	segment
dwResI15Pgs  dd 0		;free pages for int 15h
CDATA16	ends

_TEXT32  segment

		assume DS:GROUP16

;*** get ptr to PTE of a linear address
;*** in: linear address in EAX
;*** out: EDI=linear address of PTE for address in EAX
;*** C if address space isn't allocated (no page table exists)
;--- other registers preserved

		@ResetTrace

_Linear2PT proc public uses ecx

		@DebugBreak 0
		push eax
		mov edi,ss:[pPageTables]
		mov ecx,(?SYSTEMSPACE+4) * 100000h 	 ;sys area 1?
		cmp eax,ecx
		jnc @F
		add edi,1000h
		mov ecx,(?SYSTEMSPACE+0) * 100000h 	 ;sys area 0?
		cmp eax,ecx
		jnc @F
		add edi,1000h
		xor ecx,ecx
@@:
		sub eax,ecx
		shr eax,10				;ergibt offset in page tab
		and al,0FCh
		add edi,eax
;------------------------------- pMaxPageTab may be NULL (all allocated)
		mov ecx,ss:[pMaxPageTab]
		jecxz @F
		cmp ss:[pMaxPageTab],edi
@@:
		pop eax
		@strout <"#pm: lin addr %lX - addr PTE %lX, max addr PTE %lX",lf>,eax,edi,ss:[pMaxPageTab]
		ret
		align 4
_Linear2PT endp

;--- get linear address from a PTE address
;--- in: eax = linear address where PTE is stored
;--- out: eax = linear address
;--- modifies ecx

PT2Linear proc
		sub eax, ss:[pPageTables]
		jc exit
		mov ecx, 1000h
		cmp eax, ecx
		jc sysarea1
		sub eax, ecx
		cmp eax, ecx
		jc sysarea2
		sub eax, ecx
		shl eax, 10
		ret
sysarea1:
		shl eax, 10
		add eax, (?SYSTEMSPACE+4) * 100000h
		ret
sysarea2:
		shl eax, 10
		add eax, (?SYSTEMSPACE+0) * 100000h
exit:
		ret
		align 4
PT2Linear endp

;*** search physical address region in page tables
;*** called by _searchphysregion
;*** ESI = ^ page table
;*** EDX = physical address to search
;*** EDI = length of region in pages
;*** ECX = entries in page table(s)
;*** DS = FLAT
;*** Out: NC + EAX=linaddr

		@ResetTrace

checkpt proc

		cld
		@strout <"#pm: checking table at lin %lX",lf>,esi
nextentry:
		cmp ecx,edi
		jb error
		lodsd
		and ax,0F000h or PTF_PRESENT or PTF_USER
		cmp eax,edx
		jz checkpt_2
checkpt_11:
		loopd nextentry
error:
		stc
		ret

;--- first page tab entry is ok, check the rest
        
checkpt_2:
		pushad
nextitem:
		dec edi
		jz found
		lodsd
		and ax,0F000h or PTF_PRESENT or PTF_USER
		add edx,1000h
		cmp eax,edx
		loopzd nextitem
		popad
		jmp checkpt_11	;continue search
found:
		popad
		lea eax, [esi-4];adjust esi so it points to 1. entry again
		call PT2Linear
		@strout <"#pm: mapping found for real addr %lX=%lX",lf>,edx,eax
		clc
		ret
		align 4
checkpt endp

;--- search a region of physical pages in linear address space
;--- edx=physical address start
;--- eax=size in pages
;--- out: NC: found, eax=linear address
;--- else C, all preserved

_searchphysregion proc public uses ds
		pushad
		@strout <"#pm: phys2lin: addr=%lX,pages=%lX",lf>,edx,eax

		mov edi,eax 			;search in spaces already mapped
		push byte ptr _FLATSEL_
		pop ds
		and dh,0F0h
		mov dl,PTF_PRESENT or PTF_USER

;------- get number of pages allocated so far in ECX

		mov esi,ss:[pPageTables]
		mov ecx,ss:[pMaxPageTab]
		sub ecx, esi
		shr ecx, 2
		call checkpt
		jc error
		mov [esp.PUSHADS.rEAX],eax
error:
		popad
		ret
		align 4
_searchphysregion endp

;*** helper for DPMI function 0800h
;*** map a physical address region into linear address space
;*** INP: EDX=physical address region start
;***	  ECX=length of region in pages
;***	  EAX=linear address space to map the region to
;***      BL=1 -> set PTF_PWT bit in PTEs

		@ResetTrace

_mapphysregion proc public uses es

		pushad

		@strout <"#pm, mapphysregion: addr=%lX,size=%lX",lf>,edx,ecx

		push byte ptr _FLATSEL_
		pop es
		call _Linear2PT			;set EDI (ptr to PTE)
		@strout <"#pm: adspace allocated, ^pagetab=%lX, addr=%lX",lf>,edi,eax
		mov eax,edx
		or al, PTF_PRESENT or PTF_WRITEABLE or PTF_USER
		test bl,1
		jz @F
		or al, PTF_PWT or PTF_PCD	;set 'write through' + 'cache disable'
@@:
		stosd
		add eax,1000h
		loopd @B
		popad
		ret
		align 4

_mapphysregion endp

;--- physical memory

;*** get free dos pages

		@ResetTrace

getavaildospages proc

		push ebx
		or  ebx,-1
		mov ah,48h
		call rmdosintern	;get free paragraphs in BX
		movzx eax,bx
		shr eax,8		;paras to pages (10h -> 1000h)
		sub eax,1		;one less???
		jnc @F
		xor eax,eax
@@:
		pop ebx
		ret
		align 4

getavaildospages endp

;*** get free VCPI pages in EDX

if ?VCPIALLOC
getavailvcpipages proc

		xor edx,edx
		test [fHost],FH_VCPI
		jz exit
if ?NOVCPIANDXMS
		test fHost, FH_XMS
		jnz exit
endif
		mov ax,0DE03h			 ;get number of free pages (EDX)
		call [vcpicall]
exit:
		ret
		align 4
getavailvcpipages endp
endif

;*** get free XMS pages in EAX
;*** modifies EDX

getavailxmspages proc uses ebx

		test fHost, FH_XMS
		jz error
		push ecx
		mov ah, fXMSQuery
		mov bl,0
		@pushproc callxms
		call dormprocintern
		pop ecx

;--- get largest free block in E/AX
;--- get total free in E/DX
;--- it is returned even if the call ah=88h "fails" (BL=A0)

		cmp bl,0
		jz @F
		cmp bl,0A0h				;status "all memory allocated"?
		jnz error
@@:
		mov eax,edx
		test [fHost],FH_XMS30	;xms driver 3.0+?
		jnz @F
		movzx eax,ax
@@:
		shr eax,2				;kbytes -> pages
		ret
error:
		xor eax,eax
		ret
		align 4
getavailxmspages endp

;*** get number of physical pages
;*** out: eax=free pages, edx=total pages, ecx=reserved for address space

		@ResetTrace

_GetNumPhysPages proc public

		assume ds:GROUP16

		@strout <"#pm, GetNumPhysPages: free pages in cur block=%lX",lf>, PhysBlk.dwFree
		call getavailxmspages	;get free XMS pages in EAX
		@strout <"#pm, GetNumPhysPages: XMS pages=%lX",lf>,eax
		add eax,PhysBlk.dwFree	;add free pages cur block (XMS or I15)
if ?VCPIALLOC
		and eax, eax			;is XMS memory available?
		jnz @F
		call getavailvcpipages	;get VCPI pages
		@strout <"#pm, GetNumPhysPages: VCPI pages=%lX",lf>, edx
        mov eax, edx
@@:
endif
		test [bEnvFlags],ENVF_INCLDOSMEM
		jz @F
		push eax
		@strout <"#pm, GetNumPhysPages: calling getavaildospages",lf>
		call getavaildospages
		@strout <"#pm, GetNumPhysPages: DOS pages=%X",lf>,ax
		pop ecx
		add eax,ecx
@@:
		mov ecx,eax 			;some pages will be needed for paging
		shr ecx,10				;(1 page for 4MB address space)
if ?RESPAGES        
		add ecx, ?RESPAGES
endif
		@strout <"#pm, GetNumPhysPages: subtract %lX pages for pagetables",lf>,ecx
		cmp ecx,eax
		jc @F
		mov ecx,eax
@@:
		mov edx, eax
		add eax, dwPagePool		;the pagepool are "allocated" pages		

;--- total physical pages are
;---   "true" free pages
;--- + allocated pages in PHYSBLK blocks
;--- + dwVCPIPages

  if ?VCPIALLOC
		add edx, dwVCPIPages
  endif
		push ecx
		mov ecx, offset PhysBlk
nextitem:
		test [ecx].PHYSBLK.bFlags, PBF_INUSE
		jz @F
		add edx, [ecx].PHYSBLK.dwSize
		sub edx, [ecx].PHYSBLK.dwFree	;free pages are in EAX already
@@:
		@strout <"#pm, GetNumPhysPages: block total=%lX, free=%lX",lf>,[ecx].PHYSBLK.dwSize, [ecx].PHYSBLK.dwFree
		mov ecx, [ecx].PHYSBLK.pNext
		and ecx, ecx
		jnz nextitem
		pop ecx
if 0
		test [bEnvFlags],ENVF_NOXMS30	;restrict free mem to 63 MB?
		jz norestrict
		cmp eax, 4000h-1h
		jb @F
		mov eax, 4000h-1h
@@:
		cmp edx, 4000h-1h
		jb @F
		mov edx, 4000h-1h
@@:
norestrict:
endif
		@strout <"#pm, GetNumPhysPages: total=%lX, free=%lX, res=%lX",lf>,edx,eax,ecx
		ret
		align 4
_GetNumPhysPages endp

;*** get physical address of a linear address in 1. MB
;*** inp: eax=linear address
;--- no check done

linear2phys proc uses es
		shr eax,10
		add eax,[pPageTab0]
		push byte ptr _FLATSEL_
		pop es
		mov eax,es:[eax]
		ret
		align 4
linear2phys endp

;--- get a page from the current memory block
;--- this block may come from XMS, I15 or DOS

		@ResetTrace

getblockpage proc
		cmp PhysBlk.dwFree, 0
		jz error
		dec PhysBlk.dwFree
		mov eax, PhysBlk.dwBase
		push ecx
		test PhysBlk.bFlags, PBF_TOPDOWN
		jnz topdown
		mov ecx, PhysBlk.dwSize
		sub ecx, PhysBlk.dwFree	;ecx = pages allocated
		dec ecx
		shl ecx, 12
		add eax, ecx
		pop ecx
		test PhysBlk.bFlags, PBF_LINEAR
		jz @F
		call linear2phys
@@:
if _LTRACE_
		push ecx
		mov ecx, PhysBlk.dwSize
		shl ecx, 12
		add ecx, PhysBlk.dwBase
		dec ecx
		@strout <"#pm: page %lX from cur block %lX-%lX, free=%lX",lf>, eax, PhysBlk.dwBase, ecx, PhysBlk.dwFree
		pop ecx
endif
;		 @waitesckey
		or ax,PTF_NORMAL+(_XMSFLAG_*100h)	  ;set user,read-write
		ret
topdown:
		mov ecx, PhysBlk.dwFree
		shl ecx, 12
		add eax, ecx
		pop ecx
		jmp @B
error:
		stc
		ret
		align 4
getblockpage endp

		@ResetTrace

allocphyshandle proc uses edx
		mov eax, offset PhysBlk
		jmp skipitem
nextitem:
		and eax, eax
		jz notfound
		test [eax].PHYSBLK.bFlags, PBF_INUSE
		jz found
skipitem:
		mov edx, eax
		mov eax, [edx].PHYSBLK.pNext
		jmp nextitem
found:
		push [eax].PHYSBLK.pNext
		pop [edx].PHYSBLK.pNext
		xor edx, edx
		mov [eax].PHYSBLK.pNext, edx
		ret
notfound:
		mov eax,sizeof PHYSBLK
		call _heapalloc					;this call cannot fail now
		ret
		align 4
allocphyshandle endp

setactivephyshandle proc
		mov edx, offset PhysBlk
@@:
		test [edx].PHYSBLK.bFlags, PBF_INUSE
		jnz found
		mov edx, [edx].PHYSBLK.pNext
		and edx, edx
		jnz @b
		stc
		ret
found:
		cmp edx, offset PhysBlk
		jz done
		mov eax, [edx].PHYSBLK.dwBase
		mov ecx, [edx].PHYSBLK.dwSize
		xchg eax, PhysBlk.dwBase
		xchg ecx, PhysBlk.dwSize
		mov [edx].PHYSBLK.dwBase, eax
		mov [edx].PHYSBLK.dwSize, ecx
		mov eax, [edx].PHYSBLK.dwFree
		mov ecx, [edx].PHYSBLK.dwHandle
		xchg eax, PhysBlk.dwFree
		xchg ecx, PhysBlk.dwHandle
		mov [edx].PHYSBLK.dwFree, eax
		mov [edx].PHYSBLK.dwHandle, ecx
done:
		ret
		align 4
setactivephyshandle endp

if ?FREEXMSDYN

;--- free phys handle in EAX
;--- DS=GROUP16, ES=FLAT?

		@ResetTrace

freephyshandle proc
		pushad
		mov ecx, offset PhysBlk
nextitem:
		cmp eax, ecx
		jz found
		mov ecx, [ecx].PHYSBLK.pNext
		and ecx, ecx
		jnz nextitem
		stc
		popad
		ret
found:
		@strout <"#pm: phys handle %lX found, pNext=%lX, hdl=%lX, start=%X",lf>, eax, [eax].PHYSBLK.pNext, [eax].PHYSBLK.dwHandle, offset PhysBlk
@@:
		mov dl, [eax].PHYSBLK.bFlags
		mov [eax].PHYSBLK.bFlags, 0
		test dl, PBF_XMS
		jz @F
		mov dx,[eax].PHYSBLK.wHandle
		@strout <"#pm: calling XMS host to free handle=%X",lf>, dx
		@pushproc freexms
		call dormprocintern
if ?XMSBLOCKCNT
		dec [bXMSBlocks]
endif
		jmp done
@@:
		test dl, PBF_DOS
		jz @F
if 0
		mov cx, [eax].PHYSBLK.wHandle
		mov v86iret.rES,cx
		mov ah,49h
		call rmdosintern
else
		push eax
		mov ah,51h
		call rmdosintern	;get PSP in BX
		pop eax
		movzx ecx, [eax].PHYSBLK.wHandle
		dec ecx
		shl ecx, 4
		mov word ptr es:[ecx+1], bx
endif
@@:
done:
		clc
		popad
		ret
		align 4
freephyshandle endp

endif

		@ResetTrace

;--- alloc new phys block and set values
;--- edx == base
;--- eax == size

setphyshandle proc        

;		@strout <"#pm: XMS/DOS memory allocated, addr=%lX, size=%lX",lf>,edx,eax

									;set values so _heapalloc cannot fail
		xchg edx,PhysBlk.dwBase	;save current physical address
		push edx
		push PhysBlk.dwSize
		mov PhysBlk.dwSize,eax	;save current size in pages
		xchg eax, PhysBlk.dwFree
		push eax
		push PhysBlk.dwHandle

		call allocphyshandle
		mov edx, PhysBlk.pNext
		mov [eax].PHYSBLK.pNext, edx
		mov PhysBlk.pNext, eax
		pop [eax].PHYSBLK.dwHandle
		pop [eax].PHYSBLK.dwFree
		pop [eax].PHYSBLK.dwSize
		pop [eax].PHYSBLK.dwBase
		@strout <"#pm: new phys mem obj %lX, base=%lX, size=%lX, free=%lX",lf>,eax,[eax].PHYSBLK.dwBase, [eax].PHYSBLK.dwSize, [eax].PHYSBLK.dwFree
		@strout <"#pm: current: base=%lX, size=%lX, free=%lX",lf>, PhysBlk.dwBase, PhysBlk.dwSize, PhysBlk.dwFree
		ret
		align 4
setphyshandle endp

;*** get pages from XMS
;*** inp ECX: requested size in pages
;*** DS=GROUP16
;--- modifies ebx, eax, edx? 

		@ResetTrace

		assume ds:GROUP16

getxmspage proc near

		test fHost,FH_XMS		;XMS host present?
		jz getxmspage_err

		@strout <"#pm: try to alloc XMS mem (real mode), ecx=%lX",lf>,ecx
		call getavailxmspages
		cmp eax, 1
		jc getxmspage_err		;XMS is out of memory
		call getbestxmssize		;return best size
		push ecx
		mov ecx,eax
		@pushproc allocxms
		call dormprocintern
		pop ecx
		jc getxmspage_err		;XMS is out of memory
		call setphyshandle
		mov PhysBlk.wHandle, bx
		mov PhysBlk.bFlags, PBF_XMS
if ?XMSBLOCKCNT
		inc [bXMSBlocks]
endif
		jmp getblockpage
getxmspage_err:
		@strout <"#pm: getxmspage memory alloc failed, ax=%X",lf>,ax
		stc
		ret
		align 4
getxmspage endp

;*** allocate DOS memory to satisfy requests, ecx=pages
;--- modifies ebx, edx, eax

		@ResetTrace

getdospage proc

		assume ds:GROUP16

		test [bEnvFlags],ENVF_INCLDOSMEM
		jz error

		cmp ecx,100h-1		  ;255 or more pages request (1 MB - 4 kB)?
		jnc error			  ;is an error in any case
		test PhysBlk.bFlags, PBF_DOS
		jz newdosblock

		mov ax, PhysBlk.wHandle
		mov ebx,PhysBlk.dwSize
		mov [v86iret.rES],ax
		neg al
		movzx eax, al
		shl ebx,8				;pages -> paragraphs
		add ebx, eax

		mov dh,cl				;angeforderte pages (1 Page -> 100h Paras)
		mov dl,00
		movzx edx,dx
		lea edx,[edx+ebx]
		test edx,0FFFF0000h
		jnz newdosblock
		push ebx
		mov ebx,edx
		@strout <"#pm: try to enlarge DOS block %X to %X paras",lf>,v86iret.rES,bx
		mov ah,4Ah
		call rmdosintern
		pop ebx
		jc @F
		@strout <"#pm: DOS block enlarged",lf>
		add PhysBlk.dwSize,ecx
		mov PhysBlk.dwFree,ecx
		call setowner
		jmp getblockpage
@@:
		@strout <"#pm: DOS block enlarge failed",lf>
		mov ah,4Ah				;due to a bug in most DOSes the block
		call rmdosintern		;has to be resized to its previous size
		call setowner
newdosblock:
		mov bh,cl				;nur angeforderte pages
		inc bh					;1 mehr, da beginn nicht an pagegrenze
		mov bl,00
		@strout <"#pm: try to alloc a new DOS block, size=%X",lf>,bx
		mov ah,48h
		call rmdosintern
		jc error2
		@strout <"#pm: new DOS block allocated, addr=%X, size=%X",lf>,ax,bx
		mov bx,ax		;handle
		movzx edx,ax
		shl edx,4
		add edx,1000h-1
		and dx, 0F000h
		movzx eax,cl
		call setphyshandle
		mov PhysBlk.wHandle, bx
		mov PhysBlk.bFlags, PBF_DOS or PBF_LINEAR
		call setowner
		jmp getblockpage
error2:
		@strout <"#pm: alloc new dos block failed",lf>
error:
		stc
		ret
setowner:
		push es
		push byte ptr _FLATSEL_
		pop es
		movzx edx,PhysBlk.wHandle
		dec edx
		shl edx,4
		mov ax,wHostPSP
		mov es:[edx+1],ax
		pop es
		retn
		align 4
getdospage endp

;*** scan page pool for a free page
;*** is called only if there is at least 1 item in pool
;*** the page pool are released pages in the page tables
;*** (when a page is released just the present bit is cleared)

		@ResetTrace

scanpagepool proc uses es esi ecx

		push byte ptr _FLATSEL_
		pop es

		mov esi,pPoolMax
		mov ecx,pPageTables

		@strout <"#pm, scanpagepool: %lX-%lX, pages=%lX",lf>, ecx, esi, dwPagePool

;		@SetTrace
if _LTRACE_
		and esi, esi
		jnz @F
		@strout <"#pm, scanpagepool: pPoolMax is NULL!, dwPagePool=%lX",lf>, dwPagePool
		@waitesckey
@@:
endif

nextitem:
		sub esi,4
		cmp esi, ecx
		jb notfound
		mov eax,es:[esi]
		test al, PTF_PRESENT
		jnz nextitem
		test ah, _XMSFLAG_
		jz nextitem
		mov dword ptr es:[esi],PTF_NORMAL  ;clear PTE here
		mov pPoolMax, esi
exit:
		ret
notfound:
		@strout <"#pm, scanpagepool error: no page in page pool found",lf>
		stc
		jmp exit
		align 4
scanpagepool endp

;*** get a phys. page
;*** inp: 
;*** EAX = page entry value
;*** ECX = number of pages which will be requested (hint for XMS)
;*** DS=GROUP16
;*** out: new value in EAX, inclusive flags (XMS/VCPI)
;*** physical page can come from following sources:
;*** - PTE at current location (page is committed!)
;*** - PTE at current location (previously committed page)
;*** - PTE from page pool (uncommitted page somewhere in address space)
;*** - XMS page from current XMS handle
;*** - XMS page from a new XMS handle
;*** - VCPI page
;*** modifies: ebx, eax, edx

		@ResetTrace

getphyspagex proc

		assume ds:GROUP16

		test al,PTF_PRESENT	;is page committed?
		jnz exit			;then we're done
		test ah,_XMSFLAG_	;is this a page from page pool?
		jz getphyspage		;if no, alloc a new page
		dec [dwPagePool]
		@strout <"#pm: page pool decr [%lX], Entry=%lX, edi=%lX, caller=%lX",lf>, dwPagePool, eax, edi, <dword ptr [esp]>
exit:
		ret
		align 4
getphyspagex endp

		@ResetTrace

getphyspage proc

		cmp [dwPagePool],0		;free pages in page tables to be found?
		jz @F
		call scanpagepool
		jc @F
		dec [dwPagePool]
		@strout <"#pm: page pool decremented [%lX], Entry=%lX",lf>,\
			[dwPagePool], eax
		ret
@@:

		@ResetTrace

		call getblockpage		;get page from current phys mem block
		jnc exit
		@strout <"#pm: get page thru XMS",lf>
		call getxmspage
		jnc exit
if ?VCPIALLOC
		test [fHost],FH_VCPI
		jz novcpimem
if ?NOVCPIANDXMS
		test [fHost],FH_XMS	;using VCPI when XMS exists but fails
		jnz novcpimem		;seems to be unstable for many VCPI hosts
endif
		@strout <"#pm: try VCPI alloc",lf>

		@ResetTrace

		mov ax,0DE04h			   ;1 page alloc VCPI
		call [vcpicall]
		and ah,ah				   ;ok?
		jnz @F
		inc [dwVCPIPages]
		@strout <"#pm: page %lX allocated thru VCPI, total=%lX",lf>, edx, dwVCPIPages
;		 @waitesckey
		mov eax,edx
		and ax,0F000h
		or ax,PTF_NORMAL + (_VCPIFLAG_*100h)
		ret
@@:
		@strout <"#pm: VCPI alloc failed, ax=%X",lf>, ax

		@ResetTrace

novcpimem:
endif
		call getdospage
exit:
		@strout <"#pm, exit getphyspage, eax=%lX",lf>, eax
;		 @waitesckey
		ret
		align 4
getphyspage endp

;*** free PTE in eax
;*** DS=GROUP16
;*** returns modified PTE in EAX
;--- other registers preserved

		@ResetTrace

freephyspage proc

		test al,PTF_PRESENT		;committed?
		jz exit				;if not, do nothing	   
		test ah,_XMSFLAG_		;is it from XMS/I15/DOS?
		jz noxmspage	        ;no (VCPI or mapped)
		inc [dwPagePool]		;XMS/I15/DOS will be put in page pool
		and al, not PTF_PRESENT
		@strout <"#pm: Page Pool incremented [%lX], Entry=%lX, caller=%lX",lf>,[dwPagePool],eax,<dword ptr [esp]>
exit:
		ret
		align 4
noxmspage:
if ?VCPIALLOC
		test ah,_VCPIFLAG_		   ;is it a vcpi page? 
		jz novcpipage

		@ResetTrace

		pushad
		mov edx,eax
		and dx,0F000h			   ;nur VCPI pages sofort  zurueckgeben
		mov ax,0DE05h			   ;1 page free VCPI
		call [vcpicall]
		and ah,ah				   ;ok?
		jnz @F
		dec [dwVCPIPages]
@@:
		@strout <"#pm: free VCPI page %lX returned ax=%X, remaining %lX",lf>, edx, ax, dwVCPIPages
		popad
novcpipage:
endif
		xor eax, eax			   ;return 0 (value of new page entry 
		ret
		align 4
freephyspage endp

;*** adress space handling

;*** mapPageTable: used to map a page table
;*** all page tables are mapped into linear address space FFC00000-FFFFFFFF
;*** after being mapped, the page table is cleared to zero
;*** IN: EAX=PTE for page table (will be stored in page map table)
;*** IN: ESI=offset in page map table [FFC00000] to store PTE)
;*** IN: ES=flat
;*** variables needed: pPageTables, pPagesStart
;*** out: NC if successful, EDI = linear address of page (FFC00000-FFFFF000)
;*** modifies EDI, EDX
;--- error cannot happen, this case is checked before the call

		@ResetTrace

mapPageTable proc near

		push ecx
		mov edi,esi 			;now edi is offset to free area
		mov edx,[pPageTables]	;linear address of page table area
		mov es:[edi+edx],eax	;set new page table in mapping page

if _LTRACE_
		lea edx, [edi+edx]
		@strout <"#pm, mapPageTable: written %lX to %lX",lf>, eax, edx
endif

;--- now clear new page table

		shl edi,10			;* 1024
		add edi,[pPagesStart]

		@strout <"#pm, mapPageTable: phys entry %lX mapped at %lX",lf>, eax, edi


		push edi
		push eax
		mov ecx,1000h/4			 ;clear the new page table
		xor eax,eax
		rep stosd

		pop eax
		pop edi
		pop ecx
		clc
		ret
		align 4

mapPageTable endp


;--- return free address space in eax (pages)
;--- total address space in edx (pages)
;--- called by int 31h, ax=0500h
;--- ds=GROUP16

_getaddrspace proc public
		xor edx,edx 			   ;  00000000h
		sub edx,[pPageTab0]
		sub edx,[dwOfsPgTab0]
		shr edx,2

		xor eax,eax
		sub eax,[pMaxPageTab]
		shr eax,2
		ret
		align 4
_getaddrspace endp

;--- if a page table is totally clear (4 MB)
;--- free physical memory (PTE in mapping page table) + reset to zero
;--- + clear PDE in page dir
;--- EDX=linear address of page tab
;--- BL=1 -> free entry in page map table

		@ResetTrace

freepagetab proc

		pushad

		mov esi,[pPageTables]	;linear address page tables
		mov edi, pPageDir

		cmp edx, pPoolMax		;is page used by pool?
		setnc al
		and bl,al

		sub edx,[pPageTab0]
		shr edx, 10 			;convert it to offset in page table

		xor eax, eax			;simply clear PDE in page dir
								;no need to free it, it is a double
		mov es:[edi+edx],eax


		cmp bl,1				;can page table freed in mapping area?
		jnz @F

		lea edi, [esi+edx+?SYSPGDIRAREA]

		mov eax,es:[edi]		;and free PTE in mapping pagetab
if _LTRACE_
		mov ecx, edx
		add ecx, ?SYSPGDIRAREA
		shl ecx, 10
		add ecx, pPageTables
		shl edx, 20
		@strout <"#pm, freepagetab: rel. PTE %lX at %lX [reg %lX, mapped %lX",lf>, eax, edi, edx, ecx
endif
		call freephyspage
		stosd
		cmp edi, pPoolMax
		jc @F
		mov pPoolMax, edi
@@:
		popad
		ret
		align 4

freepagetab endp

;--- free user address space
;--- IN: eax = linear address
;--- IN: ecx = pages
;--- ES=FLAT
;--- free entries in page directory and entries in page tables

		@ResetTrace

FreeUserAddrSpace proc

		pushad
		@strout <"#pm, FreeUserAddrSpace: free space at %lX, %lX pages",lf>, eax, ecx
		@strout <"#pm, FreeUserAddrSpace: pMaxPageTab=%lX pPoolMax=%lX",lf>, pMaxPageTab, pPoolMax
		mov edi, eax
		shr edi, 10 			;400000h -> 1000h, 800000 -> 2000
		add edi, [pPageTab0]

		xor ebp, ebp
		lea edx, [edi+ecx*4]
		cmp edx, pMaxPageTab	;is it the "last" space?
		jnz @F
		mov pMaxPageTab, edi
		inc ebp
@@:

		xor eax, eax
		xor edx, edx			;count entries in page table
		xor ebx, ebx
if _LTRACE_
		xor esi, esi
endif
;----------------------------------- clear entries in page table
		jecxz exit
nextpage:
		test di, 0FFFh
		jnz @F
		cmp dx, 400h			;all pages in pagetab
		jnz noclear
if _LTRACE_
		inc esi
endif
		cmp edx, ebx			;were all pages released?
		setz bl
		lea edx, [edi-1000h]
		call freepagetab
noclear:
		xor edx,edx
		xor ebx,ebx
@@:
								;this is always uncommitted memory
		mov eax,es:[edi]
		test ah,_XMSFLAG_		;but is a page pool page assigned?
		jnz @F
		mov dword ptr es:[edi],0
		inc ebx
@@:
		add edi, 4
		inc edx
		dec ecx
		jnz nextpage

		and ebp, ebp			;was it at the end?
		jz @F
		mov eax, edi
		and ax, 0F000h
		sub edi, eax
		shr edi, 2				;PTEs in last page table
		@strout <"#pm, FreeUserAddrSpace: last page table entries: %lX %X %X",lf>, edi, dx, bx
		cmp edi, edx
		jnz @F
		cmp edx, ebx
		setz bl
		mov edx, eax
		call freepagetab
@@:
		@strout <"#pm, FreeUserAddrSpace: %X pages for page tables freed",lf>, si
exit:
		popad
		ret
		align 4
FreeUserAddrSpace endp

;*** allocate user address space
;*** in: ECX=pages, DS=GROUP16, ES=FLAT
;*** out: NC if successful, EAX=linear address
;*** C on error
;*** modifies EDI, ESI, EBX, EDX
;*** updates: pMaxPageTab
;--- 4 GB are 1.0000.0000/1000 == 100000 pages
;--- example (pMaxPageTab = FFC20440h):
;--- NEG(pMaxPageTab) = 3DFBC0h, SHR 2 = F7EF0h pages == F7EF0000h bytes

		@ResetTrace

AllocUserAddrSpace proc near

		assume ds:GROUP16

		@strout <"#pm, AllocUserAddrSpace: alloc %lX pages",lf>,ecx
		mov edi,[pMaxPageTab]	;top used address space (may be 0!)
;		and edi, edi
;		jz error
;		cmp ecx,100000h
;		jnc error
;		lea eax, [ecx*4+edi]
;		cmp eax, edi			;overflow?
;		jc error				;then insufficient free address space
		mov eax, edi
		neg eax
		shr eax, 2				;remaining free pages
		cmp ecx, eax
		ja error

		push ecx
		push edi
		cld
nextpage:
		test di,0FFFh			;start of a new page table?
		jz newpagetab
donenewpagetab:
		mov eax,es:[edi]
		mov al,PTF_NORMAL
;		 @strout <"#pm, AllocUserAddrSpace: mem page at %lX",lf>,edi
		stosd							;save PTE in page table
		dec ecx
		jnz nextpage
		mov [pMaxPageTab],edi
		pop edx
		pop ecx
										;page tables are stored so that
										;it is very simple to get linear
										;address from pointer to PTE
		@strout <"#pm, AllocUserAddrSpace: : edx=%lX, pPageTab0=%lX",lf>,edx,pPageTab0
		sub edx,[pPageTab0]
		shl edx,10					;* 1024 -> jetzt in edx die lin addr
		mov eax, edx
		@strout <"#pm, AllocUserAddrSpace: new addrspace generated: addr=%lX,size=%lX",lf>,eax,ecx
		clc
		ret
newpagetab:
		mov esi,edi
		sub esi,pPageTables
		shr esi,10					;1000h -> 004, 2000h -> 8
		mov edx,[pPageTables]
		mov eax,es:[esi+edx]		;get current PTE
		test al,PTF_PRESENT
		jnz @F

;--- set ECX (is a parameter for XMS mem alloc)

		push ecx
		mov ecx,[esp+8]				; address space pages
		shr ecx,10					; 1024 pages -> 1 page table
		inc ecx
		call getphyspagex			;get a page for new page table
		pop ecx

		jc error2
		or al,?PAGETABLEATTR
		call mapPageTable			;and map page table in sys region 1
@@:
		mov ebx, pPageDir			;get pointer to current PDE
		mov es:[ebx+esi-?SYSPGDIRAREA],eax	;set PDE in page dir
		jmp donenewpagetab
error2:
		pop edi 					;get pMaxPageTab
		mov eax, ecx
		mov ecx,[esp]				;total size in pages
		@strout <"#pm, AllocUserAddrSpace: alloc %lX pages failed at %lX",lf>, ecx, eax
		sub ecx, eax				;subtract pages not allocated so far
		mov eax, edi
		sub eax,[pPageTab0]
		shl eax,10
		invoke FreeUserAddrSpace
		pop ecx
error:
		stc
		ret
		align 4

AllocUserAddrSpace endp



;-------------------------------------------------------

;*** get user address space
;*** RC: C on errors
;*** Inp: EAX num pages
;*** out: EAX=linear address, EDX = pages
;--- DS=GROUP16

_AllocUserSpace proc public

		push es
		pushad
		push byte ptr _FLATSEL_
		pop es
		mov ecx, eax
		call AllocUserAddrSpace
		jc @F
		mov [esp].PUSHADS.rEAX, eax
		mov [esp].PUSHADS.rEDX, ecx
@@:
		popad
		pop es
		ret
		align 4
_AllocUserSpace endp

;*** Inp: ECX num pages
;*** Inp: EAX linear address

_FreeUserSpace proc public

		push es
		pushad
		push byte ptr _FLATSEL_
		pop es
		call FreeUserAddrSpace
		popad
		pop es
		ret
		align 4
_FreeUserSpace endp

		@ResetTrace

_CommitRegion proc near public
		mov dl,PTF_PRESENT or PTF_WRITEABLE or PTF_USER
_CommitRegion endp	;fall throu

;*** commit a region
;--- INP: EAX=linear addr, ECX=size in pages, DL=page flags
;--- modifies ES (=FLAT)

commitblockx proc near
		pushad
		push byte ptr _FLATSEL_
		pop es
		call _Linear2PT
		jc error
		@strout <"#pm, CommitBlock: alloc %lX pages at %lX, ptr PTE=%lX",lf>,ecx,eax,edi
nextpage:						;<---- commit next page
		mov eax,es:[edi]
		push edx
		call getphyspagex	;expects in ECX a hint for XMS block size
		pop edx
		jc error
if _LTRACE_
		test cx,0FFFh
		jnz @F
		@strout <"#pm, CommitBlock: commit page %lX at %X:%lX, remaining %lX",lf>,eax,es,edi, ecx
@@:
endif
;		and al,098h 		;reset DIRTY, ACCESSED, SYS, WRIT, PRES
		and al,not (PTF_DIRTY or PTF_ACCESSED or PTF_USER or PTF_WRITEABLE or PTF_PRESENT)
		or al,dl
		stosd
		dec ecx
		jnz nextpage
		clc
exit:
		popad
		ret
error:
		@strout <"#pm, CommitBlock: alloc failed, remaining %lX pages, pPoolMax=%lX",lf>,ecx, ss:pPoolMax
		mov eax, ecx
		mov ecx, [esp].PUSHADS.rECX
		sub ecx, eax
		jecxz error_done
		cmp edi, ss:pPoolMax
		jc @F
		mov ss:pPoolMax,edi
@@:
		sub edi,4
		mov eax,es:[edi]
		call freephyspage
		mov es:[edi], eax
		loopd @B
error_done:
		@strout <"#pm, CommitBlock: alloc failed, pPoolMax=%lX",lf>,ss:pPoolMax
		stc
		jmp exit
		align 4
commitblockx endp

;*** uncommit memory region
;*** EAX=linear address, ECX=size in pages
;--- eax, ecx, edx modified

_UncommitRegion proc public
		jecxz exit
		mov edx, eax			;save linear address begin
		push es
		push byte ptr _FLATSEL_
		pop es
		@strout <"#pm, UncommitRegion: free %lX pages at %lX, pPoolMax=%lX",lf>,ecx,eax,ss:pPoolMax
		call _Linear2PT
		push ebx
		push ecx
		mov ebx,ss:pPoolMax
nextpage:
		mov eax,es:[edi]
		call freephyspage
		test ah,_XMSFLAG_
		stosd
		jz @F
		mov ebx, edi
@@:
		loopd nextpage
		cmp ebx, ss:pPoolMax
		jc @F
		mov ss:pPoolMax,ebx
@@:
		@strout <"#pm, UncommitRegion: pPoolMax=%lX",lf>,ss:pPoolMax
		pop ecx
		mov ebx, edx
;		call updatetlb
		pop ebx
		pop es
exit:
		ret
		align 4

_UncommitRegion endp

;--- move PTEs from one block to another
;--- eax = lin addr of old block
;--- edx = lin addr of new block
;--- ecx = size in pages (may be 0)

_MovePTEs proc public uses es esi edi ebx
		push byte ptr _FLATSEL_
		pop es
		@strout <"#pm, MovePTEs: mov %lX pages from %lX to %lX",lf>,ecx,eax,edx
		push eax
		push ecx

		call _Linear2PT
		mov esi, edi
		mov eax, edx
		call _Linear2PT
		push ds
		push es
		pop ds
		push esi
		push ecx
		rep movsd
		pop ecx
		pop edi
		pop ds
		mov eax, PTF_NORMAL
		rep stosd

		pop ecx
		pop ebx
;		call updatetlb
;		@strout <"#pm, MovePTEs: exit",lf>
		ret
		align 4
_MovePTEs endp

		@ResetTrace

;*** dl=flags,eax=lin addr, ecx=pages ***

_CommitRegionZeroFill proc public

		@strout <"#pm, commit region %lX, size %lX",lf>,eax,ecx
		call commitblockx	;will set es to FLAT
		jc @F
		cld
		pushad
		mov edi,eax
		xor eax,eax
		@strout <"#pm, zerofill region %lX:%lX, size %lX",lf>,es,edi,ecx
		shl ecx,10
		rep stosd
		popad
@@:
		ret
		align 4
_CommitRegionZeroFill endp

;--- allocate address space in system region
;--- cannot be freed anymore
;--- IN: ECX pages
;--- OUT: EAX=linear address

		@ResetTrace

_AllocSysAddrSpace proc public
		mov eax,[SysAddrSpace]
		cmp [SysAddrSize],ecx
		jc error
		sub [SysAddrSize],ecx
		shl ecx,12
		add [SysAddrSpace],ecx
		@strout <"#pm, allocsysaddrspace: block %lX, remaining pages: %lX",lf>,eax, SysAddrSize
error:
		ret
		align 4
_AllocSysAddrSpace endp

;*** IN: ECX pages, DS=GROUP16
;--- OUT: EAX=Addr

_AllocSysPagesRo proc public
		mov dl,PTF_PRESENT or PTF_USER
		jmp AllocSysPages_Common
		align 4
_AllocSysPagesRo endp

_AllocSysPagesX proc public
		mov dl,PTF_PRESENT or PTF_WRITEABLE    ;system page
		jmp AllocSysPages_Common
		align 4
_AllocSysPagesX endp

;--- leaves ES unmodified

_AllocSysPages proc public
		mov dl,PTF_PRESENT or PTF_WRITEABLE or PTF_USER  ;user page
AllocSysPages_Common::
		mov eax,[SysAddrSpace]
		cmp [SysAddrSize],ecx
		jc error
		push es
		pushad
		call _CommitRegionZeroFill	;first do a commit
		popad
		pop es
		jc error					;no more memory
		push ecx
		call _AllocSysAddrSpace		;now allocate address space
		pop ecx
error:
		ret
		align 4
_AllocSysPages endp

if ?USESYSSPACE2
_AllocSysPages2 proc public
		cmp [SysAddrSize],ecx
		jc error
		mov edx,ecx
		shl edx,12
		mov eax,[SysAddrSpace2]
		sub eax,edx
		call _CommitRegion
		jc error
		mov [SysAddrSpace2],eax
		sub [SysAddrSize],ecx
error:
		ret
		align 4
_AllocSysPages2 endp

_FreeSysPages2 proc public
		push ecx
		push eax
		call _UncommitRegion
		pop eax
		pop ecx
		cmp eax,[SysAddrSpace2]
		jnz @F
		add [SysAddrSize],ecx
		mov edx,ecx
		shl edx,12
		add [SysAddrSpace2],edx
@@:
		ret
		align 4
_FreeSysPages2 endp
endif

;--- alloc committed memory in user address space
;--- in:ECX=pages
;--- out: eax=linear address

_AllocUserPages proc public
		pushad
		call AllocUserAddrSpace
		jc exit
		call _CommitRegion
		jc exit		;the address space cannot be freed currently
		mov [esp].PUSHADS.rEAX, eax
exit:
		popad
		ret
		align 4
_AllocUserPages endp

;*** destructor routines Page Manager PM

if ?FREEVCPIPAGES

;--- free VCPI pages in a memory block
;--- either free them directly or copy them to host stack
;--- inp: ESI -> PTE
;---      EDI -> host stack
;---      ECX = cnt pages

		@ResetTrace

freememblock proc

		jecxz exit
nextitem:
		mov eax, es:[esi]
		test al,1
		jz skipitem
		test ah,_VCPIFLAG_
		jz skipitem
		@strout <"#pm: free page %lX at %lX",lf>, eax, esi
		test bl,1
		jz @F
		call freephyspage
		mov es:[esi],eax
		jmp skipitem
@@:
		mov [edi], eax
		add edi, 4
skipitem:
		add esi, 4
		loopd nextitem
exit:
		ret
		align 4
freememblock endp

;--- DS=GROUP16

		@ResetTrace

FreeVCPIPages proc uses esi

		test fHost,FH_VCPI
		jz exit
		cld
		push byte ptr _FLATSEL_
		pop es

		@strout <"#pm: FreeVCPIPages entry, di=%X",lf>, di

;--- copy system region FF800000 pages to host stack

		mov bl,0

		mov esi, [pPageTables]
		add esi, 1000h
		mov ecx, 400h
		@strout <"#pm: free sys space=%lX, entries=%lX",lf>, esi, ecx
		call freememblock
		
;--- free mapped page tables FFC00000 pages 

		mov bl,1

		mov esi, [pPageTables]
if 1
		lea esi, [esi+3*4]
		mov ecx, 400h-3
else
		lea esi, [esi+2*4]	
		mov ecx, 400h-2
endif
		@strout <"#pm: free sys space=%lX, entries=%lX",lf>, esi, ecx
		call freememblock

;--- free anything from 004-FF8 in page dir

		mov esi, pPageDir			;linear address page dir
		lea esi, [esi+4]
		mov ecx,400h-3
		@strout <"#pm: free page tables in page dir %lX, entries=%lX",lf>, esi, ecx
		call freememblock

;--- copy the rest to host stack

		mov bl,0

		mov esi, pPageDir			;linear address page dir
		mov ecx,400h
		call freememblock

		@strout <"#pm: FreeVCPIPages exit, di=%X",lf>, di
exit:
		ret
		align 4

FreeVCPIPages endp

endif

if ?SETCOPYPTE

;--- edx=linear address
;--- eax=new PTE
;--- DS=GROUP16, ES=FLAT

		@ResetTrace

_SetPage proc public
		pushad
		@strout <"#pm, SetPage: edx=%lX, eax=%lX",lf>, edx, eax
		mov eax, edx
		call _Linear2PT
		mov eax, [esp].PUSHADS.rEAX
		xchg eax, es:[edi]
		test al,PTF_PRESENT
		jz notcommitted
		and al, not PTF_PRESENT
;--- save old PTE in page pool
		mov edi, pPageTables
		mov ecx, pPoolMax
		mov ebx, pMaxPageTab
		cmp ecx, ebx
		jnc @F
		mov ecx, ebx
@@:
nextitem:
		cmp edi, ecx
		jnc notfound
		mov ebx, es:[edi]
		add edi, 4
		test bl,PTF_PRESENT
		jnz nextitem
		test bh, _XMSFLAG_
		jnz nextitem
		mov es:[edi-4],eax
		jmp pagestored
notfound:
		mov es:[edi], eax
		mov pPoolMax, edi
pagestored:
		inc dwPagePool
notcommitted:
		mov ecx, 1
		mov ebx, edx
		call updatetlb
		popad
		ret
		align 4
_SetPage endp

endif

;--- inp: edx=linear address to copy from
;--- DS=GROUP16, ES=FLAT
;--- out: eax=(old) PTE of cloned page

_ClonePage proc public
		push edx
		push ebx
		call getphyspage
		pop ebx
		pop edx
		jc @F
		@strout <"#pm, _CopyPage: addr=%lX, new PTE=%lX",lf>, edx, eax
		call CopyPageContent
		@strout <"#pm, _CopyPage: old PTE=%lX",lf>, eax
@@:
		ret
		align 4
_ClonePage endp

;--- edx=linear address to copy from
;--- eax=new PTE to copy to
;--- out: eax=(old) PTE

		@ResetTrace

CopyPageContent proc
		pushad
		cld
		mov ebx, eax
		mov esi, edx

;--- map the dest PTE

		or bl,PTF_PRESENT
		mov es:[(?SYSTEMSPACE+4)*100000h+1000h],ebx
		mov edi, ?SYSTEMSPACE*100000h

		push ds

;--- copy page content

		push es
		pop ds
		mov ecx, 1000h/4
		rep movsd

;--- get current PTE

		mov eax, edx
		call _Linear2PT
		mov eax, es:[edi]

if 0
;--- set new PTE
		mov [esp+4].PUSHADS.rEAX, eax
		and al,PTF_PRESENT or PTF_WRITEABLE or PTF_USER
		and bl, not (PTF_PRESENT or PTF_WRITEABLE or PTF_USER)
		or bl,al
		mov es:[edi],ebx
else
		and al,PTF_PRESENT or PTF_WRITEABLE or PTF_USER
		or byte ptr [esp+4].PUSHADS.rEAX, al
endif

;--- update TLB

		xor ecx, ecx
		mov es:[(?SYSTEMSPACE+4)*100000h+1000h],ecx
		inc ecx
		mov ebx, ?SYSTEMSPACE*100000h
;		call updatetlb
		pop ds
		popad
		clc
		ret
		align 4
CopyPageContent endp


if ?FREEXMSDYN

;--- check the committed pages if one is
;--- contained in current block. If no, release block + clear PTEs in pool

		@ResetTrace

compresspagepool proc

		push es
		push byte ptr _FLATSEL_
		pop es
if _LTRACE_
		mov edx, PhysBlk.dwSize
		sub edx, PhysBlk.dwFree		;edx=pages allocated
		shl edx, 12
		add edx, PhysBlk.dwBase
		@strout <"#pm, compress e: blk base=%lX, size=%lX, free=%lX, nxt free=%lX",lf>, PhysBlk.dwBase, PhysBlk.dwSize, PhysBlk.dwFree, edx
		@strout <"#pm, compress e: pPoolMax=%lX, dwPagePool=%lX, pMaxPageTab=%lX",lf>,pPoolMax, dwPagePool, pMaxPageTab
endif
nextblock:
		call compresspool
		mov edx, PhysBlk.dwBase
		mov ebx, PhysBlk.dwSize
		sub ebx, PhysBlk.dwFree
		shl ebx, 12
		add ebx, edx
		mov ecx, pMaxPageTab
		mov edi, pPageTables
nextitem:
		cmp edi, ecx
		jz blockisfree
		mov eax, es:[edi]
		add edi, 4
		test al,PTF_PRESENT
		jz nextitem
		test ah,_XMSFLAG_
		jz nextitem
		cmp eax, edx
		jc nextitem
		cmp eax, ebx
		jnc nextitem
;--- the page is in use, but in may be just because of the page pool		
;--- this could possibly be "ignored"
		@strout <"#pm, compress: PTE %lX in use at %lX",lf>, eax, edi
		mov esi, pPageTables
		lea esi, [esi+1000h];check if page is an entry in mapping page
		lea ebp, [edi-4]
		cmp ebp, esi
		jnc scandone		;no, so it can't be for page pool -> abort
		mov esi, pMaxPageTab
		sub esi, pPageTables
		shr esi, 10
		add esi, ?SYSPGDIRAREA
		and si, 0FFFCh
		add esi, pPageTables
		cmp ebp, esi
		jc scandone
		call getpoolpage		;get a pool page, but not from current block!
		jc scandone
		@strout <"#pm, compress: weak usage %lX %lX",lf>, ebp, eax
		mov esi, eax
		mov eax, ebp
		push edx
		push ecx
		call PT2Linear		;modifies ECX
		mov edx, eax
		mov eax, es:[esi]
		mov ecx, eax
		call CopyPageContent	;copy 1 Page, linear addr EDX to PTE in EAX

		mov ecx, es:[ebp]
		or al, PTF_PRESENT	;the new PTE must be set
		mov es:[ebp], eax
		and cl, not PTF_PRESENT
		mov es:[esi], ecx	;save the old PTE in the pool
		pop ecx
		pop edx
		jmp nextitem
blockisfree:
		cmp dwPagePool,0
		jz @F
		cmp ecx, pPoolMax
		jnc @F
		mov ecx, pPoolMax
@@:
		mov edi, pPageTables
nextitem2:
		cmp edi, ecx
		jz blockdone
		mov eax, es:[edi]
		add edi, 4
		test ah, _XMSFLAG_
		jz nextitem2
		cmp eax, edx
		jc nextitem2
		cmp eax, ebx
		jnc nextitem2
		mov dword ptr es:[edi-4], PTF_NORMAL
		dec dwPagePool
		jmp nextitem2
blockdone:
		@strout <"#pm, compress: release current PHYSBLK",lf>
		mov eax, offset PhysBlk
		call freephyshandle
		call setactivephyshandle
		test PhysBlk.bFlags, PBF_XMS
		jnz nextblock
scandone:
if _LTRACE_
		mov edx, PhysBlk.dwSize
		sub edx, PhysBlk.dwFree		;edx=pages allocated
		shl edx, 12
		add edx, PhysBlk.dwBase
		@strout <"#pm, compress x: blk base=%lX, size=%lX, free=%lX, nxt free=%lX",lf>, PhysBlk.dwBase, PhysBlk.dwSize, PhysBlk.dwFree, edx
		@strout <"#pm, compress x: pPoolMax=%lX, dwPagePool=%lX, pMaxPageTab=%lX",lf>,pPoolMax, dwPagePool, pMaxPageTab
endif
		pop es
		ret
		align 4
compresspool:
		cld
		mov esi, pMaxPageTab
		mov edi, esi
		mov ecx, pPoolMax
@@:
		cmp esi, ecx
		jnc @F
		mov eax, es:[esi]
		add esi, 4
;		 cmp eax, PTF_NORMAL
;		 jz @B
		test ah,_XMSFLAG_
		jz @B
		add edi, 4
		cmp edi, esi
		jz @B
		@strout <"#pm, pool entry %lX at %lX",lf>, eax, edi
		mov dword ptr es:[esi-4],PTF_NORMAL
		mov es:[edi-4], eax
		jmp @B
@@:
		mov pPoolMax, edi
		@strout <"#pm, pPoolMax before/after compress %lX/%lX",lf>, ecx, edi

;--- the top of the pool has been adjusted		  
;--- now free all PTEs in the mapping page (FFC00000)
;--- which are beyond the new pool top

		mov esi, pPageTables
		sub edi, esi

		shr edi, 10
		add edi, ?SYSPGDIRAREA
		and di, 0FFFCh
		lea edi, [edi+esi+4]
		lea esi, [esi+1000h]
@@:
		cmp edi, esi
		jz cpdone
		mov eax, es:[edi]
		test al,PTF_PRESENT
		jz cpdone
		call freephyspage
		stosd
		jmp @B
cpdone:
if 1
		mov eax, cr3
		mov cr3, eax
endif
		retn

		align 4

;--- get a page from pool, but not from current block
;--- (current block in edx - ebx)
;--- return not the PTE itself but its address in EAX

getpoolpage:
		pushad
		mov edi, pMaxPageTab
		mov ecx, pPoolMax
@@:
		cmp edi, ecx
		jnc noppfound
		mov eax, es:[edi]
		add edi, 4
		test ah, _XMSFLAG_
		jz @B
		cmp eax, edx
		jc ppfound
		cmp eax, ebx
		jc @B
ppfound:
		lea eax, [edi-4]
		mov [esp].PUSHADS.rEAX, eax
		popad
		clc
		retn
		align 4
noppfound:
		popad
		stc
		retn
		align 4
compresspagepool endp

endif

compressdos proc uses es

		push byte ptr _FLATSEL_
		pop es
		mov esi,pPageTables
		mov ecx,pMaxPageTab

		mov edx,[ebx].PHYSBLK.dwBase
		mov edi,[ebx].PHYSBLK.dwSize
		sub edi,[ebx].PHYSBLK.dwFree
		shl edi,12
		add edi,edx

nextitem:
		cmp esi, ecx
		jnc blockfree
		mov eax,es:[esi]
		add esi,4
		test ah,_XMSFLAG_
		jz nextitem
		cmp eax, edx
		jc nextitem
		cmp eax, edi
		jnc nextitem
		test al,PTF_PRESENT					;page allocated?
		jz nextitem
		ret
blockfree:
		mov esi,pPageTables
		mov ecx,pPoolMax
nextitem2:
		cmp esi, ecx
		jnc done
		mov eax,es:[esi]
		add esi,4
		test ah,_XMSFLAG_
		jz nextitem2
		cmp eax, edx
		jc nextitem2
		cmp eax, edi
		jnc nextitem2
		mov dword ptr es:[esi-4], PTF_NORMAL
		dec dwPagePool
		jmp nextitem2
done:
		mov eax, ebx
		call freephyshandle
		ret
		align 4
compressdos endp

;*** client termination
;*** memory has been released already
;*** physical memory and address space could be cleaned here

		@ResetTrace

pm_exitclient proc public

		assume ds:GROUP16

		pushad
		cld
		@strout <"#pm, exitclient enter",lf>
		mov ebx, offset PhysBlk
nextblock:
		@strout <"#pm, PhysBlk: base=%lX, size=%lX, free=%lX, handle=%lX",lf>,\
			[ebx].PHYSBLK.dwBase, [ebx].PHYSBLK.dwSize, [ebx].PHYSBLK.dwFree, [ebx].PHYSBLK.dwHandle
		test [ebx].PHYSBLK.bFlags, PBF_DOS
		jz @F
		call compressdos
@@:
		mov ebx, [ebx].PHYSBLK.pNext
		and ebx, ebx
		jnz nextblock
		call setactivephyshandle
		
if ?FREEXMSDYN
		cmp cApps,1				;this is before it is decremented
		jnz notidle
		test fMode, FM_RESIDENT
		jz notidle				;host will exiting soon, do nothing
		test PhysBlk.bFlags,PBF_XMS
		jz notidle				;no XMS block, cannot be released
		call compresspagepool
notidle:
endif
		popad
		@strout <"   pPageDir=%lX  pPageTables=%lX",lf>,pPageDir, pPageTables
		@strout <"  pPageTab0=%lX  pMaxPageTab=%lX",lf>,pPageTab0, pMaxPageTab
		@strout <"pPagesStart=%lX   dwPagePool=%lX",lf>,pPagesStart, dwPagePool
		@strout <"   pPoolMax=%lX                 ",lf>,pPoolMax
		ret
		align 4
pm_exitclient endp

	@ResetTrace

	assume ds:GROUP16

;--- inp: DS=GROUP16, ES=FLAT
;--- preserves general registers
;--- TLB might be released already!

pm_exitserver_pm proc public
	pushad
	@strout <"#pm: exitserver_pm enter",lf>
;------------------ save all XMS handles on stack *before* freeing memory		 
	@strout <"#pm, start save xms handles on host stack",lf>
;	mov ebx,[pPhysBlkList]
	mov ebx, offset PhysBlk
	mov esi, offset stacktop
nextitem:
	and ebx,ebx
	jz xmsdone
if 1
	test [ebx].PHYSBLK.bFlags, PBF_DOS
	jz @F
	mov eax, ebx
	call freephyshandle
@@: 
endif
	test [ebx].PHYSBLK.bFlags, PBF_XMS
	jz skipitem
	mov ax,[ebx].PHYSBLK.wHandle
	mov [esi],ax
	@strout <"#pm, xms handle %X saved",lf>,ax
	inc esi
	inc esi
skipitem:
	mov ebx,[ebx].PHYSBLK.pNext
	jmp nextitem
xmsdone:
	@strout <"#pm, done save xms handles on host stack",lf>
if ?FREEXMSINRM
	mov pXMSHdls,si
  if ?FREEVCPIPAGES
;---- VCPI pages have to be freed in real-mode as well
;---- because the pages are freed with XMS.
	@strout <"#pm: call FreeVCPIPages",lf>
	mov edi, esi
	call FreeVCPIPages
	mov pVCPIPages, di
  endif
endif
ife ?FREEXMSINRM
	@strout <"#pm: free xms memory blocks",lf>
nextitem2:
	cmp esi,esp
	jz @F
	pop dx
	@strout <"#pm: free xms block %X, rm ss:sp=%X:%X",lf>,dx,ss:[tskstate.rmSS],cs:[tskstate.rmSP]

	@pushproc freexms
	call dormprocintern
	jmp nextitem2
@@:
endif
if ?FREEPDIRPM
	@strout <"#pm: restore cr3",lf>
	mov eax,[orgcr3]
	mov cr3,eax
	xchg eax,[cs._cr3]
	@strout <"#pm: free cr3 page",lf>
	mov ax,[cr3flgs]
	call freephyspage
endif
if ?VCPIALLOC
	@strout <"#pm: VCPI pages allocated on pm exit=%lX",lf>,dwVCPIPages
endif
	@strout <"#pm: exitserver_pm exit",lf>
	popad
	ret
	align 4
pm_exitserver_pm endp

;*** free some physical memory if in i15 mode
;--- used to allow nested execution of clients

_freephysmem proc public
	test ss:[fHost], FH_XMS or FH_VCPI
	jnz exit
	push eax
	mov eax, ss:[dwResI15Pgs]
	and eax, eax
	jnz @F
	mov eax, ss:PhysBlk.dwFree
	shr eax, 1
	mov ss:[dwResI15Pgs], eax
@@:
	sub ss:PhysBlk.dwFree, eax
	pop eax
exit:
	ret
	align 4
_freephysmem endp

;--- called after a int21, ax=4b00 in i21srvr.asm

_restorephysmem proc public
	test ss:[fHost], FH_XMS or FH_VCPI
	jnz exit
	push eax
	xor eax, eax
	xchg eax, ss:[dwResI15Pgs]
	add ss:PhysBlk.dwFree, eax
	pop eax
exit:
	ret
	align 4
_restorephysmem endp

;--- clone GROUP32 
;--- inp: eax=0 -> create first VM
;---      else eax -> dest where copied PTEs are stored
;--- ES=FLAT, DS=GROUP16

		@ResetTrace

pm_CloneGroup32 proc public

		mov ecx, offset endoftext32
		@strout <"#pm, clone group32: alloc %lX bytes 32bit code",lf>, ecx
		mov edx, ecx
		shr ecx, 12
		test dx,0FFFh
		jz @F
		inc ecx
@@:
		and eax, eax
		jz isfirst
		mov edi, eax
;;		mov edx, ?SYSTEMSPACE * 100000h + 1000h
		mov edx, SysAddrSpace
		@strout <"#pm, clone group32: source %lX, dest=%lX, pg=%lX",lf>, edx, edi, ecx
@@:
		call _ClonePage
		jc error
		@strout <"#pm %lX cloned, PTE=%lX", lf>, edx, eax
		stosd
		add edx,1000h
		dec SysAddrSize
		mov SysAddrSpace, edx
		loopnz @B
		@strout <"#pm, clone group32 done, last PTE=%lX, ppt=%lX",lf>, eax, edi
		ret
isfirst:
		call _AllocSysPagesRo
		jc error
		@strout <"#pm, clone group32: copying code to extended memory",lf>
		mov edi, eax
		push ds
		push cs
		pop ds
		xor esi, esi
		mov ecx, offset endoftext32
		shr ecx, 2
		rep movsd
		pop ds
		clc
error:
		ret
		align 4
pm_CloneGroup32 endp

;*** create a VM
;--- inp: DS=GROUP16, ES=FLAT
;--- all registers preserved

;--- for the very first VM, the real-mode setup has initialized a minimal 
;--- system with paging enabled. CR3 is set and PDE 000 as well. page
;--- table 0 is allocated and valid, variable pPageTab0 is initialized.
;--- variable PhysBlk contains a valid physical memory block.

;--- now paging will be fully initialized:
;--- 1. alloc 4 physical pages and map them temporarily at 3FC000-3FFFFF
;--- 2. clear the page contents
;--- 3. copy content of page tab 0 to 3FE000
;--- 4. copy PDEs 000, FF8 and FFC to 3FFxxx (temp. mapped new pagedir)
;--- 5. restore content of old pagetab 0
;--- 6. test if this is the very first VM. If no, copy content of
;---    FFC00000+1000 to 3FC000+1000 (PTEs for system area 0). This
;---    will make GROUP32, GDT, and IDT accessible after CR3 has been
;---    switched.
;--- 7. set new CR3
;--- 8. copy PTE for pagedir to FFC01004h (maps new page dir at FFBFFxxx)

;*** variables set:
;*** v86topm._cr3: CR3
;*** pPageDir:   lin  address page dir
;*** pPagesTab0: lin  address page tab 0
;*** pPagesStart:lin  address page 
;*** pPageTables:lin  address sys area 1
;*** pMaxPageTab:lin  address next entry in cur. page table

?TEMPBASE	equ 3FC000h	;linear address of page tables for new VM in
						;current VM (valid just temporarily inside here)

		@ResetTrace

pm_createvm proc public

		assume ds:GROUP16

		pushad
		mov ebp, esp
		@strout <"#pm: createvm enter",lf>
		@strout <"#pm: cr3=%lX pPageDir=%lX pPageTab0=%lX",lf>, v86topm._cr3, pPageDir, pPageTab0
;		 @waitesckey
		mov SysAddrSpace, ?SYSTEMSPACE * 100000h + 1000h
		mov SysAddrSpace2, (?SYSTEMSPACE+4) * 100000h - 1000h
		mov SysAddrSize, 400h-2

		test fMode, FM_CLONE		;dont clear the PhysBlk var
		jz noinit				;for the first instance

		mov edx, offset GROUP16:startvdata
		xor eax, eax
@@:
		mov [edx], eax
		add edx, 4
		cmp edx, offset GROUP16:endvdata
		jb @B

		test fHost, FH_XMS or FH_VCPI
		jnz noinit
		@strout <"#pm: no XMS or VCPI host",lf>
		call alloci15_pm
		jc noinit
		@strout <"#pm: I15 mem=%lX",lf>, eax
		mov PhysBlk.bFlags, PBF_I15 or PBF_TOPDOWN
		mov PhysBlk.dwBase, edx
		mov PhysBlk.dwSize, eax
		mov PhysBlk.dwFree, eax
noinit:
if ?FREEPDIRPM
		mov eax, v86topm._cr3
		mov orgcr3, eax
endif

;--- first alloc 4 physical pages, store them onto stack

if 1
		invoke _GetNumPhysPages
		@strout <"#pm: free/total phys pages: %lX/%lX",lf>, eax, edx
endif

		@strout <"#pm: alloc 4 physical pages",lf>
		mov ecx,4
@@:
		call getphyspage
		jc exit
		or al,?PAGETABLEATTR
		push eax
		loop @B

;--- map the pages at ?TEMPBASE - ?TEMPBASE+3FFFh
;--- save old PTEs onto the stack

		mov edi, pPageTab0
		add di, 0FF0h
		xor ecx, ecx
@@:
		mov eax, [esp+ecx*4]
		xchg eax, es:[edi+ecx*4]
		mov [esp+ecx*4], eax
		inc ecx
		cmp cl,4
		jnz @B

;--- clear content of new pages

		cld
		mov edi, ?TEMPBASE
		push edi
		mov ecx, 4000h/4
		xor eax, eax
		rep stosd
		pop edi

;--- now clone old pagetab 0
;--- the new pages mapped at 3FC000h are intended to be used:
;--- 3FC000 -> FFC00000 (system area 1)
;--- 3FD000 -> FF800000 (system area 0)
;--- 3FE000 -> 00000000 (page table 0)
;--- 3FF000 -> page directory

;--- the PTE copy must be done in pagetab 0, because for the very
;--- first VM, there is no other address space available

		@strout <"#pm: copy PTEs from previous pt 0, dwOfs=%lX",lf>, dwOfsPgTab0

		lea ebx, [edi + 3000h]	;mapped new page dir
		lea edi, [edi + 2000h]	;new page tab 0
		mov esi, pPageTab0
		push edi
		push esi
		mov ecx, dwOfsPgTab0	;just copy the PTEs which are global!
		shr ecx, 2
		push ds
		push es
		pop ds
		rep movsd
		pop ds
		pop esi
		pop edi
		mov eax, 0FF0h
		add edi, eax			;never copy the last 4 PTEs
		add esi, eax

;--- store the original 4 PTEs in new pagetab 0

		mov cl,4
@@:
		pop eax
		stosd
		loop @B

		test [bEnvFlags2],ENVF2_HMAMAPPING	;reinit region 100000-10FFFF ?
		jz nohmamapping
		sub edi,300h*4
		mov eax,100007h
		mov cl,10h
@@:
		stosd
		add eax,1000h
		loopd @B
nohmamapping:
		push es
		pop ds
		mov edi, ?TEMPBASE
		lodsd
		stosd
		mov [ebx+?SYSTEMSPACE+4],eax
		@strout <"#pm: new PDE for FFC00000=%lX",lf>,eax
		lodsd
		stosd
		mov [ebx+?SYSTEMSPACE],eax
		@strout <"#pm: new PDE for FF800000=%lX",lf>,eax
		lodsd						;PDE for pagetab 000
		stosd
		mov [ebx+0000h],eax
		@strout <"#pm: new PDE for 00000000=%lX",lf>,eax
		lodsd						;new PTE for page dir
		mov ebx, eax

		mov esi, ss:pdGDT.dwBase
		test ss:fMode, FM_CLONE
		jz isfirst

		mov eax,?TEMPBASE + 1004h  ;FF801000h
		push ss
		pop ds
		call pm_CloneGroup32

;--- copy PTEs of saved instance data to new address context
;--- so it is mapped at the very same linear address: FFBFD000
;--- but do clear the _VCPIFLAG_ and _XMSFLAG_ flags in the PTEs
;--- this will make it sure that the physical pages are not released by the clone

		push es
		pop ds
		mov esi, (?SYSTEMSPACE+4) * 100000h + 1FF4h
		mov edi, ?TEMPBASE + 1FF4h
		mov cl,2
@@:
		lodsd
		and ah,not (_VCPIFLAG_ or _XMSFLAG_) 
		stosd
		dec cl
		jnz @B
;;		@strout <"#pm: snapshot PTEs: %lX %lX",lf>, <dword ptr [edi-8]>, <dword ptr [edi-4]>
;		 sub ss:[SysAddrSpace2],2000h
;		 sub ss:[SysAddrSize],2
isfirst:

;--- restore PTEs in old pagetab 0

		mov esi, ?TEMPBASE + 2FF0h	;this is new pagetab 0
		mov edi, ss:pPageTab0
		add di, 0FF0h
		movsd
		movsd
		lodsd				;dont use movsd to copy the last 2 entries.
		push eax			;it is page table 0 + pagedir, VMware doesnt
		lodsd				;like that and will emit an exc 0E
		xchg eax, [esp]
		stosd
		pop eax
		stosd

;--- done, the temp changes in current VM are undone,
;--- the new VM is ready to be used, just set CR3

		push ss
		pop ds
		assume ds:GROUP16
		mov eax, ebx

		and ax,0F000h
		mov v86topm._cr3, eax
if ?FREEPDIRPM
		push eax
		or al,?PAGETABLEATTR
		mov [cr3flgs],ax
		pop eax
endif

;--- the new tables are set, CR3 can be reloaded now

;;		@strout <"#pm: will set CR3 to %lX",lf>,eax
		mov cr3,eax
		@strout <"#pm: new value for CR3 set",lf>
;		 @waitesckey

;--- new page dir is set and mapped, but the address space isn't reserved yet

;		mov eax, SysAddrSpace2
		mov eax, (?SYSTEMSPACE+4) * 100000h - 1000h
		mov pPageDir, eax
		mov es:[(?SYSTEMSPACE+4) * 100000h + 1FFCh],ebx	; map page dir at FFBFF000h

;--- now reinit pPageTab0

		mov pPageTab0, (?SYSTEMSPACE+4) * 100000h + ?SYSPGDIRAREA * 400h

;--- init some important variables

		mov pPageTables, (?SYSTEMSPACE+4) * 100000h
		mov pPagesStart, (?SYSTEMSPACE+4) * 100000h

		@strout <"#pm: pPageTab0=%lX,   pPageDir=%lX, pPageTables=%lX",lf>, pPageTab0, pPageDir, pPageTables
		@strout <"#pm: pPagesStart=%lX, dwPagePool=%lX,    pPoolMax=%lX",lf>, pPagesStart, dwPagePool, pPoolMax

if ?CLEARACCBIT
		@strout <"#pm: clear accessed+dirty bits in region 0-10FFFF",lf>
		mov ecx,110h
		mov edi,[pPageTab0]
@@:
		and byte ptr es:[edi],09Fh
  ifdef _DEBUG
		mov eax,es:[edi]
		and al,7
		.if (al != 7)
			@strout <"#pm: invalid PTE at %lX: %lX !!!",lf>,edi,eax
		.endif
  endif
		add edi,4
		loop @B
endif

;--- init the vm's user address space

		mov esi,pPageTab0
		add esi,dwOfsPgTab0
;;		add esi, 32				;if a security buffer is needed
		mov [pMaxPageTab],esi
		@strout <"#pm: pMaxPageTab=%lX, SysAddrSpace=%lX",lf>, pMaxPageTab, SysAddrSpace


if ?GUARDPAGE0						;get ptr to 1. page
		xor eax,eax
		call _Linear2PT
		@strout <"#pm: ptr to PTE for address 0=%lX",lf>,edi
		sub edi,dwHostBase
		@strout <"#pm: normalized form=%lX",lf>,edi
		mov pg0ptr,edi
endif

		@strout <"#pm: createvm exit",lf>
		clc
exit:
		mov esp,ebp
		popad
		ret
pm_createvm endp

if ?VM

alloci15_pm proc near
		@strout <"#pm, alloci15: int 15h, ax=E801",lf>
		mov ax,0E801h
		stc
		@simrmint 15h
		jc e801_err
		@strout <"#pm, alloci15: int 15h, ax=E801 ok, ax-dx=%X %X %X %X",lf>, ax, bx, cx, dx
		and ax, ax
		jnz @F
		mov ax, cx
		mov bx, dx
@@:
		cmp ax, 3C00h+1	;max is 3C00h (15360 kB)
		jnc e801_err
		movzx eax, ax
		shr ax, 2		;kb -> pages
		movzx ebx, bx
		shl ebx, 4		;64kb -> pages 
		add eax, ebx
		@strout <"#pm, alloci15: pages=%lX",lf>, eax
		mov edx,100000h
		clc
		ret
e801_err:
		stc
		ret

alloci15_pm endp

endif

;*** XMS has only a limited number of handles to be allocated
;*** OTOH we don't want to grap all of extended memory
;*** so a strategy is required:
;*** 1. b1 = _max(EMB/16,512kb)
;*** 2. b2 = _max(b1,req. Block)
;*** 3. b3 = _min(b2,max. Block)
;*** inp: eax=pages of largest block returned by XMS
;***      ecx=pages requested
;*** out: eax size of block to request

getbestxmssize proc
		mov ebx,eax 		;largest block -> ebx
if ?XMSBLOCKCNT
		push ecx
		mov cl,[bXMSBlocks]
		cmp cl,24+1
		jnc @F
		shr cl,3			;0->0, 8->1, 16->2	24->3
		neg cl				;0->0,	 -1,	-2	   -3
		add cl,4			;	4	  3 	 2		1
		shr eax,cl			;largest block / (16|8|4|2)
@@:
		pop ecx
else
		shr eax,4
endif
		cmp eax,80h			;below 128 pages (512 kB)?
		jae @F
		mov al,80h			;min is 512 kB
@@:
		cmp eax,ecx 		;is req block larger?
		jae @F
		mov eax,ecx 		;then use this amount
@@:
		cmp eax,ebx 		;is this larger than max emb?
		jb @F
		mov eax,ebx 		;then use max emb
@@:
		ret
getbestxmssize endp


_TEXT32  ends

_TEXT16	 segment


		@ResetTrace

;*** int 15 rm routine, called for ah=88h or ax=e801
;--- for ah=88h -> return in ax free extended memory in kB
;--- for ax=E801h -> return in ax ext. memory below 16 M in kB (usually 15360)
;--- return in bx extended memory above 16 M (64 kB blocks)

;--- this works because the host allocs physical pages from top to bottom in
;--- this mode

pm_int15rm proc public
		push ecx
		mov ecx, cs:[dwResI15Pgs]
		cmp ah, 0E8h
		jz i15e801
		cmp ecx, 0FFC0h shr 2
		mov ax, cx
		pop ecx
		jb @F
		mov ax, 0FFC0h 			;report 63 MB ext mem
		ret
@@:
		shl ax,2				;pages -> kb
		ret
i15e801:
		mov ax, 15360
		cmp ecx, 15360 shr 2	;this is in pages, not kB
		jnc @F
		mov ax, cx
		shl ax, 2				;pages -> kB
		xor bx, bx				;nothing above 16M
		jmp done

@@:
		sub ecx, 15360 shr 2
		shr ecx, 4				;64k blocks
		mov bx, cx
done:
		pop ecx
		mov cx, ax				;return the values in CX/DX as well
		mov dx, bx
		ret
pm_int15rm endp


if ?I15MEMMGR	;this is 0

;--- set int15 pages to free by server, edx=pages to free
;--- obsolete

seti15pages proc near
		mov eax,cs:PhysBlk.dwFree ;return size in eax
		sub edx,cs:[dwResI15Pgs]  ;don't count the already reserved pages
		jc set15_1				  ;size shrinks
		cmp eax,edx 			  ;size too large
		jb @F
set15_1:
		sub cs:PhysBlk.dwFree,edx
		add cs:[dwResI15Pgs],edx
		clc
		ret
@@:
		stc
		ret
seti15pages endp

endif

		@ResetTrace

;*** get memory block from XMS
;*** inp: ECX=size of block in pages
;*** DS=GROUP16
;*** Out: Carry on errors, else
;*** EAX=pages allocated
;*** EDX=physical address
;*** BX=XMS handle

		@ResetTrace

allocxms proc near uses ds

		push cs
		pop ds
		push ecx
		mov edx,ecx
		shl edx,2
		mov ah,fXMSAlloc
		@stroutrm <"-pm, allocxms: try to alloc %lX kb XMS mem,ax=%X",lf>,edx,ax 
		call [xmsaddr]
		and ax,ax
		jz allocxmserr1			;---> error
		@stroutrm <"-pm, allocxms: EMB allocated, handle=%X",lf>,dx
		push dx
		mov ah,0Ch					;lock EMB
		call [xmsaddr]
		pop cx
		and ax,ax
		jz allocxmserr1			;---> error
		push dx
		push bx
		pop edx 					;physical address -> edx
		mov bx,cx
		@stroutrm <"-pm, allocxms: EMB locked, addr=%lX",lf>, edx
		pop eax						;get no of kbytes
;;		shr eax,2					;convert to pages
		test dx,0FFFh				;starts block on page boundary?
		jz @F
		and dx,0F000h				;if no, do a page align
		add edx,1000h
		dec eax
@@: 								;RC: num pages in EAX
if 0;_LTRACE_
		push ax
		push bx
		push cx
_GetA20State proto near 
		call _GetA20State
		@stroutrm <"-pm, allocxms: A20 state is %X",lf>,ax
		pop cx
		pop bx
		pop ax
endif
		@stroutrm <"-pm, allocxms: allocated %lX pages",lf>,eax
		clc
		ret
allocxmserr1:
		pop ecx 		;adjust stack
		mov ax,bx		;al contains error code
		@stroutrm <"-pm, allocxms: unable to alloc XMS memory, error=%X, sp=%X",lf>,ax,sp
		stc
		ret
allocxms endp

;*** free XMS memory handle
;--- DX = xms memory handle
;--- may modify BX

freexms proc near
		mov ah,0Dh					;unlock EMB
		call cs:[xmsaddr]
		mov ah,0Ah					;free EMB
callxms::        
		call cs:[xmsaddr]
		ret
freexms endp

		@ResetTrace

;--- DS=GROUP16

pm_exitserver_rm proc public

if _LTRACE_
		nop
		@stroutrm <"-pm: exitserver_rm enter",lf>
;		 @waitesckey
endif

		@stroutrm <"-pm: pVCPIPages=%X, pXMSHdls=%X",lf>, pVCPIPages, pXMSHdls
if ?FREEVCPIPAGES

		mov si, pVCPIPages
nextitem:
		cmp si, pXMSHdls
		jz vcpidone
		sub si, 4
		mov edx,[si]
		and dx,0F000h
		mov ax,0DE05h
		int 67h
if _LTRACE_
		and ah,ah
		jz @F
		@stroutrm <"-pm: free VCPI page %lX returned ax=%X",lf>, edx, ax
@@:
endif
		and ah,ah
		jnz nextitem
		dec dwVCPIPages
		@stroutrm <"-pm: free VCPI page %lX returned ax=%X, remaining %lX",lf>, edx, ax, dwVCPIPages
		jmp nextitem
vcpidone:
else
		mov si, pXMSHdls
endif
nextitem2:
		cmp si, offset stacktop
		jbe xmsdone
		dec si
		dec si
		mov dx,[si]
		@stroutrm <"-pm: free XMS handle %X",lf>, dx
		call freexms
		jmp nextitem2
xmsdone:
if 0
		test PhysBlk.bFlags, PBF_DOS
		jz @F
		mov es,PhysBlk.wHandle
		@stroutrm <"-pm: free DOS mem block %X",lf>,es
		mov ah,49h
		int 21h
@@:
endif
		@stroutrm <"-pm: exitserver_rm exit, sp=%X",lf>,sp
		ret
pm_exitserver_rm endp

_TEXT16 ends

;*** initialization

_ITEXT16 segment

		@ResetTrace

;*** no XMS/VCPI host detected, try Int15 alloc
;*** Out: EAX=number of free pages
;*** Out: EDX=phys. addr of block

alloci15 proc near
		mov cl, 0
if ?USEE820
		@stroutrm <"-pm, alloci15: int 15h, ax=E820",lf>
		xor ebx, ebx
		sub sp, 20
		mov di, sp
		push ss
		pop es
nextitem:
		mov ecx, 20
		mov edx,"SMAP"
		mov eax,00E820h
		int 15h
		mov cl, 0
		jc done
		and ebx, ebx
		jz done
		.if (dword ptr es:[di+16] == 1)
			mov edx, es:[di+0]
			.if (edx == 100000h)
				mov eax, es:[di+8]
				shr eax, 12 		;bytes -> pages
				inc cl
				jmp done
			.endif
		.endif
		jmp nextitem
done:
		add sp, 20
endif
if ?USEE801
  if ?USEE820
		cmp cl,0
		jnz donee801
  endif
		@stroutrm <"-pm, alloci15: int 15h, ax=E801",lf>
		mov ax,0E801h
		int 15h
		jc e801_err
		@stroutrm <"-pm, alloci15: int 15h, ax=E801 ok, ax-dx=%X %X %X %X",lf>, ax, bx, cx, dx
		and ax, ax
		jnz @F
		mov ax, cx
		mov bx, dx
@@:
		cmp ax, 3C00h+1	;max is 3C00h (15360 kB)
		jnc e801_err
		movzx eax, ax
		shr ax, 2		;kb -> pages
		movzx ebx, bx
		shl ebx, 4		;64kb -> pages 
		add eax, ebx
		mov cl,1
		@stroutrm <"-pm, alloci15: pages=%lX",lf>, eax
		jmp donee801
e801_err:
		mov cl,0
donee801:
endif
		cmp cl,0
		jnz @F
		@stroutrm <"-pm, alloci15: int 15, ah=88h",lf>
		mov ah,88h				;get extended memory size (kB)
		int 15h
		@stroutrm <"-pm, alloci15: Int 15 extended memory size=%X",lf>,ax
		movzx eax, ax
		shr ax,2				;kb -> pages
		and ax,ax
		jz exit
@@:
;		mov [dwNxtPageOfs],-1000h ;allocate from top to bottom
;		mov edx,eax
;		shl edx,12				;pages -> bytes
;		add edx,100000h-1000h	;block starts at 0x100000 (HMA)
		mov edx,100000h
		clc
exit:
		ret

alloci15 endp

;--- get physical address of linear address in 1. MB
;--- inp: eax = linear address
;--- out: edx = physical address

getphysaddr proc
		mov edx,eax
		test [fHost],FH_VCPI
		jz exit
		push cx
		push eax
		shr eax,12				;get physical address from VCPI
		mov cx,ax				;inp: page number in CX
		mov ax,0DE06h
		int 67h
		and dl,0F8h				;clear R/O, USER, PRESENT bits
		pop eax
		pop cx
exit:
		ret
getphysaddr endp

;*** alloc memory for 2 page tables + 4 PTEs (2010h bytes) in dos memory
;--- this is for page table 0, page dir + 4 additional PTEs 
;*** this is temporary until we are in protected mode
;--- and will be changed in initserver_pm
;--- out: EAX = linear address page table 0
;--- ES= segment page table 0

		@ResetTrace

allocpagetab0 proc

		@stroutrm <"-pm, allocpagetab0: try to alloc 2000h bytes conv. memory",lf>
		mov bx, 200h		;2 pages (8 kB), needed are 1004h bytes
		mov ah, 48h
		int 21h
		jc error
		mov word ptr [taskseg._ES],ax	;save it here, will be released soon
		@stroutrm <"-pm, allocpagetab0: DOS memory alloc for page tabs ok (%X)",lf>,ax

;--- now shrink the memory so it fits exactly

		mov es,ax
		mov ah,1            ;2 full pages
		neg al				;+ page align the memory
		inc ax				;+ 1 paragraph
		mov bx,ax
		mov ah,4Ah
		int 21h
if 0	;igore shrink failure
		jc error
		@stroutrm <"-pm, allocpagetab0: DOS memory realloc for page tabs ok (%X)",lf>,bx
endif
		mov ax,es
        add ax,100h-1
		mov al,00
		@stroutrm <"-pm, allocpagetab0: page tab start %X",lf>,ax
;--- init page table 0:
;--- 000000-10FFFF: phys=linear 
;--- 110000-3FFFFF: NULL
		mov es,ax
		xor di,di
		mov cx,440h/4
		xor eax,eax
		or al,PTF_PRESENT or PTF_USER or PTF_WRITEABLE
		cld
@@:
		stosd
		add eax,1000h
		loop @B
		mov cx,(1000h-440h)/4	;init rest of tab0
		xor eax,eax
		rep stosd
		@stroutrm <"-pm, allocpagetab0: initialization pagetab0 + pagedir done",lf>
        
		mov ax,es
		shl eax,4
error:
		ret
allocpagetab0 endp

if ?INT15XMS

		@ResetTrace

getunmanagedmem proc
		@stroutrm <"-pm, getunmanagedmem enter",lf>

;--- a 2.0 host cannot handle more than 65535 kb extended memory
;--- that would give highest address:
;--- FFFF * 400 -> 3FFFC00 + 100000h -> 40FFC00 - 1 -> 40FFBFF
;--- but usually HMA is not included in this calculation:
;--- FFFF * 400 -> 3FFFC00 + 110000h -> 410FC00 - 1 -> 410FBFF
;--- to be sure, round up to the next page: 410FFFF

		mov ecx,0410FFFFh
		test [fHost],FH_XMS30	;xms driver 3.0+?
		jz @F
		mov ah, fXMSQuery
		call xmsaddr
		cmp ecx,110000h
		jb error
		mov ax,cx
		and ah,03h
		cmp ax,03FFh
		jnz error
@@:
		@stroutrm <"-pm, getunmanagedmem highest address=%lX",lf>, ecx
		push ecx		
		call alloci15
		pop ecx
		@stroutrm <"-pm, getunmanagedmem int 15h base=%lX, size=%lX",lf>, edx, eax
;--- ecx = highest address for XMS
;--- eax = int 15 mem (pages)
;--- edx = 100000h
		shl eax, 12
		add eax, edx
		inc ecx
		sub eax,ecx
		ja @F
error:
		stc
		ret
@@:
		mov edx, ecx
		shr eax, 12
		@stroutrm <"-pm, using unmanaged memory base=%lX, size=%lX",lf>, edx, eax
		mov PhysBlk.bFlags, PBF_I15 or PBF_TOPDOWN
		cmp eax, ?PAGEMIN		;could we get the minimum?
		ret
getunmanagedmem endp
endif

;*** initialization Page Manager RM
;*** allocs minimum space required for init:
;--- 1 page   page dir
;--- 3 pages  page tables 0, FF8, FFC
;--- 1 page   pm breaks + GDT
;--- 1 page   IDT
;--- 1 page   LDT
;--- 1 page   LPMS
;--- 2 page   client save state
;--- 7 pages  CGROUP if code is moved high
;*** RC: C on errors (not enough memory)
;*** sets:
;*** vcpiOfs: offset entry VCPI
;*** v86topm._cr3: value for CR3
;*** pPageDir:linear address page dir
;*** pPageTables:linear address page tables
;*** pPageTab0:linear address page table 0
;*** dwOfsPgTab0: offset 1. free PTE in page table 0

?HEAPPAGE equ 1	;add 1 page for heap

if ?MOVEHIGH
?PAGEMIN	equ 10+7+?HEAPPAGE
else
?PAGEMIN	equ 10+?HEAPPAGE
endif

		@ResetTrace

pm_initserver_rm proc public

if _LTRACE_
		nop
		@stroutrm <"-pm: initserver_rm enter",lf>
endif
		test [fHost], FH_XMS
if ?XMSALLOCRM
		jz noxms
  if ?INT15XMS
		test fMode2, FM2_INT15XMS
		jz @F
		call getunmanagedmem
		jnc initpagemgr_rm_1
@@:
  endif
  if ?VCPIPREF
		test fMode2, FM2_VCPI
		jz @F
		test fHost, FH_VCPI
		jz @F
		and fHost, not (FH_XMS or FH_XMS30)
		jmp noxms
@@:
  endif
		mov ah, fXMSQuery
		mov bl,0				;some XMS hosts dont set BL on success
		call [xmsaddr]
		cmp bl,0
		jnz noxms
		test [fHost],FH_XMS30	;xms driver 3.0+?
		jnz @F
		movzx eax,ax
@@:
		shr eax,2				;kb->pg
		mov cx,6				;alloc 1/32 of max free block
nexttry:
		cmp eax, ?PAGEMIN*2
		jb @F
		shr eax, 1
		loop nexttry
@@: 	
		cmp eax, ?PAGEMIN
		jb noxms
		mov ecx, eax
		call allocxms			;alloc XMS memory
		jc noxms
		mov PhysBlk.wHandle,bx
		mov PhysBlk.bFlags, PBF_XMS
		jmp initpagemgr_rm_1
noxms:
		@stroutrm <"-pm: no XMS memory",lf>
else
		jnz initpagemgr_rm_2	;XMS exists, all ok
endif
if ?VCPIALLOC
		test [fHost],FH_VCPI	;VCPI host exists?
		jz @F
if ?NOVCPIANDXMS
		test [fHost],FH_XMS		;avoid using VCPI if XMS host exists
		jnz @F
endif
		mov ax,0DE03h			;get number of free pages (EDX)
		int 67h
		@stroutrm <"-pm: free VCPI pages=%lX",lf>, edx
		cmp edx, ?PAGEMIN
		jnc initpagemgr_rm_2
@@:
endif
		@stroutrm <"-pm: no VCPI or XMS memory",lf>
		test fHost, FH_XMS or FH_VCPI
		jnz @F
		mov PhysBlk.bFlags, PBF_I15 or PBF_TOPDOWN
		call alloci15			;try to alloc with Int 15h
		cmp eax, ?PAGEMIN		;could we get the minimum?
		jnb initpagemgr_rm_1	;that would be ok for now
@@:
		test [bEnvFlags],ENVF_INCLDOSMEM
		stc
		jz error
		@stroutrm <"-pm: no extended memory found, try to alloc dos mem",lf>
		mov bx,(?PAGEMIN+1)*100h
		mov ah,48h
		int 21h
		jc error				;if this fails, we are 'out of mem'
		mov PhysBlk.wHandle, ax
		movzx edx,ax
		add dx,100h-1			;align to page 
		mov dl,0
		shl edx,4				;make it a linear address
		@stroutrm <"-pm: dos memory allocated, addr=%lX, size=%X paras",lf>,edx, bx
		mov eax,?PAGEMIN
		mov PhysBlk.bFlags, PBF_DOS or PBF_LINEAR
initpagemgr_rm_1:
		@stroutrm <"-pm: PhysBlk init, base=%lX, size=%lX pg",lf>, edx, eax
		mov PhysBlk.dwSize, eax 	;pages total
		mov PhysBlk.dwFree, eax 	;pages free to allocate
		mov PhysBlk.dwBase, edx		;phys. address
initpagemgr_rm_2:
		call allocpagetab0		;will set ES=page tab 0
		jc error
		mov [pPageTab0],eax 	;linear address page table 0
		call getphysaddr		;phys. addr von eax nach edx
		@stroutrm <"-pm: pPageTab0=%lX [PDE=%lX]",lf>, eax, edx
		or dl,PTF_PRESENT or PTF_NORMAL
		assume es:SEG16
		mov es:[1000h+000],edx	;set PDE for pagetab0 in page dir

		add eax,1000h
		mov pPageDir, eax
		call getphysaddr
		mov v86topm._cr3, edx	;CR3 will be modified later
		@stroutrm <"-pm: pPageDir=%lX [CR3=%lX]",lf>, eax, edx

		xor di,di				;es:di ^ pagetable 0
		test [fHost],FH_VCPI
		jz @F
		mov si,offset vcpidesc	;ds:si ^ 3 descriptors in GDT
		mov ax,0DE01h			;get protected mode interface
		int 67h
		cmp ah,00				;returns in DI=first free entry
		stc 					;in pagetab 0
		jnz error
		mov [vcpiOfs],ebx		;entry VCPI host
		@stroutrm <"-pm: get protected mode interface ok (%lX,%X)",lf>,ebx,di
@@:
		cmp di,440h 			;never go below linear addr 110000h 
		jnb @F
		mov di,440h
@@:
		mov word ptr [dwOfsPgTab0],di	;first free entry in page table 0
		@stroutrm <"-pm: real mode initialization ok",lf>
if ?386SWAT
		test fDebug,FDEBUG_KDPRESENT
		jz @F
		mov ebx, v86topm._cr3
		mov edx, pPageDir
		mov ax, 0DEF4h
		int 67h
@@:
endif
		clc
error:
		@stroutrm <"-pm: initserver_rm exit",lf>
		ret
pm_initserver_rm endp

pm_initserver2_rm proc public
		push es
		mov es,word ptr [taskseg._ES]
		@stroutrm <"-pm: releasing old page tables %X",lf>, es
		mov ah,49h
		int 21h
		pop es
		ret
pm_initserver2_rm endp

_ITEXT16 ends

		end

