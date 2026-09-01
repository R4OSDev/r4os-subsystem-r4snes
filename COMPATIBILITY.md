# Compatibility

The 0.8.0 subsystem accepts `.sfc` and `.smc` candidates up to 64 MiB,
normalizes an optional 512-byte copier header and requires one unambiguous
LoROM, HiROM, ExLoROM or ExHiROM header. Region, board capability, declared
sizes, reset vector, startup opcode and checksum/complement contribute to a
concrete result. Header checksum equality is evidence rather than a lone veto,
so consistent homebrew remains representable. Execution still ends with a
deterministic not-implemented error until 5A22 integration. No commercial
cartridge is shipped, embedded or needed by the public build.

CPU qualification covers every legal opcode in emulation mode and all four
native M/X combinations. Synthetic cases check register/flag widths, direct
page and bank boundaries, high-before-low read-modify-write stores, native and
emulation stacks, BCD arithmetic, block moves, interrupt vectors, WAI/STP and
the first differing micro-operation between traces. The optional reference
gate executes the unchanged Gilyon 1.4 basic and full ROMs through the same CPU,
cartridge and bus used by the module. WDC documentation is normative; observed
edge behavior was independently compared with Ares and Mesen 2 without copying
their implementation.

SPC700 qualification executes all 256000 pinned cases through the production
core and compares A/X/Y, PSW, PC/SP, listed ARAM and every read/write/wait
phase. Gilyon spctest reaches Success through the real W65C816 bus, semantic
IPL upload and directional port latches; the open IPL-speed ROM transfers
32768 bytes without a first data divergence. Timer, SLEEP/STOP, port-order,
oscillator partition and optional exact-IPL cases are separate owner gates.

The capability table names every planned enhancement family and the
user-firmware sizes for NEC-DSP/ST hardware without claiming those devices are
already executable. MSU-1 and adapter systems remain explicit exclusions;
unknown boards fail closed and are never silently run as a base board.

The S-PPU owner now covers modes 0-7, native hires and interlace geometries,
Mode 7, windows, main/subscreen composition, color math, fixed color, mosaic,
VMAIN and sprite limits. Twelve exact synthetic XRGB32 digests and nine HDRV
register scripts are automated gates. Twenty-three digest-pinned foreign ROMs
remain diagnostics because no licensed, revision-bound hardware capture is
available; their visual similarity is never treated as a pass condition.

SRAM will use the canonical subtree
`C:\R4OS\SUBSYSTEMS\r4os.snes\SAVE`. The cartridge remains immutable and no
legacy or host-specific save directory is probed.
