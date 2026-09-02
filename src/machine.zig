const board = @import("board.zig");
const bus = @import("bus.zig");
const cartridge = @import("cartridge.zig");
const controller = @import("controller.zig");
const coprocessors = @import("coprocessors.zig");
const cpu = @import("cpu.zig");
const persistence = @import("persistence.zig");
const ppu = @import("ppu.zig");
const scpu = @import("scpu.zig");
const smp = @import("smp.zig");
const timing = @import("timing.zig");

pub const RunFault = enum {
    closed,
    cpu,
    dma_stalled,
    smp,
    super_fx,
    sa1,
    cx4,
};

pub const RunResult = struct {
    granted_master_cycles: u32 = 0,
    executed_master_cycles: u64 = 0,
    frame_ready: bool = false,
    fault: ?RunFault = null,
};

/// The MMIO owner used by productive S-CPU execution. It joins only devices
/// which really share the $2100-$21ff window; scheduling and host services stay
/// outside this adapter.
const SystemMmio = struct {
    display: *ppu.Ppu,
    audio: *smp.Smp,

    pub fn read(self: *SystemMmio, address: u32, cpu_open_bus: u8, ppu_open_bus: u8) bus.MmioRead {
        const offset: u16 = @truncate(address);
        if (offset >= 0x2140 and offset <= 0x2143) {
            return .{
                .handled = true,
                .value = self.audio.cpuReadPort(@truncate(offset - 0x2140)),
                .latch = .none,
            };
        }
        return self.display.read(address, cpu_open_bus, ppu_open_bus);
    }

    pub fn write(self: *SystemMmio, address: u32, value: u8, cpu_open_bus: u8, ppu_open_bus: u8) bool {
        const offset: u16 = @truncate(address);
        if (offset >= 0x2140 and offset <= 0x2143) {
            self.audio.cpuWritePort(@truncate(offset - 0x2140), value);
            return true;
        }
        return self.display.write(address, value, cpu_open_bus, ppu_open_bus);
    }

    pub fn onMasterTick(self: *SystemMmio, clock: *const timing.Clock) void {
        self.display.onMasterTick(clock);
    }

    pub fn filteredMasterTickRequired(self: *const SystemMmio, clock: *const timing.Clock) bool {
        return self.display.masterTickRequired(clock);
    }

    pub fn synchronizeClock(self: *const SystemMmio, clock: *timing.Clock) void {
        self.display.synchronizeClock(clock);
    }
};

pub const Machine = struct {
    instance_id: u64,
    board: ?board.Board = null,
    bus: bus.Bus = .{},
    cpu: cpu.Cpu = .{},
    scpu: scpu.Scpu = .{},
    ppu: ppu.Ppu = .{},
    smp: smp.Smp = .{},
    controllers: controller.Ports = .{},
    coprocessors: coprocessors.Registry = .{},
    persistence: persistence.State = .{},
    clock: timing.Clock = .{},
    host_budget: timing.HostBudget = .{},
    rtc_master_phase: u64 = 0,
    slices: u64 = 0,
    maximum_operation_overshoot: u64 = 0,
    closed: bool = false,

    pub fn init(instance_id: u64) Machine {
        return .{ .instance_id = instance_id };
    }

    /// Powers a caller-owned machine at its final address. Product hosts use
    /// this entry so the roughly two-megabyte PPU/SMP state is never returned
    /// through an app-stack temporary.
    pub fn powerInPlace(result: *Machine, instance_id: u64, cart: *const cartridge.Cartridge, exact_ipl: ?[]const u8) !void {
        result.* = .{ .instance_id = instance_id };
        result.board = cart.board;
        result.coprocessors.selected = cart.board.capability.enhancement;
        result.clock = timing.Clock.init(if (cart.board.region == .pal) .pal else .ntsc);
        result.scpu.reset(&result.bus, &result.controllers, &result.cpu);
        result.smp.powerSemanticIpl();
        if (exact_ipl) |firmware| {
            try result.smp.installExactIpl(firmware);
            result.smp.reset();
        }
    }

    pub fn power(instance_id: u64, cart: *const cartridge.Cartridge, exact_ipl: ?[]const u8) !Machine {
        var result: Machine = undefined;
        try powerInPlace(&result, instance_id, cart, exact_ipl);
        return result;
    }

    pub fn foundationReady(self: *const Machine) bool {
        return self.instance_id != 0 and self.controllers.port1.connected and
            !self.controllers.port2.connected and self.coprocessors.implemented() and
            !self.closed;
    }

    /// Executes at most one caller grant. CPU and DMA operations remain
    /// indivisible, so the last one can cross the target by a few clocks. The
    /// overshoot is credited by HostBudget and never increases the runtime's
    /// reported 32,768-clock grant.
    pub fn runHostSlice(
        self: *Machine,
        cart: *cartridge.Cartridge,
        caller_limit: u32,
        guest_nanoseconds: u64,
    ) RunResult {
        if (self.closed) return .{ .fault = .closed };
        const granted = self.host_budget.budget(
            guest_nanoseconds,
            self.clock.profile().master_hz,
            caller_limit,
        );
        if (granted == 0) return .{};

        const start = self.clock.master_cycles;
        const start_frame = self.ppu.frame_generation;
        while (self.clock.master_cycles -% start < granted) {
            const consumed = self.clock.master_cycles -% start;
            const remaining: u32 = @intCast(@as(u64, granted) - consumed);
            if (self.runOperation(cart, remaining)) |fault| {
                const executed = self.clock.master_cycles -% start;
                self.host_budget.reconcile(granted, executed);
                return .{
                    .granted_master_cycles = granted,
                    .executed_master_cycles = executed,
                    .frame_ready = self.ppu.frame_generation != start_frame,
                    .fault = fault,
                };
            }
        }
        const executed = self.clock.master_cycles -% start;
        self.host_budget.reconcile(granted, executed);
        self.maximum_operation_overshoot = @max(self.maximum_operation_overshoot, executed - granted);
        self.advanceRtc(cart, executed);
        self.slices +%= 1;
        return .{
            .granted_master_cycles = granted,
            .executed_master_cycles = executed,
            .frame_ready = self.ppu.frame_generation != start_frame,
        };
    }

    pub fn close(self: *Machine) void {
        if (self.closed) return;
        self.closed = true;
        self.scpu.dma.abortAll();
        self.controllers.clearInput();
        self.smp.dsp.endCapture();
        self.host_budget.pause();
        self.smp.removeExactIpl();
    }

    fn runOperation(self: *Machine, cart: *cartridge.Cartridge, maximum_master_cycles: u32) ?RunFault {
        self.cpu.setIrqLine(self.scpu.irq_flag or cart.sa1CpuIrqPending() or cart.cx4CpuIrqPending());
        var mmio = SystemMmio{ .display = &self.ppu, .audio = &self.smp };
        var port = scpu.TimedPortWithDevice(*SystemMmio){
            .bus = &self.bus,
            .cartridge = cart,
            .scpu = &self.scpu,
            .clock = &self.clock,
            .controllers = &self.controllers,
            .cpu = &self.cpu,
            .device = &mmio,
        };
        const before = self.clock.master_cycles;
        if (port.cpuReady()) {
            if (self.cpu.canFastForwardWaiting() and
                self.scpu.math_operation == .none and
                self.scpu.dma_enable == 0 and self.scpu.hdma_enable == 0)
            {
                _ = port.fastForwardWaiting(maximum_master_cycles);
            } else {
                _ = self.cpu.step(&port) catch return .cpu;
            }
        } else {
            const result = port.serviceDmaStep();
            if (!result.progressed) return .dma_stalled;
        }
        const elapsed = self.clock.master_cycles -% before;
        // S-SMP execution is already synchronized only at complete S-CPU or
        // DMA operations. Accumulating its oscillator phase once for that
        // exact span is arithmetically identical to one division per master
        // clock and removes the dominant product-host hot path.
        _ = self.smp.advanceOscillator(self.clock.profile().master_hz, elapsed);
        if (self.serviceSmp()) return .smp;
        return self.serviceCoprocessors(cart, elapsed);
    }

    fn serviceSmp(self: *Machine) bool {
        if (self.smp.ipl_mode == .semantic and self.smp.semantic_ipl_state != .running) return false;
        while (self.smp.cycles < self.smp.oscillator_ticks) self.smp.step() catch return true;
        return false;
    }

    fn serviceCoprocessors(self: *Machine, cart: *cartridge.Cartridge, elapsed: u64) ?RunFault {
        const work: usize = @intCast(@min(elapsed, 4_096));
        switch (cart.board.capability.enhancement) {
            .super_fx => {
                const result = cart.runSuperFxSlice(@max(@as(usize, 1), work / 2)) orelse return null;
                if (result.state == .fault) return .super_fx;
            },
            .sa1 => {
                const result = cart.runSa1UntilMasterClock(self.clock.master_cycles, 8_192) orelse return null;
                if (result.state == .fault) return .sa1;
            },
            .cx4 => {
                const device = if (cart.cx4_device) |*value| value else return null;
                const result = device.runUntilCycle(cart.rom_storage, cart.sram_storage, self.clock.master_cycles);
                if (result.fault != null) return .cx4;
            },
            .dsp1_family, .st010_st011 => {
                // uPD77C25/96050 clocks are below the S-CPU master clock. A
                // waiting command returns immediately, while active firmware
                // receives a deterministic proportional instruction budget.
                _ = cart.runNecDspSlice(@max(@as(usize, 1), work / 3));
            },
            .st018 => {
                // ST018's 21.44-MHz source is effectively one step per SNES
                // master clock for this bounded cooperative integration.
                _ = cart.runSt018Slice(@max(@as(usize, 1), work));
            },
            else => {},
        }
        return null;
    }

    fn advanceRtc(self: *Machine, cart: *cartridge.Cartridge, elapsed: u64) void {
        self.rtc_master_phase +|= elapsed;
        const hz = self.clock.profile().master_hz;
        if (self.rtc_master_phase < hz) return;
        const seconds = self.rtc_master_phase / hz;
        self.rtc_master_phase %= hz;
        if (cart.srtc_device) |*device| device.advanceSeconds(seconds);
        if (cart.spc7110_device) |*device| if (device.has_rtc) device.advanceRtcSeconds(seconds);
    }
};
