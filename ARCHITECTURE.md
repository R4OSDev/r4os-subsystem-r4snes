# Architecture

R4SNES follows R4OS subsystem ownership boundaries. The R4X owns guest state;
the SDK owns generic window/input/video transport; the Kernel owns physical
device identity. SNES button policy exists only in `host_adapter.zig`.

Every launch receives a private `Machine`. Its owners are separated as
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
- `obc1.zig`: exact 8-KiB object-RAM windows, selectors and documented bank
  mirrors without owning persistence policy.
- `srtc.zig`: Sharp S-RTC protocol, live/latch calendar and bounded
  partition-invariant time advancement without host-clock access.
- `sdd1.zig` and `spc7110.zig`: bounded streaming decompression and documented
  cartridge/data-port mapping; `epson_rtc.zig` owns the optional RTC-4513.
- `superfx.zig`: private GSU-1/GSU-2 execution, cache, bus arbitration and
  complete PLOT/RPIX pipeline.
- `sa1.zig`: private W65C816, Super MMC, I-/BW-RAM, DMA/conversion, arithmetic,
  timers, vectors and dual-processor arbitration.
- `cx4.zig`: HG51B169 ISA, caches, mathematical ROM, DMA and asynchronous
  cartridge-bus ownership.
- `nec_dsp.zig`: common uPD7725 ISA, multiplier, host handshake and exact
  DSP-1/1A/1B/2/3/4 board windows; firmware policy remains outside the core.
- `persistence.zig`: normalized identity policy, exact SRAM/BW-RAM payloads,
  checksummed S-RTC/Epson records and forward-only offline-time policy.
- `persistence_r4os.zig`: thin configuration of the SDK's compiled-in lease,
  serial-worker and atomic recovery mechanism for the canonical SNES tree.
- `host_adapter.zig`: R4OS physical-key mapping and generation-safe XRGB32
  bridge into `r4os.subsystem_host`.
- `runtime_adapter.zig`: bounded composition of the machine stepper and S-DSP
  queue with `r4os.subsystem_runtime`; it owns no guest clock or backend.
- `timing.zig`: pause-correct host-time conversion into region-specific
  master-clock debt and bounded grants.
- `machine.zig`: instance-local CPU/DMA, PPU, S-SMP and enhancement scheduling
  plus the productive execution and lifecycle boundary.
- `product_host.zig`: private source, machine, persistence, runtime, video,
  input/focus and reverse-teardown ownership for one application launch.

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
owned by the shared SDK runtime. Version 0.19.0 starts a validated cartridge
through the productive R4SUBSYS1 application path. Host elapsed time becomes
NTSC/PAL master-clock debt; each host cycle reports at most 32768 clocks. CPU
and DMA operations finish atomically at that edge and their bounded remainder
is credited against the next grant. PPU, S-SMP and the selected enhancement
owner advance from the same machine clock rather than host time. Firmware
lookup remains an application-boundary policy and generic scheduling remains
in the SDK.

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

Enhancement access precedes generic MMIO, SRAM and ROM decode only for the
chip's exact documented windows. OBC-1 folds banks `00-3F/80-BF:6000-7FFF`
and the `70-71/F0-F1` mirrors into one 13-bit RAM address. Selector writes and
indirect object/attribute writes report their changed physical byte to the
cartridge, which maintains one bounded dirty interval while persistence keeps
the full board-sized raw payload. Reset reloads selector state from battery
RAM and never clears it.

S-RTC owns only `00-3F/80-BF:2800-2801` at system-I/O timing. A read command
captures an explicit latch; a calendar write becomes live only after all
twelve writable nibbles form one valid date. The thirteenth weekday nibble is
calculated from the Gregorian date. The reset command yields the sole halted
all-zero representation. Persistence imports and validates both live and
latched state, applies at most 512 days of forward catch-up to the device, and
exports the resulting calendar before publication. Invalid calendar,
weekday, latch, halt and reserved-byte states retain distinct error classes.

SA-1 is a cartridge-owned second processor, not a scheduler or Kernel object.
Its private W65C816 advances on an integer master-clock relation and exposes
only bounded slice/until-clock entry points. Super MMC owns every ROM lookup;
I-RAM, BW-RAM, bitmap views, write protections and contention stay inside the
device. Normal DMA and both character conversion paths operate one bounded
unit at a time. Reset, WAI/STP, bidirectional IRQ/NMI, vectors, arithmetic,
variable-bit reads and timers remain instance-local. Only physical BW-RAM dirty
ranges can reach cartridge persistence, and only on a battery board; I-RAM is
always volatile.

The NEC-DSP owner has 2048 24-bit program words, 1024 16-bit data-ROM words,
256 private data-RAM words and a four-word stack. Every instruction advances
exactly one DSP cycle and updates the signed multiplier pipeline after the
operation. OP/RT/JP/LD, both accumulators, all flags, DP/RP modifiers, serial
acknowledge conditions and RQM/DRS/DRC byte sequencing follow one bounded
state machine. A recognized RQM self-loop yields to the host without consuming
unbounded cycles; any slice partition produces the same complete state.

Cartridge parsing first separates a possible 8192-byte appended firmware tail
and only then validates the normalized ROM. Separate and appended firmware are
mutually exclusive. The immutable cartridge SHA-256 never includes firmware,
while the device retains its own revision digest. Product validation accepts
only the exact known revision digest from the fixed private path; the relaxed
policy is explicitly named `allow_open_test` and is used solely by generated
owner fixtures. Close is idempotent and erases program ROM, data ROM, RAM,
stack and digest.
