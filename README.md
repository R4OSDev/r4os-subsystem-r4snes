# R4SNES

R4SNES is the public, original Zig implementation of the Super Nintendo
subsystem for R4OS. It is a userland GUI R4X with the stable subsystem ID
`r4os.snes` and guest format `snes.cartridge` for `.sfc` and `.smc` files.

Version 0.19.0 joins the bounded cartridge frontend, complete W65C816, timed
5A22 and byte-interruptible DMA/HDMA with a dot-observed S-PPU in a productive
`R4SUBSYS1` application host. The PPU owns
VRAM/CGRAM/OAM and renders modes 0-7, Mode 7, sprites, windows, main/subscreen,
color math, fixed color, mosaic, VMAIN, hires, overscan and interlace. It
publishes only complete changed native XRGB32 generations at 256 or 512 pixels
wide and 224, 239, 448 or 478 pixels high.

The S-SMP now owns a complete bus-phased SPC700, 64 KiB ARAM, TEST/CONTROL,
three timers, DSP register access and four ordered CPU/APU port latches. A
semantic IPL service performs the documented upload without distributing the
proprietary 64 bytes. An optional exact user image is accepted only from
`C:\R4OS\SUBSYSTEMS\r4os.snes\FIRMWARE\SPC700.IPL` and only at exactly 64
bytes. The public module contains no IPL image.

The cycle-clocked S-DSP owns all 128 registers, eight voices, BRR decode and
loops, Gaussian interpolation, pitch/noise/modulation, KON/KOFF, ADSR/GAIN,
main and echo mixing, eight-tap FIR, feedback and echo RAM. Its native 32 kHz
stereo stream is converted deterministically to 48 kHz S16LE in caller-owned
blocks of at most 2048 frames through a bounded queue. A thin adapter composes
that queue only with `r4os.subsystem_runtime`; mute or backend degradation
discards audio without changing guest time, video or machine progress.

The unchanged Gilyon CPU and SPC ROMs, all 256000 SPC700 state and bus-cycle
vectors, a 32768-byte IPL-speed transfer, twelve exact PPU models and nine HDRV
geometry scripts run through module-owned gates. Nine digital S-DSP cases are
matched byte-for-byte against the revision-pinned independent SNES-SPC oracle,
and an automatic WAV analyzer checks 48 kHz frequency, continuity and channel
ratio. The reference harness also
integrity-checks 23 bounded PPU diagnostics without promoting visual output to
truth.

Every productive launch owns a private cartridge, `Machine`, persistence
session, runtime adapter, video adapter and immutable source buffers. Host time
is converted into NTSC or PAL master-clock debt, with one reported grant of at
most 32768 clocks per host cycle; a complete CPU or DMA operation may cross the
edge only by its bounded remainder, which is credited against the next grant.
The host exposes pause, resume, reset, mute and unmute, accepts physical port-1
keys only while focused, publishes native XRGB32 generations and sends only
caller-owned 48-kHz PCM through App-Audio. Reset creates fresh machine, save,
video and audio generations. Close and every open-error path unwind in reverse
order and are repeat-idempotent. This establishes automatic product-host
operation without making a commercial-ROM playability claim before the final
manual acceptance.

Battery-backed SRAM and SA-1 BW-RAM persist as one exact
board-sized `HASH.SAV` below
`C:\R4OS\SUBSYSTEMS\r4os.snes\SAVE\`; the hash is calculated from the
normalized ROM after copier-header removal. S-RTC and Epson state use one
versioned, fixed-size and SHA-256-protected `HASH.RTC` record containing chip
identity, live and latched registers, halt/overflow state and bounded
forward-only catch-up. The R4OS backend is the SDK source helper shared with
R4GB: one create-only writer lease, immutable snapshots, one coalescing worker,
same-directory stage/target/last-good publication, bounded recovery and
mandatory drain/join. Battery-less boards never access this namespace, and no
legacy or host-specific path is probed.

OBC-1 is now an executable board capability. Its complete 8-KiB battery RAM,
both documented bank mirrors, object selector, four-byte object window and
packed two-bit attribute window run through the production cartridge bus at
slow-cartridge timing. Only changed physical bytes extend the dirty interval,
and restart reconstructs selectors from the exact `HASH.SAV` payload.

S-RTC is likewise executable on its documented ExHiROM profile. The `$2800`
read and `$2801` write ports implement marker, command, transactional
twelve-nibble calendar write, latch and reset states. Live and latched
calendars use checked BCD/range rules, Gregorian leap years and an explicit
reset-halted state. Forward offline time is applied before the next atomic RTC
snapshot; host time reversal is ignored. Unknown revisions, contradictory
headers and checksum-valid but semantically invalid RTC records fail with
specific diagnostics instead of falling back to a base board.

S-DD1 and SPC7110/Epson RTC are executable board owners with bounded streaming
decompression, exact cartridge windows, data/arithmetic ports and their
documented SRAM/RTC behavior. Seven synthetic streams match the unchanged
Mesen2 and Snes9x decoders byte-for-byte; Ares is retained as a third reviewed
state-machine source.

Super FX is executable as GSU-1 or GSU-2. The owner implements all 256 opcode
bytes and all ALT states, the real pipeline and branch delay slot, ROM/RAM
buffers, 512-byte cache, S-CPU/GSU bus arbitration, IRQ/STOP, clock selection,
and the complete 2/4/8-bpp PLOT/RPIX cache pipeline. Standard cartridge headers
do not encode the GSU revision: the compatible default is GSU-2/VCR `$04`,
while explicit board metadata may select GSU-1/VCR `$03`; SlowROM/FastROM is
never misused as a revision signal. Battery-backed 32/64/128-KiB GSU work RAM
uses the same normalized-ROM `HASH.SAV` location, while battery-less boards do
not touch persistence.

`Tests/Build-SuperFxPrograms.ps1` uses the pinned WLA-DX 10.7 binaries on both
Linux and Windows to rebuild two unchanged OpenSNES GSU examples and four
original opcode/cache/pixel/bus programs. The reference gate binds every
binary digest, RAM completion cells and aggregate device state, and compares
all 16384 pixels from the OpenSNES wireframe example with an independent
Bresenham bitmap.

SA-1 is an executable board capability with a private W65C816, independent
clock and interrupt/reset state, Super MMC ROM mapping, 2-KiB I-RAM, mapped
BW-RAM and bitmap views. Both processors use the documented write protections
and observable bus contention. Normal DMA, both character-conversion modes,
variable-bit reads, signed arithmetic and accumulation, timer IRQs and vector
overrides are bounded and retain their state across arbitrary host slices.
Battery-backed BW-RAM uses the same exact normalized-ROM `HASH.SAV`; I-RAM and
battery-less BW-RAM remain volatile.

The focused `sa1-reference-test` executes six revision-pinned open hardware
ROMs through the production dual-CPU/PPU path. Two self-checking ROMs must end
at WRAM `$000000 = $01`; four utilities use fixed tilemap, WRAM, SA-1-state or
defined-register digests while electrically indeterminate open-bus fields are
kept diagnostic. The backup utility runs twice with only BW-RAM carried over.
Every phase also writes a raw tilemap and 256x224 PPM evidence image below
`Temp/R4SNES-SA1`; the full corpus is bound to aggregate digest
`62D2B8ACD2C164B6`.

CX4 is an executable, firmware-free HG51B169 owner with complete instruction
decoding, two program caches, 3 KiB data RAM, DMA, asynchronous bus access,
IRQ/reset/suspend and a generated fixed-point mathematical ROM. Four programs
are rebuilt with WLA-DX and bind exact register, RAM, geometry and pixel
oracles without title data or command HLE.

The NEC uPD7725 owner executes DSP-1, DSP-1A, DSP-1B, DSP-2, DSP-3 and DSP-4
through one complete instruction core and revision-specific LoROM/HiROM host
windows. R4SNES never distributes their 8192-byte programs. A separate image
must use the exact fixed name below
`C:\R4OS\SUBSYSTEMS\r4os.snes\FIRMWARE\`, or a legacy image may append the
same 8192 bytes. Size and known revision SHA-256 are mandatory; there is no
download or HLE fallback. DSP-1/DSP-1A code is identical, DSP-1B is the safe
default when the standard header has no exact board metadata, and an appended
known image can disambiguate the package. Firmware is excluded from the
normalized cartridge identity and is cleared from temporary and device memory
on close.

`Tests/Build-NecDspFirmware.ps1` reproducibly emits six original open firmware
images covering all four instruction classes, 16 ALUs, 16 sources, 16
destinations, pointer modes and all 39 defined branch modes plus a reserved
case. The public harness binds exact Ares and Mesen2 source revisions and the
aggregate digest `B281EE2EAAA5F878`. An optional private gate validates all six
revisions against known firmware hashes and proves a real DSP-1B Q15 multiply;
private bytes are neither copied nor emitted.

The only connected controller is port 1 and it uses physical keyboard usages:

- D-pad: arrow keys
- Start: Enter
- Select: right Control
- X/A/B/Y: keypad 8/6/2/4
- L/R: keypad 7/9

Controller port 2 is intentionally disconnected until a later USB-controller
project defines its platform contract. Numeric-row and navigation keys are not
aliases for keypad controls.

Build on Linux with `./Build.sh`; build on Windows with `Build.bat`. Both thin
starters run the same PowerShell 7 orchestration. `./Build.sh test` runs the
module-owned host tests and generates `share/r4snes/CPU_OPCODE_COVERAGE.json`
under the artifact prefix and self-tests the S-DSP WAV analyzer.
`./Build.sh reference-test` validates the optional, locally acquired inventory,
parses all bound diagnostic cartridges, runs both
Gilyon CPU ROMs and Gilyon SPC through the production ports, executes the IPL
speed transfer, checks all 256000 SPC700 vectors including bus phases, and
binds the nine exact S-DSP comparison cases.
Use `./Build.sh superfx-reference-test` for the focused reproducible GSU source,
binary, completion, state and pixel-frame gate.
Use `./Build.sh sa1-reference-test` for the focused six-ROM SA-1 completion,
defined-field, evidence-artifact and two-start BW-RAM gate.
Use `./Build.sh nec-dsp-reference-test` for the six open uPD7725 firmware
variants. Supplying `-Dnec-dsp-private-root=<directory>` additionally validates
locally owned firmware without making it a build prerequisite.
