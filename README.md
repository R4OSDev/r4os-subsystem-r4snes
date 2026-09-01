# R4SNES

R4SNES is the public, original Zig implementation of the Super Nintendo
subsystem for R4OS. It is a userland GUI R4X with the stable subsystem ID
`r4os.snes` and guest format `snes.cartridge` for `.sfc` and `.smc` files.

Version 0.2.0 owns a bounded cartridge frontend and the complete base 24-bit
address space. It strips one plausible copier header, selects one unambiguous
LoROM/HiROM/ExLoROM/ExHiROM header, hashes the normalized immutable ROM,
allocates board-sized private SRAM and exposes checked ROM/SRAM decoders. A
private 128-KiB WRAM bus delegates MMIO and records 6/8/12-masterclock access
classes with separate CPU/PPU open-bus latches. Every parsed cartridge is still
rejected before execution, so this version makes no playability claim.

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
