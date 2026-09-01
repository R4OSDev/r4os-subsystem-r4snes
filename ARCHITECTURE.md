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
- `cpu.zig`: W65C816/S-CPU architectural state.
- `ppu.zig`: S-PPU state and future frame production.
- `smp.zig` and `sdsp.zig`: S-SMP/SPC700 and S-DSP state.
- `controller.zig`: port-1 serial pad state; port 2 remains disconnected.
- `coprocessors.zig`: explicit enhancement-chip registry without implicit
  fallbacks.
- `persistence.zig`: canonical SRAM path and future atomic persistence policy.
- `host_adapter.zig`: R4OS physical-key mapping only.
- `machine.zig`: instance-local composition and lifecycle boundary.

No component stores a host pointer or global mutable guest state. Cartridge
source bytes are never changed; parsing copies only the normalized program
view into private ownership. All 24-bit decode results are checked indices into
private ROM, SRAM or 128-KiB WRAM. Unknown areas return explicit open-bus state.
Scheduling, guest time and audio enter through the generic SDK runtime only in
later milestones, and 0.2.0 still executes no cartridge instruction.
