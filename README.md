# R4SNES

R4SNES is the public, original Zig implementation of the Super Nintendo
subsystem for R4OS. It is a userland GUI R4X with the stable subsystem ID
`r4os.snes` and guest format `snes.cartridge` for `.sfc` and `.smc` files.

Version 0.1.0 is deliberately a foundation release. It establishes isolated
owners for cartridge/board, 24-bit bus, S-CPU, PPU, S-SMP, S-DSP, controller,
coprocessors, persistence and R4OS host adapters. Every cartridge launch is
validated only as a bounded candidate and then rejected with a concrete
not-implemented result. This version makes no playability claim.

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
module-owned host tests and `./Build.sh reference-test` validates the optional,
locally acquired reference inventory.
