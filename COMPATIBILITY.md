# Compatibility

The 0.2.0 cartridge stage accepts `.sfc` and `.smc` candidates up to 64 MiB,
normalizes an optional 512-byte copier header and requires one unambiguous
LoROM, HiROM, ExLoROM or ExHiROM header. Region, board capability, declared
sizes, reset vector, startup opcode and checksum/complement contribute to a
concrete result. Header checksum equality is evidence rather than a lone veto,
so consistent homebrew remains representable. Execution still ends with a
deterministic not-implemented error. No commercial cartridge is shipped,
embedded or needed by the public build.

The capability table names every planned enhancement family and the
user-firmware sizes for NEC-DSP/ST hardware without claiming those devices are
already executable. MSU-1 and adapter systems remain explicit exclusions;
unknown boards fail closed and are never silently run as a base board.

SRAM will use the canonical subtree
`C:\R4OS\SUBSYSTEMS\r4os.snes\SAVE`. The cartridge remains immutable and no
legacy or host-specific save directory is probed.
