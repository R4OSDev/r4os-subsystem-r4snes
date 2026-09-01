# Compatibility

The 0.1.0 foundation accepts `.sfc` and `.smc` launch metadata only long enough
to recognize a bounded candidate geometry. It then returns a deterministic
not-implemented error. No commercial cartridge is shipped, embedded or needed
by the public build.

Later roadmap stages add mapping, CPU, timing, PPU, audio, persistence and
documented enhancement-chip families behind explicit validation. Unsupported
or firmware-dependent boards must fail closed and must never silently run as a
different board.

SRAM will use the canonical subtree
`C:\R4OS\SUBSYSTEMS\r4os.snes\SAVE`. The cartridge remains immutable and no
legacy or host-specific save directory is probed.
