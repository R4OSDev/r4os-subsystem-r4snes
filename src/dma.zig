pub const channel_count: usize = 8;
pub const trace_capacity: usize = 256;

pub const transfer_lengths = [_]u3{ 1, 2, 2, 4, 4, 4, 2, 4 };
pub const transfer_offsets = [8][4]u2{
    .{ 0, 0, 0, 0 },
    .{ 0, 1, 0, 1 },
    .{ 0, 0, 0, 0 },
    .{ 0, 0, 1, 1 },
    .{ 0, 1, 2, 3 },
    .{ 0, 1, 0, 1 },
    .{ 0, 0, 0, 0 },
    .{ 0, 0, 1, 1 },
};

pub const Revision = enum {
    s_cpu_a,
    s_cpu_b,
};

pub const Glitch = enum {
    hdma_2100_then_manual_dma,
    b_bus_21ff_wrap,
    dmap_write_during_transfer,
};

pub const GlitchDisposition = enum {
    exact,
    diagnostic_only,
    absent,
};

pub fn glitchDisposition(revision: Revision, glitch: Glitch) GlitchDisposition {
    return switch (glitch) {
        .hdma_2100_then_manual_dma => if (revision == .s_cpu_a) .diagnostic_only else .absent,
        .b_bus_21ff_wrap => .exact,
        .dmap_write_during_transfer => .exact,
    };
}

pub const Channel = struct {
    control: u8 = 0xff,
    b_address: u8 = 0xff,
    a_address: u16 = 0xffff,
    a_bank: u8 = 0xff,
    transfer_size: u16 = 0xffff,
    indirect_bank: u8 = 0xff,
    hdma_table_address: u16 = 0xffff,
    line_counter: u8 = 0xff,
    unused: u8 = 0xff,
    dma_active: bool = false,
    hdma_completed: bool = false,
    hdma_do_transfer: bool = false,

    pub fn directionBtoA(self: *const Channel) bool {
        return (self.control & 0x80) != 0;
    }

    pub fn indirect(self: *const Channel) bool {
        return (self.control & 0x40) != 0;
    }

    pub fn decrement(self: *const Channel) bool {
        return (self.control & 0x10) != 0;
    }

    pub fn fixed(self: *const Channel) bool {
        return (self.control & 0x08) != 0;
    }

    pub fn mode(self: *const Channel) u3 {
        return @truncate(self.control);
    }

    pub fn bBusAddress(self: *const Channel, byte_index: u3) u16 {
        const offset = transfer_offsets[self.mode()][byte_index & 3];
        return 0x2100 | @as(u16, self.b_address +% @as(u8, offset));
    }
};

pub const Phase = enum {
    idle,
    manual_delay,
    manual_sync,
    manual_global,
    manual_channel_overhead,
    manual_byte,
    manual_end,
    hdma_init_sync,
    hdma_init_global,
    hdma_init_line,
    hdma_init_indirect_low,
    hdma_init_indirect_high,
    hdma_init_end,
    hdma_run_sync,
    hdma_run_global,
    hdma_run_transfer,
    hdma_run_reload,
    hdma_run_indirect_low,
    hdma_run_indirect_high,
    hdma_run_end,
};

pub const TraceKind = enum {
    synchronization,
    overhead,
    transfer,
    table_read,
    conflict,
    completion,
};

pub const TraceEntry = struct {
    kind: TraceKind,
    phase: Phase,
    channel: u8 = 0xff,
    a_address: u32 = 0,
    b_address: u16 = 0,
    value: u8 = 0,
    valid: bool = true,
    master_cycles: u8 = 0,
};

pub const TransferResult = struct {
    a_address: u32,
    b_address: u16,
    value: u8,
    valid: bool,
    conflict: bool = false,
    master_cycles: u8,
};

pub const ReadResult = struct {
    address: u32,
    value: u8,
    valid: bool,
    master_cycles: u8,
};

pub const StepResult = struct {
    phase: Phase,
    progressed: bool,
    transferred: bool = false,
    master_cycles: u8 = 0,
    completed: bool = false,
};

pub const Controller = struct {
    channels: [channel_count]Channel = [_]Channel{.{}} ** channel_count,
    revision: Revision = .s_cpu_b,
    hdma_enabled: u8 = 0,
    phase: Phase = .idle,
    suspended_manual_phase: Phase = .idle,
    active_channel: u4 = 8,
    transfer_index: u3 = 0,
    hdma_cursor: u4 = 0,
    hdma_init_pending: bool = false,
    hdma_run_pending: bool = false,
    hdma_needs_sync: bool = false,
    resume_cpu_master_cycles: u8 = 6,
    dma_clock_counter: u64 = 0,
    manual_bytes: u64 = 0,
    hdma_bytes: u64 = 0,
    aborted_bytes: u64 = 0,
    trace: [trace_capacity]TraceEntry = undefined,
    trace_len: u16 = 0,
    trace_overflow: u64 = 0,

    pub fn reset(self: *Controller) void {
        const revision = self.revision;
        self.* = .{ .revision = revision };
    }

    pub fn busy(self: *const Controller) bool {
        return self.phase != .idle or self.hdma_init_pending or self.hdma_run_pending;
    }

    pub fn cpuMayRun(self: *const Controller) bool {
        return !self.busy();
    }

    pub fn lastTrace(self: *const Controller) []const TraceEntry {
        return self.trace[0..self.trace_len];
    }

    pub fn clearTrace(self: *Controller) void {
        self.trace_len = 0;
        self.trace_overflow = 0;
    }

    pub fn requestManual(self: *Controller, mask: u8, resume_cpu_master_cycles: u8) void {
        for (0..channel_count) |index| {
            if ((mask & (@as(u8, 1) << @as(u3, @intCast(index)))) != 0) self.channels[index].dma_active = true;
        }
        if (mask == 0) return;
        self.resume_cpu_master_cycles = switch (resume_cpu_master_cycles) {
            6, 8, 12 => resume_cpu_master_cycles,
            else => 6,
        };
        if (self.phase == .idle) {
            self.dma_clock_counter = 0;
            self.phase = .manual_delay;
        }
    }

    pub fn setHdmaEnabled(self: *Controller, mask: u8) void {
        self.hdma_enabled = mask;
    }

    pub fn beginFrame(self: *Controller) void {
        if (self.hdma_enabled == 0) {
            for (&self.channels) |*channel| {
                channel.hdma_completed = false;
                channel.hdma_do_transfer = false;
            }
            return;
        }
        self.hdma_init_pending = true;
    }

    pub fn beginHblank(self: *Controller) void {
        if (self.hdma_enabled != 0) self.hdma_run_pending = true;
    }

    pub fn abortAll(self: *Controller) void {
        for (&self.channels) |*channel| {
            if (channel.dma_active) self.aborted_bytes +%= if (channel.transfer_size == 0) 65_536 else channel.transfer_size;
            channel.dma_active = false;
        }
        self.phase = .idle;
        self.suspended_manual_phase = .idle;
        self.hdma_init_pending = false;
        self.hdma_run_pending = false;
    }

    pub fn readRegister(self: *const Controller, offset: u16, open_bus: u8) ?u8 {
        if (offset < 0x4300 or offset > 0x437f) return null;
        const channel = &self.channels[(offset >> 4) & 7];
        return switch (offset & 0x0f) {
            0x0 => channel.control,
            0x1 => channel.b_address,
            0x2 => @truncate(channel.a_address),
            0x3 => @truncate(channel.a_address >> 8),
            0x4 => channel.a_bank,
            0x5 => @truncate(channel.transfer_size),
            0x6 => @truncate(channel.transfer_size >> 8),
            0x7 => channel.indirect_bank,
            0x8 => @truncate(channel.hdma_table_address),
            0x9 => @truncate(channel.hdma_table_address >> 8),
            0xa => channel.line_counter,
            0xb, 0xf => channel.unused,
            else => open_bus,
        };
    }

    pub fn writeRegister(self: *Controller, offset: u16, value: u8) bool {
        if (offset < 0x4300 or offset > 0x437f) return false;
        const channel = &self.channels[(offset >> 4) & 7];
        switch (offset & 0x0f) {
            0x0 => channel.control = value,
            0x1 => channel.b_address = value,
            0x2 => channel.a_address = (channel.a_address & 0xff00) | value,
            0x3 => channel.a_address = (channel.a_address & 0x00ff) | (@as(u16, value) << 8),
            0x4 => channel.a_bank = value,
            0x5 => channel.transfer_size = (channel.transfer_size & 0xff00) | value,
            0x6 => channel.transfer_size = (channel.transfer_size & 0x00ff) | (@as(u16, value) << 8),
            0x7 => channel.indirect_bank = value,
            0x8 => channel.hdma_table_address = (channel.hdma_table_address & 0xff00) | value,
            0x9 => channel.hdma_table_address = (channel.hdma_table_address & 0x00ff) | (@as(u16, value) << 8),
            0xa => channel.line_counter = value,
            0xb, 0xf => channel.unused = value,
            else => {},
        }
        return true;
    }

    /// Execute at most one synchronization, overhead, table-read or transfer
    /// micro-operation.  Thus the host can stop after every DMA byte without
    /// exposing a half-written bus transaction.
    pub fn step(self: *Controller, port: anytype) StepResult {
        self.prioritizeHdma();
        const before = self.phase;
        return switch (self.phase) {
            .idle => .{ .phase = .idle, .progressed = false, .completed = true },
            .manual_delay => self.transition(.manual_sync),
            .manual_sync => self.advanceState(port, 8 - @as(u8, @intCast(port.masterClock() & 7)), .manual_global, .synchronization),
            .manual_global => self.advanceState(port, 8, .manual_channel_overhead, .overhead),
            .manual_channel_overhead => self.manualChannelOverhead(port),
            .manual_byte => self.manualByte(port),
            .manual_end => self.finishManual(port),
            .hdma_init_sync => self.advanceState(port, 8 - @as(u8, @intCast(port.masterClock() & 7)), .hdma_init_global, .synchronization),
            .hdma_init_global => self.hdmaInitGlobal(port),
            .hdma_init_line => self.hdmaInitLine(port),
            .hdma_init_indirect_low => self.hdmaInitIndirectLow(port),
            .hdma_init_indirect_high => self.hdmaInitIndirectHigh(port),
            .hdma_init_end => self.finishHdma(port, before),
            .hdma_run_sync => self.advanceState(port, 8 - @as(u8, @intCast(port.masterClock() & 7)), .hdma_run_global, .synchronization),
            .hdma_run_global => self.hdmaRunGlobal(port),
            .hdma_run_transfer => self.hdmaRunTransfer(port),
            .hdma_run_reload => self.hdmaRunReload(port),
            .hdma_run_indirect_low => self.hdmaRunIndirectLow(port),
            .hdma_run_indirect_high => self.hdmaRunIndirectHigh(port),
            .hdma_run_end => self.finishHdma(port, before),
        };
    }

    fn transition(self: *Controller, next: Phase) StepResult {
        self.phase = next;
        return .{ .phase = next, .progressed = true };
    }

    fn advanceState(self: *Controller, port: anytype, clocks: u8, next: Phase, kind: TraceKind) StepResult {
        const elapsed = port.advanceDma(clocks);
        self.dma_clock_counter +%= elapsed;
        self.append(.{ .kind = kind, .phase = self.phase, .master_cycles = elapsed });
        self.phase = next;
        return .{ .phase = next, .progressed = true, .master_cycles = elapsed };
    }

    fn manualChannelOverhead(self: *Controller, port: anytype) StepResult {
        const next = self.findActiveChannel(0) orelse {
            self.phase = .manual_end;
            return .{ .phase = .manual_end, .progressed = true };
        };
        self.active_channel = next;
        self.transfer_index = 0;
        return self.advanceState(port, 8, .manual_byte, .overhead);
    }

    fn manualByte(self: *Controller, port: anytype) StepResult {
        if (self.active_channel >= channel_count or !self.channels[self.active_channel].dma_active) {
            return self.selectNextManual();
        }
        const index: usize = self.active_channel;
        var channel = &self.channels[index];
        const address = (@as(u32, channel.a_bank) << 16) | channel.a_address;
        const transfer = port.transferByte(channel, self.transfer_index, address, self.revision);
        self.dma_clock_counter +%= transfer.master_cycles;
        self.manual_bytes +%= 1;
        self.appendTransfer(index, transfer, self.phase);
        if (!channel.fixed()) {
            if (channel.decrement()) channel.a_address -%= 1 else channel.a_address +%= 1;
        }
        channel.transfer_size -%= 1;
        self.transfer_index +%= 1;
        if (channel.transfer_size == 0) {
            channel.dma_active = false;
            return self.selectNextManualWithCycles(transfer.master_cycles);
        }
        return .{ .phase = self.phase, .progressed = true, .transferred = true, .master_cycles = transfer.master_cycles };
    }

    fn selectNextManual(self: *Controller) StepResult {
        return self.selectNextManualWithCycles(0);
    }

    fn selectNextManualWithCycles(self: *Controller, clocks: u8) StepResult {
        const start: usize = if (self.active_channel < channel_count) @as(usize, self.active_channel) + 1 else 0;
        if (self.findActiveChannel(start)) |next| {
            self.active_channel = next;
            self.transfer_index = 0;
            self.phase = .manual_channel_overhead;
        } else if (self.findActiveChannel(0)) |next| {
            self.active_channel = next;
            self.transfer_index = 0;
            self.phase = .manual_channel_overhead;
        } else {
            self.active_channel = 8;
            self.phase = .manual_end;
        }
        return .{ .phase = self.phase, .progressed = true, .transferred = clocks != 0, .master_cycles = clocks };
    }

    fn finishManual(self: *Controller, port: anytype) StepResult {
        const speed = self.resume_cpu_master_cycles;
        const remainder: u8 = @intCast(self.dma_clock_counter % speed);
        const clocks = speed - remainder;
        const elapsed = port.advanceDma(clocks);
        self.dma_clock_counter +%= elapsed;
        self.append(.{ .kind = .completion, .phase = self.phase, .master_cycles = elapsed });
        self.phase = .idle;
        return .{ .phase = .idle, .progressed = true, .master_cycles = elapsed, .completed = true };
    }

    fn prioritizeHdma(self: *Controller) void {
        if (!self.hdma_init_pending and !self.hdma_run_pending) return;
        if (isHdmaPhase(self.phase)) return;
        const was_manual = isManualPhase(self.phase);
        if (was_manual) self.suspended_manual_phase = self.phase;
        if (!was_manual) self.dma_clock_counter = 0;
        self.hdma_needs_sync = !was_manual;
        self.hdma_cursor = 0;
        self.transfer_index = 0;
        if (self.hdma_init_pending) {
            self.hdma_init_pending = false;
            for (&self.channels) |*channel| {
                channel.hdma_completed = false;
                channel.hdma_do_transfer = true;
            }
            self.phase = if (self.hdma_needs_sync) .hdma_init_sync else .hdma_init_global;
        } else {
            self.hdma_run_pending = false;
            self.phase = if (self.hdma_needs_sync) .hdma_run_sync else .hdma_run_global;
        }
    }

    fn hdmaInitGlobal(self: *Controller, port: anytype) StepResult {
        const elapsed = port.advanceDma(8);
        self.dma_clock_counter +%= elapsed;
        self.append(.{ .kind = .overhead, .phase = self.phase, .master_cycles = elapsed });
        for (0..channel_count) |index| {
            const channel = &self.channels[index];
            channel.hdma_do_transfer = true;
            if ((self.hdma_enabled & (@as(u8, 1) << @as(u3, @intCast(index)))) != 0) {
                channel.dma_active = false;
                channel.hdma_table_address = channel.a_address;
            }
        }
        self.hdma_cursor = 0;
        self.phase = .hdma_init_line;
        return .{ .phase = self.phase, .progressed = true, .master_cycles = elapsed };
    }

    fn hdmaInitLine(self: *Controller, port: anytype) StepResult {
        const index = self.nextHdmaChannel(self.hdma_cursor, false) orelse {
            self.phase = .hdma_init_end;
            return .{ .phase = self.phase, .progressed = true };
        };
        self.hdma_cursor = index;
        var channel = &self.channels[index];
        const address = (@as(u32, channel.a_bank) << 16) | channel.hdma_table_address;
        const read = port.readDma(address, self.revision);
        self.recordRead(index, read, self.phase);
        channel.line_counter = read.value;
        channel.hdma_table_address +%= 1;
        channel.hdma_completed = read.value == 0;
        channel.hdma_do_transfer = !channel.hdma_completed;
        self.dma_clock_counter +%= read.master_cycles;
        if (channel.indirect()) {
            self.phase = .hdma_init_indirect_low;
        } else {
            self.hdma_cursor += 1;
        }
        return .{ .phase = self.phase, .progressed = true, .master_cycles = read.master_cycles };
    }

    fn hdmaInitIndirectLow(self: *Controller, port: anytype) StepResult {
        var channel = &self.channels[self.hdma_cursor];
        const address = (@as(u32, channel.a_bank) << 16) | channel.hdma_table_address;
        const read = port.readDma(address, self.revision);
        self.recordRead(self.hdma_cursor, read, self.phase);
        self.dma_clock_counter +%= read.master_cycles;
        channel.hdma_table_address +%= 1;
        if (channel.hdma_completed) {
            channel.transfer_size = @as(u16, read.value) << 8;
            self.hdma_cursor += 1;
            self.phase = .hdma_init_line;
        } else {
            channel.transfer_size = read.value;
            self.phase = .hdma_init_indirect_high;
        }
        return .{ .phase = self.phase, .progressed = true, .master_cycles = read.master_cycles };
    }

    fn hdmaInitIndirectHigh(self: *Controller, port: anytype) StepResult {
        var channel = &self.channels[self.hdma_cursor];
        const address = (@as(u32, channel.a_bank) << 16) | channel.hdma_table_address;
        const read = port.readDma(address, self.revision);
        self.recordRead(self.hdma_cursor, read, self.phase);
        self.dma_clock_counter +%= read.master_cycles;
        channel.hdma_table_address +%= 1;
        channel.transfer_size = (channel.transfer_size & 0x00ff) | (@as(u16, read.value) << 8);
        self.hdma_cursor += 1;
        self.phase = .hdma_init_line;
        return .{ .phase = self.phase, .progressed = true, .master_cycles = read.master_cycles };
    }

    fn hdmaRunGlobal(self: *Controller, port: anytype) StepResult {
        const elapsed = port.advanceDma(8);
        self.dma_clock_counter +%= elapsed;
        self.append(.{ .kind = .overhead, .phase = self.phase, .master_cycles = elapsed });
        self.hdma_cursor = 0;
        self.transfer_index = 0;
        self.phase = .hdma_run_transfer;
        return .{ .phase = self.phase, .progressed = true, .master_cycles = elapsed };
    }

    fn hdmaRunTransfer(self: *Controller, port: anytype) StepResult {
        const index = self.nextHdmaChannel(self.hdma_cursor, true) orelse {
            self.hdma_cursor = 0;
            self.phase = .hdma_run_reload;
            return .{ .phase = self.phase, .progressed = true };
        };
        self.hdma_cursor = index;
        var channel = &self.channels[index];
        channel.dma_active = false;
        if (!channel.hdma_do_transfer) {
            self.hdma_cursor += 1;
            self.transfer_index = 0;
            return .{ .phase = self.phase, .progressed = true };
        }
        const address = if (channel.indirect())
            (@as(u32, channel.indirect_bank) << 16) | channel.transfer_size
        else
            (@as(u32, channel.a_bank) << 16) | channel.hdma_table_address;
        const transfer = port.transferByte(channel, self.transfer_index, address, self.revision);
        self.recordHdmaTransfer(index, transfer);
        if (channel.indirect()) channel.transfer_size +%= 1 else channel.hdma_table_address +%= 1;
        self.transfer_index += 1;
        if (self.transfer_index >= transfer_lengths[channel.mode()]) {
            self.transfer_index = 0;
            self.hdma_cursor += 1;
        }
        return .{ .phase = self.phase, .progressed = true, .transferred = true, .master_cycles = transfer.master_cycles };
    }

    fn hdmaRunReload(self: *Controller, port: anytype) StepResult {
        const index = self.nextHdmaChannel(self.hdma_cursor, true) orelse {
            self.phase = .hdma_run_end;
            return .{ .phase = self.phase, .progressed = true };
        };
        self.hdma_cursor = index;
        var channel = &self.channels[index];
        channel.line_counter -%= 1;
        channel.hdma_do_transfer = (channel.line_counter & 0x80) != 0;
        const address = (@as(u32, channel.a_bank) << 16) | channel.hdma_table_address;
        const read = port.readDma(address, self.revision);
        self.recordRead(index, read, self.phase);
        self.dma_clock_counter +%= read.master_cycles;
        if ((channel.line_counter & 0x7f) == 0) {
            channel.line_counter = read.value;
            channel.hdma_table_address +%= 1;
            channel.hdma_completed = read.value == 0;
            channel.hdma_do_transfer = true;
            if (channel.indirect()) {
                self.phase = .hdma_run_indirect_low;
            } else {
                self.hdma_cursor += 1;
            }
        } else {
            self.hdma_cursor += 1;
        }
        return .{ .phase = self.phase, .progressed = true, .master_cycles = read.master_cycles };
    }

    fn hdmaRunIndirectLow(self: *Controller, port: anytype) StepResult {
        var channel = &self.channels[self.hdma_cursor];
        const address = (@as(u32, channel.a_bank) << 16) | channel.hdma_table_address;
        const read = port.readDma(address, self.revision);
        self.recordRead(self.hdma_cursor, read, self.phase);
        self.dma_clock_counter +%= read.master_cycles;
        channel.hdma_table_address +%= 1;
        if (channel.hdma_completed and self.isLastActiveHdma(self.hdma_cursor)) {
            channel.transfer_size = @as(u16, read.value) << 8;
            self.hdma_cursor += 1;
            self.phase = .hdma_run_reload;
        } else {
            channel.transfer_size = read.value;
            self.phase = .hdma_run_indirect_high;
        }
        return .{ .phase = self.phase, .progressed = true, .master_cycles = read.master_cycles };
    }

    fn hdmaRunIndirectHigh(self: *Controller, port: anytype) StepResult {
        var channel = &self.channels[self.hdma_cursor];
        const address = (@as(u32, channel.a_bank) << 16) | channel.hdma_table_address;
        const read = port.readDma(address, self.revision);
        self.recordRead(self.hdma_cursor, read, self.phase);
        self.dma_clock_counter +%= read.master_cycles;
        channel.hdma_table_address +%= 1;
        channel.transfer_size = (channel.transfer_size & 0x00ff) | (@as(u16, read.value) << 8);
        self.hdma_cursor += 1;
        self.phase = .hdma_run_reload;
        return .{ .phase = self.phase, .progressed = true, .master_cycles = read.master_cycles };
    }

    fn finishHdma(self: *Controller, port: anytype, completed_phase: Phase) StepResult {
        var elapsed: u8 = 0;
        if (self.hdma_needs_sync) {
            const speed = self.resume_cpu_master_cycles;
            const remainder: u8 = @intCast(self.dma_clock_counter % speed);
            elapsed = port.advanceDma(speed - remainder);
            self.dma_clock_counter +%= elapsed;
        }
        self.append(.{ .kind = .completion, .phase = completed_phase, .master_cycles = elapsed });
        if (self.suspended_manual_phase != .idle and self.anyManualActive()) {
            self.phase = self.suspended_manual_phase;
        } else if (self.anyManualActive()) {
            self.phase = .manual_channel_overhead;
        } else {
            self.phase = .idle;
        }
        self.suspended_manual_phase = .idle;
        return .{ .phase = self.phase, .progressed = true, .master_cycles = elapsed, .completed = self.phase == .idle };
    }

    fn findActiveChannel(self: *const Controller, start: usize) ?u4 {
        var index = start;
        while (index < channel_count) : (index += 1) {
            if (self.channels[index].dma_active) return @intCast(index);
        }
        return null;
    }

    fn nextHdmaChannel(self: *const Controller, start: u4, active_only: bool) ?u4 {
        var index: usize = start;
        while (index < channel_count) : (index += 1) {
            if ((self.hdma_enabled & (@as(u8, 1) << @as(u3, @intCast(index)))) == 0) continue;
            if (active_only and self.channels[index].hdma_completed) continue;
            return @intCast(index);
        }
        return null;
    }

    fn isLastActiveHdma(self: *const Controller, current: u4) bool {
        var index: usize = @as(usize, current) + 1;
        while (index < channel_count) : (index += 1) {
            if ((self.hdma_enabled & (@as(u8, 1) << @as(u3, @intCast(index)))) != 0 and !self.channels[index].hdma_completed) return false;
        }
        return true;
    }

    fn anyManualActive(self: *const Controller) bool {
        for (self.channels) |channel| if (channel.dma_active) return true;
        return false;
    }

    fn recordRead(self: *Controller, channel: usize, read: ReadResult, phase: Phase) void {
        self.append(.{
            .kind = .table_read,
            .phase = phase,
            .channel = @intCast(channel),
            .a_address = read.address,
            .value = read.value,
            .valid = read.valid,
            .master_cycles = read.master_cycles,
        });
    }

    fn appendTransfer(self: *Controller, channel: usize, transfer: TransferResult, phase: Phase) void {
        self.append(.{
            .kind = if (transfer.conflict) .conflict else .transfer,
            .phase = phase,
            .channel = @intCast(channel),
            .a_address = transfer.a_address,
            .b_address = transfer.b_address,
            .value = transfer.value,
            .valid = transfer.valid,
            .master_cycles = transfer.master_cycles,
        });
    }

    fn recordHdmaTransfer(self: *Controller, channel: usize, transfer: TransferResult) void {
        self.dma_clock_counter +%= transfer.master_cycles;
        self.hdma_bytes +%= 1;
        self.appendTransfer(channel, transfer, self.phase);
    }

    fn append(self: *Controller, entry: TraceEntry) void {
        if (self.trace_len < trace_capacity) {
            self.trace[self.trace_len] = entry;
            self.trace_len += 1;
        } else {
            self.trace_overflow +%= 1;
        }
    }
};

pub fn validAAddress(address: u32) bool {
    const canonical = address & 0x00ff_ffff;
    if ((canonical & 0x40ff00) == 0x002100) return false;
    if ((canonical & 0x40fe00) == 0x004000) return false;
    if ((canonical & 0x40ffe0) == 0x004200) return false;
    if ((canonical & 0x40ff80) == 0x004300) return false;
    return true;
}

pub fn isWorkRamAddress(address: u32) bool {
    const canonical = address & 0x00ff_ffff;
    const bank: u8 = @truncate(canonical >> 16);
    const offset: u16 = @truncate(canonical);
    if (bank == 0x7e or bank == 0x7f) return true;
    return (bank <= 0x3f or (bank >= 0x80 and bank <= 0xbf)) and offset < 0x2000;
}

fn isManualPhase(phase: Phase) bool {
    return switch (phase) {
        .manual_delay, .manual_sync, .manual_global, .manual_channel_overhead, .manual_byte, .manual_end => true,
        else => false,
    };
}

fn isHdmaPhase(phase: Phase) bool {
    return switch (phase) {
        .hdma_init_sync,
        .hdma_init_global,
        .hdma_init_line,
        .hdma_init_indirect_low,
        .hdma_init_indirect_high,
        .hdma_init_end,
        .hdma_run_sync,
        .hdma_run_global,
        .hdma_run_transfer,
        .hdma_run_reload,
        .hdma_run_indirect_low,
        .hdma_run_indirect_high,
        .hdma_run_end,
        => true,
        else => false,
    };
}
