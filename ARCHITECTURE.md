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
- `spc700.zig` and `smp.zig`: complete bus-phased SPC700, ARAM, timers,
  CPU/APU latches, semantic IPL and optional exact user IPL.
- `sdsp.zig`: cycle-clocked S-DSP, native PCM, deterministic resampler and
  bounded caller-buffered audio queue.
- `controller.zig`: port-1 serial pad state; port 2 remains disconnected.
- `coprocessors.zig`: explicit enhancement-chip registry without implicit
  fallbacks.
- `persistence.zig`: normalized identity policy, exact SRAM/BW-RAM payloads,
  checksummed S-RTC/Epson records and forward-only offline-time policy.
- `persistence_r4os.zig`: thin configuration of the SDK's compiled-in lease,
  serial-worker and atomic recovery mechanism for the canonical SNES tree.
- `host_adapter.zig`: R4OS physical-key mapping and generation-safe XRGB32
  bridge into `r4os.subsystem_host`.
- `runtime_adapter.zig`: bounded composition of the machine stepper and S-DSP
  queue with `r4os.subsystem_runtime`; it owns no guest clock or backend.
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

The S-SMP bus exposes every instruction read, write and wait phase. Its three
divider timers advance from those phases, while the independent rational APU
oscillator records synchronization points for the four directional port
latches without using host time. The standard semantic IPL accepts the public
upload protocol but never supplies arbitrary bytes at `$FFC0-$FFFF`; an exact
path exists only for an optional 64-byte user file in the private firmware
tree.

The S-DSP advances one of its 32 hardware phases for every APU clock against
the same ARAM used by SPC700. Its register file, eight voices, BRR history,
envelopes, noise generator and echo/FIR state are instance-local. Complete
native 32 kHz stereo samples feed a rational 3:2 streaming converter; it is
partition invariant and writes only a fixed 8192-frame queue. The host can
pull no more than 2048 48 kHz S16LE frames into a caller-owned buffer.

`runtime_adapter.zig` is the sole audio/runtime boundary. It applies prefill,
tracks transport ownership and disables capture on mute or backend failure
without stalling or accelerating the guest. Reset and repeated close clear the
same queue and resampler state. Generic pause, resync and backend policy remain
owned by the shared SDK runtime. Version 0.10.0 still does not start a parsed
cartridge in the R4OS application because the productive machine and window
host are deliberately scheduled for a later milestone.

Persistence is keyed only by the normalized 32-byte cartridge digest. A
battery board acquires one generation-bound lease and loads exactly its
declared SRAM or BW-RAM length; a size mismatch is corruption. RTC boards also
load an exact 128-byte version-1 record whose SHA-256 binds chip kind,
registers, latch, halt, overflow, clock anchors and pending catch-up. Host time
moving backwards queues nothing; forward jumps and accumulated work are
bounded to 512 days. The compiled-in SDK helper copies dirty data before its
single worker performs stage/target/last-good replacement. Its recovery accepts
only the expected size and validates RTC content, while Close drains and joins
before releasing the lease. This is a source-level helper, not an R4L or ABI.
