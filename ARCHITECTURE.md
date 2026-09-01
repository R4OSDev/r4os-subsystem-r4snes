# Architecture

R4SNES follows R4OS subsystem ownership boundaries. The R4X owns guest state;
the SDK owns generic window/input/video transport; the Kernel owns physical
device identity. SNES button policy exists only in `host_adapter.zig`.

Every launch will receive a private `Machine`. Its owners are separated as
follows:

- `cartridge.zig` and `board.zig`: bounded source normalization, immutable
  SHA-256 ROM identity, four explicit base mappings, board capabilities and
  private SRAM.
- `bus.zig`: bounded 24-bit address routing and open-bus state.
- `opcode.zig`: the single exhaustive 256-entry legal-opcode decode truth.
- `cpu.zig`: W65C816 architectural state, ALU, address formation, interrupts
  and bounded bus-micro-operation execution.
- `ppu.zig`: dot-observed S-PPU state and complete native frame production.
- `smp.zig` and `sdsp.zig`: S-SMP/SPC700 and S-DSP state.
- `controller.zig`: port-1 serial pad state; port 2 remains disconnected.
- `coprocessors.zig`: explicit enhancement-chip registry without implicit
  fallbacks.
- `persistence.zig`: canonical SRAM path and future atomic persistence policy.
- `host_adapter.zig`: R4OS physical-key mapping and generation-safe XRGB32
  bridge into `r4os.subsystem_host`.
- `machine.zig`: instance-local composition and lifecycle boundary.

No component stores a host pointer or global mutable guest state. Cartridge
source bytes are never changed; parsing copies only the normalized program
view into private ownership. All 24-bit decode results are checked indices into
private ROM, SRAM or 128-KiB WRAM. Unknown areas return explicit open-bus state.

The CPU receives a compile-time bus port rather than owning the cartridge or
MMIO. Production ports route through `bus.zig`; tests therefore cannot replace
address decoding with a second CPU implementation. A step emits at most one
instruction or interrupt transition. Its fixed trace identifies fetch, read,
write, idle and vector-read operations with 24-bit address, value and bus time.
Repeated MVN/MVP iterations remain separate bounded steps, and WAI/STP remain
observable states rather than host loops.

The PPU consumes the canonical 5A22 master-clock stream. Modes 0-7, Mode-7
matrix/repeat/flip/EXTBG, windows, main/subscreen, color math, fixed color,
mosaic, VMAIN, sprites and active-display register effects remain private to
that owner. Complete changed frames are packed as native XRGB32 at 256/512 by
224/239/448/478; unchanged output does not advance the generation. The shared
SDK alone scales, letterboxes and splits damage into at most 128x128 rasters.

Scheduling, guest-time admission and audio enter through the generic SDK
runtime only in later milestones. Version 0.7.0 still does not start a parsed
cartridge in the R4OS application because the APU and productive runtime host
are not yet connected.
