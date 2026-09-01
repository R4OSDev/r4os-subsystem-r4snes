# R4SNES

R4SNES is the public, original Zig implementation of the Super Nintendo
subsystem for R4OS. It is a userland GUI R4X with the stable subsystem ID
`r4os.snes` and guest format `snes.cartridge` for `.sfc` and `.smc` files.

Version 0.3.0 adds a complete, instance-local W65C816 core to the bounded
cartridge frontend and 24-bit bus. All 256 legal opcode bytes, emulation and
native mode, independent M/X widths, bank and page wrapping, decimal
arithmetic, stack forms, block moves, RESET/ABORT/NMI/IRQ/BRK/COP, WAI and STP
are implemented. Every external fetch, read, write and vector access plus each
internal idle cycle is represented as a bounded micro-operation. Block moves
process exactly one byte per step.

The unchanged Gilyon `cputest-basic` and `cputest-full` ROMs run through the
production CPU and bus in the optional reference gate. A generated JSON index
records five tested decode variants for every opcode. Productive cartridge
execution remains deliberately rejected until 5A22 timing and MMIO are wired,
so this version still makes no playability claim.

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
under the artifact prefix. `./Build.sh reference-test` validates the optional,
locally acquired inventory and runs both Gilyon CPU ROMs.
