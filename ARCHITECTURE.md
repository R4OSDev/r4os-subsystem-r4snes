# Architecture

R4SNES follows R4OS subsystem ownership boundaries. The R4X owns guest state;
the SDK owns generic window/input/video transport; the Kernel owns physical
device identity. SNES button policy exists only in `host_adapter.zig`.

Every launch will receive a private `Machine`. Its owners are separated as
follows:

- `cartridge.zig` and `board.zig`: immutable ROM identity, mapping and board
  capabilities.
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

No component stores a host pointer or global mutable guest state. Scheduling,
guest time and audio will enter through the generic SDK runtime in later
milestones. The foundation never reads, patches or executes cartridge bytes.
