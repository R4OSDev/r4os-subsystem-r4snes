# R4SNES

R4SNES is the public, original Zig implementation of the Super Nintendo
subsystem for R4OS. It is a userland GUI R4X with the stable subsystem ID
`r4os.snes` and guest format `snes.cartridge` for `.sfc` and `.smc` files.

Version 0.9.0 joins the bounded cartridge frontend, complete W65C816, timed
5A22 and byte-interruptible DMA/HDMA with a dot-observed S-PPU. The PPU owns
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
truth. Productive cartridge execution remains deliberately rejected until the
runtime-machine and window-host stages are wired, so this version still makes no
playability claim.

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
