; R4SNES-owned HG51B169 fixture.  The input is an original vector and
; 2x2 matrix; the result is exposed both as coordinates and as one transformed
; 2-bpp pixel.  The program also reads each mathematical CX4 data-ROM family.

.MEMORYMAP
    SLOTSIZE $10000
    DEFAULTSLOT 0
    SLOT 0 $0000
.ENDME

.ROMBANKSIZE $10000
.ROMBANKS 1

.BANK 0 SLOT 0
.ORG 0

.SECTION "R4SnesCx4Geometry" FORCE
    ; Input: v=(1,2), M=((2,1),(-1,2)) in r0..r5.
    ; out.x = 1*2 + 2*1 = 4.
    MOV  A,r0
    MUL  r2
    MOV  A,MACL
    MOV  r6,A
    MOV  A,r1
    MUL  r3
    MOV  A,MACL
    ADD  A,r6
    MOV  r8,A

    ; out.y = 1*(-1) + 2*2 = 3, including signed multiply/wrap.
    MOV  A,r0
    MUL  r4
    MOV  A,MACL
    MOV  r7,A
    MOV  A,r1
    MUL  r5
    MOV  A,MACL
    ADD  A,r7
    MOV  r9,A

    ; Exact public CX4 lookup families: sine, tangent, arcsine, reciprocal.
    RDROM $240
    MOV  A,ROM
    MOV  r10,A
    RDROM $320
    MOV  A,ROM
    MOV  r11,A
    RDROM $2C0
    MOV  A,ROM
    MOV  r12,A
    RDROM $00A
    MOV  A,ROM
    MOV  r13,A

    ; Publish transformed wireframe vertex outside the tile at RAM $20/$21.
    MOV  A,r8
    MOV  RAM,A
    MOV  A,$20
    WRRAM 0,A
    MOV  A,r9
    MOV  RAM,A
    MOV  A,$21
    WRRAM 0,A

    ; Convert (x=4,y=3) to the two bytes of row 3 in a 2-bpp tile.
    ; mask = $80 >> x = $08; row address = y*2 = 6.
    MOV  A,$80
    SHR  A,r8
    MOV  RAM,A
    MOV  A,r9
    SHL  A,1
    MOV  r14,A
    WRRAM 0,A
    ADD  A<<0,$01
    WRRAM 0,A

    MOV  A,$AB
    MOV  r15,A
    HALT
.ENDS
