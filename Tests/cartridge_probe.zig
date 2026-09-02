const std = @import("std");
const core = @import("core");

const default_guest_seconds: u64 = 5;
const host_step_ns: u64 = 10 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES cartridge probe FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 4) return error.BadArguments;
    const guest_seconds = if (args.len >= 3)
        try std.fmt.parseInt(u64, args[2], 10)
    else
        default_guest_seconds;
    if (guest_seconds == 0 or guest_seconds > 300) return error.InvalidGuestDuration;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(core.cartridge.maximum_source_size + 1),
    );
    defer allocator.free(bytes);
    if (bytes.len > core.cartridge.maximum_source_size) return error.CartridgeTooLarge;

    const exact_ipl: ?[]u8 = if (args.len == 4)
        try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], allocator, .limited(core.smp.exact_ipl_size + 1))
    else
        null;
    defer if (exact_ipl) |firmware| allocator.free(firmware);
    if (exact_ipl) |firmware| if (firmware.len != core.smp.exact_ipl_size)
        return error.InvalidIplSize;

    var cart = try core.cartridge.Cartridge.parse(allocator, bytes);
    defer cart.deinit();
    var machine = try core.machine.Machine.power(1, &cart, exact_ipl);
    defer machine.close();
    machine.smp.dsp.beginCapture();

    std.debug.print(
        "R4SNES cartridge probe: bytes={d} mapping={s} region={s} enhancement={s} sram={d} ipl={s} reset=0x{x:0>4} opcode=0x{x:0>2}\n",
        .{
            cart.rom_storage.len,
            @tagName(cart.board.mapping),
            @tagName(cart.board.region),
            @tagName(cart.board.capability.enhancement),
            cart.sram_storage.len,
            if (exact_ipl == null) "semantic" else "exact-user-supplied",
            cart.header.reset_vector,
            cart.header.startup_opcode,
        },
    );

    _ = machine.runHostSlice(&cart, core.timing.maximum_host_slice_master_cycles, 0);
    const started = std.Io.Clock.awake.now(init.io);
    var guest_ns: u64 = 0;
    var next_report_ns: u64 = std.time.ns_per_s;
    const end_ns = guest_seconds * std.time.ns_per_s;
    var last_upload_destination = machine.smp.semantic_destination;
    var last_upload_received = machine.smp.semantic_received;
    var pcm: [core.sdsp.maximum_render_frames * core.sdsp.sample_bytes]u8 = undefined;
    var nonzero_audio_bytes: u64 = 0;
    while (guest_ns < end_ns) {
        guest_ns = @min(guest_ns + host_step_ns, end_ns);
        while (true) {
            const result = machine.runHostSlice(
                &cart,
                256,
                guest_ns,
            );
            if (result.fault) |fault| {
                report(&machine, guest_ns, nonzero_audio_bytes);
                std.debug.print(
                    "R4SNES cartridge probe: machine_fault={s} smp_fault={?s} upload_destination=0x{x:0>4} upload_received={d} upload_counter=0x{x:0>2}\n",
                    .{
                        @tagName(fault),
                        if (machine.smp.fault) |smp_fault| @tagName(smp_fault) else null,
                        machine.smp.semantic_destination,
                        machine.smp.semantic_received,
                        machine.smp.semantic_counter,
                    },
                );
                return error.MachineFault;
            }
            if (machine.smp.ipl_mode == .semantic and
                (machine.smp.semantic_destination != last_upload_destination or
                    machine.smp.semantic_received < last_upload_received))
            {
                std.debug.print(
                    "R4SNES cartridge probe: semantic block destination=0x{x:0>4} received={d} counter=0x{x:0>2} state={s}\n",
                    .{
                        machine.smp.semantic_destination,
                        machine.smp.semantic_received,
                        machine.smp.semantic_counter,
                        @tagName(machine.smp.semantic_ipl_state),
                    },
                );
            }
            last_upload_destination = machine.smp.semantic_destination;
            last_upload_received = machine.smp.semantic_received;
            if (machine.host_budget.pending_master_cycles == 0) break;
        }
        const queued = @min(machine.smp.dsp.queuedFrames(), core.sdsp.maximum_render_frames);
        if (queued != 0) {
            const byte_count = queued * core.sdsp.sample_bytes;
            const rendered = machine.smp.dsp.renderPcm(pcm[0..byte_count]);
            if (rendered < 0 or rendered != byte_count) return error.PcmDrainFailed;
            for (pcm[0..byte_count]) |byte| if (byte != 0) {
                nonzero_audio_bytes +%= 1;
            };
        }
        if (guest_ns >= next_report_ns or guest_ns == end_ns) {
            report(&machine, guest_ns, nonzero_audio_bytes);
            next_report_ns +|= std.time.ns_per_s;
        }
    }
    const ended = std.Io.Clock.awake.now(init.io);
    const elapsed_ns: u64 = @intCast(@max(ended.nanoseconds - started.nanoseconds, 0));
    std.debug.print(
        "R4SNES cartridge probe PASS: guest_seconds={d} wall_ns={d} master_cycles={d} instructions={d} ppu_frames={d} smp_cycles={d} nonzero_audio_bytes={d}\n",
        .{ guest_seconds, elapsed_ns, machine.clock.master_cycles, machine.cpu.instructions, machine.ppu.frame_generation, machine.smp.cycles, nonzero_audio_bytes },
    );
}

fn report(machine: *const core.machine.Machine, guest_ns: u64, nonzero_audio_bytes: u64) void {
    const pixels = @as(usize, machine.ppu.published_width) * machine.ppu.published_height;
    var visible_pixels: usize = 0;
    for (machine.ppu.published_frame[0..pixels]) |pixel| {
        if (pixel != 0xff000000) visible_pixels += 1;
    }
    const dsp = &machine.smp.dsp;
    std.debug.print(
        "t={d}ms clock={d} beam={d}:{d}:{d} cpu={x:0>2}:{x:0>4} op_at={x:0>6} ins={d} p=0x{x:0>2} a=0x{x:0>4} x=0x{x:0>4} y=0x{x:0>4} s=0x{x:0>4} wait={} stop={} nmi={} irq={} dma=0x{x:0>2}/0x{x:0>2}\n",
        .{
            guest_ns / std.time.ns_per_ms,
            machine.clock.master_cycles,
            machine.clock.frame,
            machine.clock.v_counter,
            machine.clock.h_counter,
            machine.cpu.pb,
            machine.cpu.pc,
            machine.cpu.instruction_address,
            machine.cpu.instructions,
            machine.cpu.p.byte(),
            machine.cpu.a,
            machine.cpu.x,
            machine.cpu.y,
            machine.cpu.s,
            machine.cpu.waiting,
            machine.cpu.stopped,
            machine.scpu.nmi_enabled,
            machine.scpu.irq_flag,
            machine.scpu.dma_enable,
            machine.scpu.hdma_enable,
        },
    );
    std.debug.print(
        "  ppu_frames={d} geom={d}x{d} digest=0x{x:0>16} visible_pixels={d} blank={} brightness={d} mode={d} main=0x{x} sub=0x{x} cgram0=0x{x:0>2}{x:0>2}\n",
        .{
            machine.ppu.frame_generation,
            machine.ppu.published_width,
            machine.ppu.published_height,
            machine.ppu.frame_digest,
            visible_pixels,
            machine.ppu.forced_blank,
            machine.ppu.brightness,
            machine.ppu.mode,
            machine.ppu.main_enable,
            machine.ppu.sub_enable,
            machine.ppu.cgram[1],
            machine.ppu.cgram[0],
        },
    );
    std.debug.print(
        "  smp={s}/{s} pc=0x{x:0>4} a=0x{x:0>2} x=0x{x:0>2} y=0x{x:0>2} sp=0x{x:0>2} psw=0x{x:0>2} cycles={d}/{d} ports_cpu={x:0>2},{x:0>2},{x:0>2},{x:0>2} ports_smp={x:0>2},{x:0>2},{x:0>2},{x:0>2} dsp_samples={d} rendered={d} dropped={d} silence={d} nonzero_bytes={d} queued={d} last={d},{d} muted={} reset={} kon=0x{x:0>2} flg=0x{x:0>2}\n",
        .{
            @tagName(machine.smp.ipl_mode),
            @tagName(machine.smp.semantic_ipl_state),
            machine.smp.pc,
            machine.smp.a,
            machine.smp.x,
            machine.smp.y,
            machine.smp.sp,
            machine.smp.psw,
            machine.smp.cycles,
            machine.smp.oscillator_ticks,
            machine.smp.io.cpu_to_smp[0],
            machine.smp.io.cpu_to_smp[1],
            machine.smp.io.cpu_to_smp[2],
            machine.smp.io.cpu_to_smp[3],
            machine.smp.io.smp_to_cpu[0],
            machine.smp.io.smp_to_cpu[1],
            machine.smp.io.smp_to_cpu[2],
            machine.smp.io.smp_to_cpu[3],
            dsp.sample_counter,
            dsp.stats.frames_rendered,
            dsp.stats.frames_dropped,
            dsp.stats.silence_frames,
            nonzero_audio_bytes,
            dsp.queuedFrames(),
            dsp.last_native[0],
            dsp.last_native[1],
            dsp.muted,
            dsp.soft_reset,
            dsp.registers[0x4c],
            dsp.registers[0x6c],
        },
    );
}
