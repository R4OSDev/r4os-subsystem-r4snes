# Compatibility

The 0.14.0 subsystem accepts `.sfc` and `.smc` candidates up to 64 MiB,
normalizes an optional 512-byte copier header and requires one unambiguous
LoROM, HiROM, ExLoROM or ExHiROM header. Region, board capability, declared
sizes, reset vector, startup opcode and checksum/complement contribute to a
concrete result. Header checksum equality is evidence rather than a lone veto,
so consistent homebrew remains representable. No commercial cartridge is
shipped, embedded or needed by the public build. Execution ends
with a deterministic not-implemented error until the productive runtime-machine
and window host are connected.

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

S-DSP qualification covers all eight voices, BRR filters and loop/end flags,
Gaussian interpolation, pitch modulation, noise, every ADSR/GAIN family,
KON/KOFF/ENDX/ENVX/OUTX, main/echo volume, echo RAM, feedback and all eight FIR
taps. Nine synthetic cases, including a single BRR impulse, compare exact
stereo PCM and register/RAM digests with SNES-SPC revision
`ec8ee2bbe30451614c1d02a83f7af1c97d497d45`. Streaming tests require identical
native and 32-to-48-kHz output across arbitrary clock partitions, bounded
overflow/underflow behavior and guest progress during mute or backend failure.
The PowerShell WAV gate independently rejects discontinuity, wrong frequency
and wrong stereo balance. Audible quality remains a final-stage manual check.

OBC-1 and S-RTC are executable capabilities. OBC-1 requires the exact LoROM,
battery and 8192-byte object-RAM profile. S-RTC requires its ExHiROM, battery
and save-RAM profile. Recognizable but unknown revisions and contradictory
profiles have separate rejection classes. The capability table continues to
name every later enhancement family and the user-firmware sizes for NEC-DSP/ST
hardware without claiming those devices are already executable. MSU-1 and
adapter systems remain explicit exclusions.

The S-PPU owner now covers modes 0-7, native hires and interlace geometries,
Mode 7, windows, main/subscreen composition, color math, fixed color, mosaic,
VMAIN and sprite limits. Twelve exact synthetic XRGB32 digests and nine HDRV
register scripts are automated gates. Twenty-three digest-pinned foreign ROMs
remain diagnostics because no licensed, revision-bound hardware capture is
available; their visual similarity is never treated as a pass condition.

Battery SRAM and SA-1 BW-RAM use only the canonical subtree
`C:\R4OS\SUBSYSTEMS\r4os.snes\SAVE\` and one exact board-sized
uppercase-`HASH.SAV`. S-RTC and SPC7110 Epson RTC state use an exact,
versioned and checksummed `HASH.RTC` with chip identity, live/latched registers,
halt, overflow and bounded forward-only catch-up. One writer lease and one
serial snapshot worker publish through same-directory stage, target and
last-good backup; malformed or partial recovery fails closed. Close drains the
worker before releasing ownership. Battery-less boards do not touch the
backend. The cartridge remains immutable and no legacy or host-specific save
directory is probed.

OBC-1 tests cover direct and indirect bytes, packed attributes, both selector
bases, every documented bank mirror, reset reconstruction, exact bus timing,
dirty bounds and persistence restart. S-RTC tests cover command/read/write
markers, stable latches, reset/halt, valid ranges, February in leap and century
years, year wrap, arbitrary slice partitioning and offline restart. An RTC
record with a valid outer checksum but invalid live calendar, weekday, latch,
halt relation or reserved state is still rejected before it reaches the chip.

SA-1 boards execute a private W65C816 against independent reset, interrupt and
clock state. Qualification covers Super MMC mapping, CPU/SA-1 I-RAM and BW-RAM
protection, bitmap access, contention, bounded normal and character-conversion
DMA, arithmetic/accumulation, variable-bit reads, timers, vectors, WAI/STP and
slice invariance. Six pinned open hardware ROMs run through the dual-CPU/PPU
path: both self-checking tests return `$01`, the utilities bind deterministic
tilemap/register/state fields, and electrically indeterminate fields are
masked rather than invented. The backup utility proves a cold/warm two-start
protocol in which exact battery BW-RAM persists but I-RAM and all other device
state restart. Unknown revisions and contradictory SA-1 geometries fail with
dedicated diagnostics.
