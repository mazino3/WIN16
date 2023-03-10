
;--- handle video output in real-mode
;--- this code is only included if there is debug output in real-mode

		.386
        
		include hdpmi.inc
		include external.inc
        include debugsys.inc

		.286

		option proc:private

@seg	SEG16
@seg	_TEXT16

?MONOOUT	= 0

if ?MONOOUT
?ALTCURPOS	equ 5F0h
?ALTISVALID	equ 0DEB1h
endif

if _TRACE_
_BRIGHT_	equ 9
else
_BRIGHT_	equ 7
endif

_NORM_		equ 7	;text attribute

BIOSCOLS	equ 44Ah
BIOSPGOFS   equ 44Eh
BIOSCSR 	equ 450h
BIOSPAGE	equ 462h
BIOSCRT		equ 463h
BIOSROWS	equ 484h

;*** video output in real mode ***

		assume	ds:SEG16
		assume	es:SEG16

_TEXT16	segment

$wordout proc near
		push	ax
		mov 	al,ah
		call	$byteout
		pop 	ax
$wordout endp
$byteout proc near
		pushf
		push	ax
        mov		ah,al
		shr 	al,4
        call    nibout
        mov		al,ah
        call    nibout
        pop     ax
        popf
        ret
nibout:        
		and 	al,0Fh
		cmp 	al,10
		sbb 	al,69H
		das
		jmp     _$putchrx
$byteout endp

_$VioSetCurPosDir proc stdcall row:word,col:word

		mov 	ah,byte ptr row
		mov 	al,byte ptr col
if ?MONOOUT
		mov		ds:[?ALTCURPOS],ax
		mov		word ptr ds:[?ALTCURPOS+2],?ALTISVALID
        mov		bh,80
        mov		bl,0
else
		xor	bx,bx
		mov	bl, byte ptr ds:[BIOSPAGE]	
;		movzx 	bx,byte ptr ds:[BIOSPAGE]
		add 	bx,bx
		mov 	ds:[BX+BIOSCSR],ax 	;set cursor pos
		mov 	bh,ds:[BIOSCOLS]
endif        
		ret
_$VioSetCurPosDir endp

_$putchrx proc

local	cols:word
local	rows:word
local	char:word

		mov		char,ax
		push	ds
		push	es
        pusha
if ?USEDEBUGOUTPUT
		test	cs:fDebug,FDEBUG_OUTPFORKD
		jz		@F
		mov 	ah,D386_Display_Char
		int 	D386_RM_Int
		jmp 	exit
@@:        
endif
		push	0
		pop 	ds
		push	0B000H
		pop 	es
if ?MONOOUT
		mov		ch,24
		mov		cl,80
		mov 	bx,ds:[?ALTCURPOS]		;cursor pos (row in BH)
        cmp		word ptr ds:[?ALTCURPOS+2], ?ALTISVALID
        jz		@F
        xor		bx, bx
@@:        
else
		mov 	ch,ds:[BIOSROWS]		;rows-1
		mov 	cl,ds:[BIOSCOLS]		;cols
		xor	bx,bx
;		movzx 	bx,byte ptr ds:[BIOSPAGE]
		mov 	bl,byte ptr ds:[BIOSPAGE]
		add 	bx,bx
		mov 	bx,ds:[BX+BIOSCSR]		;cursor pos (row in BH)
endif        
		mov 	byte ptr rows,ch
		xchg	bl,bh
		xor	ax,ax
;		movzx 	ax,bl
		mov 	al,bl
		mov 	ch,00
		mov 	cols,cx
		mul 	cl
		add 	ax,ax
;		movzx 	bx,bh
		mov	bl,bh
		mov	bh, 0
		add 	bx,bx
		add 	bx,ax
if ?MONOOUT
		mov		si,0
else        
		mov 	si,ds:[BIOSPGOFS]
		cmp 	word ptr ds:[BIOSCRT],3B4h
		jz		@F
		add 	si,8000h
@@:
endif
		mov 	al,byte ptr char

		cmp 	al,cr
		jnz 	ppch21
		mov 	ax,bx
		shr 	ax,1
		div 	cl
		mov 	al,ah
		xor 	ah,ah
		add 	ax,ax
		sub 	bx,ax
		jmp 	ppch3
ppch21:
		cmp 	al,lf
		jnz 	ppch1
		add 	bx,cx
		add 	bx,cx
		jmp 	ppch3
ppch1:
		mov 	es:[bx+si],al
		inc 	bx
		inc 	bx
ppch3:
		mov 	al,byte ptr rows
		inc 	al
		mul 	cl
		add 	ax,ax
		cmp 	bx,ax
		jc		ppch4
		call	scrollr
		mov 	bx,ax
ppch4:
		mov 	ax,bx
		mov 	cx,cols
		shr 	ax,1
		div 	cl			   ;now row in al, col in ah
		mov 	cx,ax
		mov 	al,ah
		mov 	ah,00
		mov 	ch,00
		invoke	_$VioSetCurPosDir,cx,ax
exit:        
        popa
		pop 	es
		pop 	ds
		ret
scrollr:
		push  ds

		push  es
		pop   ds
		mov   di,si
		push  di
		mov   si,cols
		add   si,si
		add   si,di
		mov   cx,cols
		mov   al,byte ptr rows
		mul   cl
		mov   cx,ax
		cld
		rep   movsw
		push  di
		mov   cx,cols

		mov   ax,0720h
		rep   stosw

		pop   ax			  ;save address last row
		pop   di
		sub   ax,di

		pop   ds
		retn
_$putchrx endp

$getwordfromstack proc
		mov 	ax,[bp+0]	;get saved value of bp
		xchg	ax,[bp+2]	;move it up 1 word, get ip
		xchg	ax,[bp+4]	;move it up 1 word, get word from stack
		inc 	bp
		inc 	bp
		ret
$getwordfromstack endp


_$stroutx proc near public

		push bp
        mov  bp,sp
		pushf
        push ax
        push si
        cld
        mov  si,[bp+2]
        add  word ptr [bp+2],2
		mov	 si,word ptr cs:[si]
nextitem:
		db	  2Eh		;seg CS
		lodsb
		and   al,al
		jz	  done
        cmp   al,'%'
        jz    format
        cmp   al,lf
        jnz   @F
        mov   al,13
        call  _$putchrx
        mov   al,lf
@@:        
		call  _$putchrx
		jmp   nextitem
done:
        pop   si
        pop   ax
		popf
        mov sp,bp
        pop bp
		ret
format: 
		push	offset nextitem
		db		2Eh
		lodsb
		cmp 	al,'X'
		jz		stroutx_X
		cmp 	al,'l'
		jnz 	@F
;;		mov		dl,al
		db		2Eh
		lodsb
		cmp 	al,'X'
		jz		stroutx_lX
@@:
		cmp 	al,'s'
		jz		stroutx_s
        push	ax
        mov		al,'%'
        call	_$putchrx
        pop		ax
		call	_$putchrx
        retn
stroutx_lX:							;%lX get 2 words
		call	$getwordfromstack
		push	ax
		call	$getwordfromstack
		call	$wordout
		pop 	ax
		jmp 	$wordout
stroutx_X:							;%X get 1 word
		call	$getwordfromstack
		jmp		$wordout
stroutx_s:							;%ls or %s get string
		push	ds
		push	si
		call	$getwordfromstack
		mov 	ds,ax
		call	$getwordfromstack
		mov 	si,ax
@@:
		lodsb
		and 	al,al
		jz		@F
		call    _$putchrx
		jmp 	@B
@@:
		pop 	si
		pop 	ds
        retn
_$stroutx endp

_TEXT16	ends

end
