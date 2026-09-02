; R4SNES-owned HG51B169 asynchronous bus fixture.  WLA-DX does not expose
; names for source registers $2e/$2f, so their documented opcodes are emitted
; explicitly.  r0 points at cartridge ROM, r2 at CX4 data RAM.

.MEMORYMAP
    SLOTSIZE $10000
    DEFAULTSLOT 0
    SLOT 0 $0000
.ENDME

.ROMBANKSIZE $10000
.ROMBANKS 1

.BANK 0 SLOT 0
.ORG 0

.SECTION "R4SnesCx4Bus" FORCE
    MOV  MAR,r0
    .DW  $602E          ; MOV A,ROMBUS: schedule delayed ROM read
    WAIT
    MOV  A,MDR
    MOV  r1,A

    MOV  MAR,r2
    MOV  MDR,$5A
    .DW  $E12F          ; MOV RAMBUS,MDR: schedule delayed RAM write
    WAIT
    .DW  $602F          ; MOV A,RAMBUS: schedule delayed RAM read
    WAIT
    MOV  A,MDR
    MOV  r3,A

    MOV  A,$AB
    MOV  r15,A
    HALT
.ENDS
