const std = @import("std");
const r4os = @import("r4os");
const core = @import("core.zig");

const host_api = r4os.subsystem_host;
const product_host = core.product_host;
const runtime_api = r4os.subsystem_runtime;

comptime {
    const bindings = core.host_adapter.bindings;
    if (bindings.len != 12 or
        bindings[0].usage != r4os.abi.physical_key_usage_up or
        bindings[1].usage != r4os.abi.physical_key_usage_down or
        bindings[2].usage != r4os.abi.physical_key_usage_left or
        bindings[3].usage != r4os.abi.physical_key_usage_right or
        bindings[4].usage != r4os.abi.physical_key_usage_enter or
        bindings[5].usage != r4os.abi.physical_key_usage_right_control or
        bindings[6].usage != r4os.abi.physical_key_usage_keypad_8 or
        bindings[7].usage != r4os.abi.physical_key_usage_keypad_6 or
        bindings[8].usage != r4os.abi.physical_key_usage_keypad_2 or
        bindings[9].usage != r4os.abi.physical_key_usage_keypad_4 or
        bindings[10].usage != r4os.abi.physical_key_usage_keypad_7 or
        bindings[11].usage != r4os.abi.physical_key_usage_keypad_9)
    {
        @compileError("R4SNES physical input mapping drifted from the public R4DESK HID contract");
    }
}

const error_profile: i32 = 64;
const error_launch: i32 = 65;
const error_path: i32 = 66;
const error_missing: i32 = 67;
const error_directory: i32 = 68;
const error_size: i32 = 69;
const error_metadata: i32 = 70;
const error_cartridge: i32 = 71;
const error_not_implemented: i32 = 72;
const error_allocator: i32 = 73;
const error_firmware: i32 = 74;
const error_persistence_selftest: i32 = 75;
const error_save_busy: i32 = 76;
const error_save_open: i32 = 77;
const error_save_close: i32 = 78;
const error_host_video: i32 = 79;
const error_runtime: i32 = 80;
const error_host_selftest: i32 = 96;
const error_e2e_trace: i32 = 97;
const e2e_guest_duration_ns: u64 = 60 * std.time.ns_per_s;
const audio_service_timeout_ns: u64 = 50 * std.time.ns_per_ms;
const audio_close_timeout_ns: u64 = 500 * std.time.ns_per_ms;
const product_audio_target_quanta: u16 = 2;
const product_audio_max_catchup_quanta: u16 = 16;
const host_selftest_marker_path = "C:\\TEMP\\R4SNES.HOST";
const host_selftest_marker = "R4SNES fixture generation: OK origin=R4OS-original formats=.sfc+.smc cases=rom-only+battery-rtc+invalid+firmware-required private-rom=excluded\r\n";
const e2e_fixture_a_path = "C:\\TEMP\\R4SNES-E2E-A.SFC";
const e2e_fixture_b_path = "C:\\TEMP\\R4SNES-E2E-B.SMC";
const e2e_fixture_invalid_path = "C:\\TEMP\\R4SNES-INVALID.SFC";
const e2e_fixture_firmware_path = "C:\\TEMP\\R4SNES-DSP-REQUIRED.SFC";
const e2e_end_key = "end";

pub fn r4_app_main(app: *r4os.App) i32 {
    if (std.mem.indexOf(u8, app.args(), "/PERSISTTEST") != null) return persistenceSelfTest(app);
    if (std.mem.indexOf(u8, app.args(), "/HOSTTEST") != null) return hostSelfTest(app);
    if (std.ascii.eqlIgnoreCase(app.args(), "/SELFTEST")) return selfTest(app);
    return runProduct(app);
}

noinline fn runProduct(app: *r4os.App) i32 {
    if (app.profile != .desktop) return error_profile;
    const sys = app.system();
    const allocator = app.allocator() orelse return error_allocator;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const desk = app.desktop() orelse return r4os.abi.err_no_group;
    const draw = app.drawing() orelse return r4os.abi.err_no_group;
    const launch = r4os.subsystem_launch.parse(app.args()) catch |fault| {
        sys.println("R4SNES: invalid R4SUBSYS1 launch request.");
        return showStatus(allocator, sys, desk, draw, "R4SNES - Startfehler", &.{
            "Der R4SUBSYS1-Startdatensatz ist ungueltig oder zu gross.",
            @errorName(fault),
            "Eine SFC-/SMC-Datei muss ueber Explorer oder Open With gestartet werden.",
        }, error_launch);
    };
    const e2e_trace = E2eTrace.parse(launch);
    var path = r4os.AbsoluteFilePath.parse(launch.guest_path) catch {
        sys.println("R4SNES: invalid absolute cartridge path.");
        return showStatus(allocator, sys, desk, draw, "R4SNES - Startfehler", &.{
            "Der uebergebene Cartridge-Pfad ist nicht absolut oder ungueltig.",
            launch.guest_path,
        }, error_path);
    };
    if (!hasCartridgeExtension(launch.guest_path)) {
        return showStatus(allocator, sys, desk, draw, "R4SNES - Formatfehler", &.{
            "R4SNES akzeptiert ueber R4SUBSYS1 ausschliesslich .SFC und .SMC.",
            launch.guest_path,
        }, error_path);
    }
    var source: ?[]u8 = loadCartridgeOwned(allocator, &files, &path) catch |fault| {
        sys.write("R4SNES: cartridge load failed: ");
        sys.println(@errorName(fault));
        return showStatus(allocator, sys, desk, draw, "R4SNES - Ladefehler", &.{
            loadFailureMessage(fault),
            launch.guest_path,
            @errorName(fault),
        }, loadFailureCode(fault));
    };
    defer if (source) |bytes| secureFree(allocator, bytes);

    const requirement = core.cartridge.inspectNecDspRequirement(source.?, null) catch |fault| {
        const code = showStatus(allocator, sys, desk, draw, "R4SNES - Cartridgefehler", &.{
            cartridgeError(fault),
            launch.guest_path,
        }, error_cartridge);
        if (e2e_trace.active) {
            if (e2e_trace.expected_end != .reject_invalid or
                !writeE2eRejection(&sys, e2e_trace, "invalid", fault))
            {
                _ = writeE2eFailure(&sys, e2e_trace, "inspect", fault, "none", 0);
                return error_e2e_trace;
            }
        }
        return code;
    };
    const st018_requirement = core.cartridge.inspectSt018Requirement(source.?) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4SNES - Cartridgefehler", &.{
            cartridgeError(fault),
            launch.guest_path,
        }, error_cartridge);
    };
    var separate_firmware: ?[]u8 = null;
    defer if (separate_firmware) |firmware| secureFree(allocator, firmware);
    if (requirement) |needed| {
        if (needed.appended) {
            const appended = source.?[source.?.len - needed.firmwareBytes() ..];
            _ = core.nec_dsp.validateFirmware(needed.revision, appended, .known_only) catch |fault| {
                printNecDspFirmwareError(sys, needed, fault);
                return showStatus(allocator, sys, desk, draw, "R4SNES - Firmwarefehler", &.{
                    "Die angehaengte NEC-DSP-Firmware ist ungueltig.",
                    needed.fileName(),
                    @errorName(fault),
                }, error_firmware);
            };
        } else {
            separate_firmware = loadExactOwned(allocator, &files, needed.firmwarePath(), needed.firmwareBytes()) catch |fault| {
                printNecDspFirmwareError(sys, needed, fault);
                const code = showStatus(allocator, sys, desk, draw, "R4SNES - Firmwarefehler", &.{
                    "Die benoetigte NEC-DSP-Firmware fehlt oder ist nicht lesbar.",
                    needed.firmwarePath(),
                    @errorName(fault),
                }, error_firmware);
                if (e2e_trace.active) {
                    if (e2e_trace.expected_end != .reject_firmware or
                        !writeE2eRejection(&sys, e2e_trace, "firmware", fault))
                    {
                        _ = writeE2eFailure(&sys, e2e_trace, "firmware", fault, "none", 0);
                        return error_e2e_trace;
                    }
                }
                return code;
            };
            _ = core.nec_dsp.validateFirmware(needed.revision, separate_firmware.?, .known_only) catch |fault| {
                printNecDspFirmwareError(sys, needed, fault);
                return showStatus(allocator, sys, desk, draw, "R4SNES - Firmwarefehler", &.{
                    "Die NEC-DSP-Firmware passt nicht zur erkannten Chiprevision.",
                    needed.fileName(),
                    @errorName(fault),
                }, error_firmware);
            };
        }
    }
    var st018_firmware: ?[]u8 = null;
    defer if (st018_firmware) |firmware| secureFree(allocator, firmware);
    if (st018_requirement) |needed| {
        st018_firmware = loadExactOwned(allocator, &files, needed.firmwarePath(), needed.firmwareBytes()) catch |fault| {
            printSt018FirmwareError(sys, needed, fault);
            return showStatus(allocator, sys, desk, draw, "R4SNES - Firmwarefehler", &.{
                "Die benoetigte ST018-Firmware fehlt oder ist nicht lesbar.",
                needed.firmwarePath(),
                @errorName(fault),
            }, error_firmware);
        };
        _ = core.st018.validateFirmware(st018_firmware.?, .known_only, .separate) catch |fault| {
            printSt018FirmwareError(sys, needed, fault);
            return showStatus(allocator, sys, desk, draw, "R4SNES - Firmwarefehler", &.{
                "Die ST018-Firmware passt nicht zur bekannten Chiprevision.",
                needed.fileName(),
                @errorName(fault),
            }, error_firmware);
        };
    }
    const exact_ipl = loadOptionalIpl(&files) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4SNES - Firmwarefehler", &.{
            "Die optionale SPC700.IPL ist vorhanden, aber nicht exakt 64 Byte lesbar.",
            core.persistence.spc700_ipl_path,
            @errorName(fault),
        }, error_firmware);
    };

    var save_store = core.persistence_r4os.AsyncStore.init(files, allocator);
    const instance_id = sys.ticks() | 1;
    var time_context = ProductTimeContext{ .sys = &sys };
    var guest = product_host.Guest.init(allocator, save_store.backend(), time_context.source(), instance_id);
    defer _ = guest.close();
    const owned_source = product_host.OwnedSource{
        .image = source.?,
        .nec_dsp_revision = if (requirement) |needed| needed.revision else null,
        .nec_dsp_firmware = separate_firmware,
        .st018_firmware = st018_firmware,
        .exact_ipl = exact_ipl,
    };
    source = null;
    separate_firmware = null;
    st018_firmware = null;
    guest.openOwned(owned_source) catch |fault| {
        sys.write("R4SNES: cartridge rejected: ");
        sys.println(@errorName(fault));
        const code = openFailureCode(fault);
        const shown = showStatus(allocator, sys, desk, draw, "R4SNES - Cartridgefehler", &.{
            openFailureMessage(fault),
            launch.guest_path,
            @errorName(fault),
        }, code);
        if (e2e_trace.active) {
            _ = writeE2eFailure(&sys, e2e_trace, "open", fault, save_store.failureStageName(), save_store.failureCode());
            return error_e2e_trace;
        }
        return shown;
    };
    if (e2e_trace.active and (e2e_trace.expected_end == .witness or e2e_trace.expected_end == .close)) {
        guest.setGuestTimeLimit(e2e_guest_duration_ns) catch {
            _ = writeE2eFailure(&sys, e2e_trace, "time-limit", error.InvalidGuestTimeLimit, "none", 0);
            return error_e2e_trace;
        };
    }
    if (e2e_trace.active and e2e_trace.expected_end == .witness) {
        guest.setCompletionWitness(.{
            .wram_index = core.fixture_rom.completion_wram_index,
            .value = core.fixture_rom.completion_witness_value,
        }) catch {
            _ = writeE2eFailure(&sys, e2e_trace, "witness", error.InvalidCompletionWitnessAddress, "none", 0);
            return error_e2e_trace;
        };
    }

    const surface = guest.initialSurface() catch {
        return showStatus(allocator, sys, desk, draw, "R4SNES - Hostfehler", &.{
            "Die native XRGB32-Surface konnte nicht angelegt werden.",
        }, error_host_video);
    };
    var raster_scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window = host_api.Host.init(desk, draw, surface, raster_scratch[0..]) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4SNES - Hostfehler", &.{
            "Der produktive Super-Nintendo-Fensterhost ist nicht verfuegbar.",
            @errorName(fault),
        }, error_host_video);
    };
    window.setInputPolicy(.{ .key_text_mode = .key_and_text, .pointer_mode = .ignored });
    _ = window.setMinimumSize(core.ppu.frame_width, core.ppu.standard_height);
    guest.attachVideo(&window.video) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4SNES - Hostfehler", &.{
            "Die Cartridge-Surface konnte nicht an das Fenster gebunden werden.",
            @errorName(fault),
        }, error_host_video);
    };

    var audio_sink_storage: runtime_api.R4AudioSink = undefined;
    var audio_sink: ?runtime_api.AudioSink = null;
    if (app.audio()) |audio| {
        audio_sink_storage = runtime_api.R4AudioSink.initWithTimeouts(audio, audio_service_timeout_ns, audio_close_timeout_ns);
        audio_sink = audio_sink_storage.sink();
    }
    var audio_queue: [runtime_api.default_quantum_frames * product_audio_target_quanta * core.sdsp.sample_bytes]u8 = undefined;
    var audio_scratch: [runtime_api.default_quantum_frames * core.sdsp.sample_bytes]u8 = undefined;
    var runtime = runtime_api.Runtime.init(.{
        .slice_budget = product_host.slice_budget_master_cycles,
        .max_input_events = runtime_api.default_max_input_events,
        .max_wait_ticks = runtime_api.default_max_wait_ticks,
    }, sys.monotonicHz(), sys.ticks(), .{
        .config = .{
            .sample_rate = core.sdsp.output_sample_rate,
            .channels = core.sdsp.channels,
            .quantum_frames = runtime_api.default_quantum_frames,
            .target_quanta = product_audio_target_quanta,
            .max_catchup_quanta = product_audio_max_catchup_quanta,
        },
        .queue_storage = audio_queue[0..],
        .scratch = audio_scratch[0..],
        .sink = audio_sink,
    }) catch |fault| {
        return showStatus(allocator, sys, desk, draw, "R4SNES - Hostfehler", &.{
            "Die kooperative Gastlaufzeit konnte nicht initialisiert werden.",
            @errorName(fault),
        }, error_runtime);
    };
    var runtime_host = product_host.WindowHost.init(sys, &window, &guest, &runtime);
    runtime_host.applyTitle();

    sys.write("R4SNES: validated cartridge ");
    sys.println(guest.title());
    sys.write("R4SNES: board ");
    sys.println(@tagName(guest.cartridge.?.board.capability.enhancement));
    if (guest.save_session.?.enabled) {
        sys.write("R4SNES: persistence ");
        sys.println(core.persistence.save_root);
    }
    sys.println("R4SNES: host controls F5=pause F6=resume F8=reset F9=mute F10=unmute");
    const exit_code = runtime.run(&sys, guest.driver(), runtime_host.driver());
    const runtime_state = runtime.state;
    const audio_degraded = runtime.audio.state == .degraded;
    const runtime_stats = runtime.stats;
    const audio_stats = runtime.audio.stats;
    const guest_ns = if (e2e_trace.active) guest.effectiveGuestNanoseconds() else runtime.clock.guest_ns;
    const machine = guest.machine.?;
    const guest_cycles = machine.clock.master_cycles;
    const master_hz = machine.clock.profile().master_hz;
    const expected_cycles: u64 = @intCast((@as(u128, guest_ns) * master_hz) / std.time.ns_per_s);
    const drift_cycles = if (guest_cycles >= expected_cycles) guest_cycles - expected_cycles else expected_cycles - guest_cycles;
    const pending_cycles = machine.host_budget.pending_master_cycles;
    const ppu_frames = machine.clock.frame;
    const dsp_stats = machine.smp.dsp.stats;
    const dsp_queued_frames = machine.smp.dsp.queuedFrames();
    const maximum_step_gap_ns = guest.runtime_guest.maximum_step_gap_ns;
    const controller_witness = @as(u16, machine.bus.wram[core.fixture_rom.controller_low_wram_index]) |
        (@as(u16, machine.bus.wram[core.fixture_rom.controller_high_wram_index]) << 8);
    const completion_seen = machine.bus.wram[core.fixture_rom.completion_wram_index] == core.fixture_rom.completion_witness_value;
    const battery = guest.cartridge.?.board.battery;
    const rtc = guest.save_session.?.rtc_record != null;
    const save_bytes = guest.cartridge.?.sram_storage.len;
    const identity = guest.cartridge.?.identity;
    const guest_stats = guest.stats;
    const published_frames = window.video.stats.published_frames;
    runtime.shutdown();
    const close_result = guest.close();
    const persistence_stats = save_store.stats;
    const save_files = persistenceFilesPresent(&files, &identity, save_bytes, rtc);
    if (e2e_trace.active) {
        const expected_state: runtime_api.LifecycleState = switch (e2e_trace.expected_end) {
            .witness => .completed,
            .close => .closed,
            .reject_invalid, .reject_firmware => runtime_state,
        };
        const end_ok = runtime_state == expected_state and switch (e2e_trace.expected_end) {
            .witness => completion_seen,
            .close => true,
            .reject_invalid, .reject_firmware => false,
        };
        const persistence_ok = !battery or (save_files and persistence_stats.errors == 0 and persistence_stats.started != 0 and persistence_stats.completed != 0);
        const e2e_ok = exit_code == 0 and end_ok and close_result == 0 and !guest.resourcesOpen() and
            guest_ns != 0 and guest_cycles != 0 and ppu_frames != 0 and published_frames != 0 and
            drift_cycles <= product_host.slice_budget_master_cycles + 64 and
            pending_cycles <= product_host.slice_budget_master_cycles and
            guest_stats.maximum_slice_grant <= product_host.slice_budget_master_cycles and
            guest_stats.maximum_slice_execution <= product_host.slice_budget_master_cycles + 64 and
            controller_witness != 0 and runtime_stats.input_events != 0 and
            audio_stats.writes != 0 and audio_stats.write_failures == 0 and
            dsp_stats.frames_rendered != 0 and dsp_stats.frames_dropped == 0 and
            dsp_stats.frames_rendered > dsp_stats.silence_frames and persistence_ok and !audio_degraded;
        if (!writeE2eRuntimeReport(
            &sys,
            e2e_trace,
            launch.guest_path,
            e2e_ok,
            battery,
            rtc,
            save_files,
            guest_cycles,
            guest_ns,
            drift_cycles,
            pending_cycles,
            master_hz,
            ppu_frames,
            runtime_stats,
            audio_stats,
            dsp_stats,
            dsp_queued_frames,
            maximum_step_gap_ns,
            controller_witness,
            completion_seen,
            guest_stats,
            persistence_stats,
            published_frames,
            close_result,
        )) return error_e2e_trace;
        if (!e2e_ok) return error_e2e_trace;
    }
    if (close_result != 0) {
        var storage_text: [128]u8 = undefined;
        const rendered = std.fmt.bufPrint(storage_text[0..], "Speicherstufe: {s}, Dateisystemcode: {d}", .{
            save_store.failureStageName(),
            save_store.failureCode(),
        }) catch "Cartridge-Speicher konnte nicht sicher abgeschlossen werden.";
        return showStatus(allocator, sys, desk, draw, "R4SNES - Speicherfehler", &.{
            "SAV/RTC konnte nicht sicher veroeffentlicht werden.",
            rendered,
            "Der letzte gueltige Stand bleibt erhalten; ein Stage wird beim naechsten Start wiederaufgenommen.",
        }, error_save_close);
    }
    if (runtime_state == .closed or runtime_state == .completed) return 0;
    var failure_text: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(failure_text[0..], "Laufzeitfehler: {d}", .{exit_code}) catch "Laufzeitfehler";
    return showStatus(allocator, sys, desk, draw, "R4SNES - Laufzeitfehler", &.{
        "Die emulierte Super-Nintendo-Instanz wurde kontrolliert beendet.",
        rendered,
        if (audio_degraded) "Audio war degradiert; Video und Eingabe liefen unabhaengig weiter." else "Alle Instanzressourcen wurden freigegeben.",
    }, if (exit_code == 0) error_runtime else exit_code);
}

const E2eTrace = struct {
    const ExpectedEnd = enum { close, witness, reject_invalid, reject_firmware };

    active: bool = false,
    id: []const u8 = "",
    expected_end: ExpectedEnd = .close,

    fn parse(request: r4os.subsystem_launch.Request) E2eTrace {
        const mode = (request.option(r4os.subsystem_launch.trace_mode_key) catch null) orelse return .{};
        if (!std.ascii.eqlIgnoreCase(mode, r4os.subsystem_launch.trace_mode_headless)) return .{};
        const id = (request.option(r4os.subsystem_launch.trace_key) catch null) orelse return .{};
        if (id.len != 16) return .{};
        for (id) |byte| if (!std.ascii.isHex(byte)) return .{};
        const end_text = (request.option(e2e_end_key) catch null) orelse return .{};
        const expected_end: ExpectedEnd = if (std.ascii.eqlIgnoreCase(end_text, "close"))
            .close
        else if (std.ascii.eqlIgnoreCase(end_text, "witness"))
            .witness
        else if (std.ascii.eqlIgnoreCase(end_text, "reject-invalid"))
            .reject_invalid
        else if (std.ascii.eqlIgnoreCase(end_text, "reject-firmware"))
            .reject_firmware
        else
            return .{};
        return .{ .active = true, .id = id, .expected_end = expected_end };
    }

    fn endName(self: E2eTrace) []const u8 {
        return switch (self.expected_end) {
            .reject_invalid => "reject-invalid",
            .reject_firmware => "reject-firmware",
            else => @tagName(self.expected_end),
        };
    }
};

fn e2eReportPath(trace: E2eTrace, storage: *[96]u8) ?[*:0]const u8 {
    const path = std.fmt.bufPrintZ(storage[0..], "C:\\TEMP\\R4SNES-{s}.REPORT", .{trace.id}) catch return null;
    return path.ptr;
}

fn writeE2eRejection(
    sys: *const r4os.r4sys.Context,
    trace: E2eTrace,
    class: []const u8,
    fault: anyerror,
) bool {
    var path_storage: [96]u8 = undefined;
    const path = e2eReportPath(trace, &path_storage) orelse return false;
    var report_storage: [256]u8 = undefined;
    const report = std.fmt.bufPrint(
        report_storage[0..],
        "R4SNES E2E rejection: OK id={s} class={s} error={s} window=closed resources=closed\r\n",
        .{ trace.id, class, @errorName(fault) },
    ) catch return false;
    return sys.fileWrite(path, report) == @as(i32, @intCast(report.len));
}

fn writeE2eFailure(
    sys: *const r4os.r4sys.Context,
    trace: E2eTrace,
    phase: []const u8,
    fault: anyerror,
    storage_stage: []const u8,
    storage_code: i32,
) bool {
    var path_storage: [96]u8 = undefined;
    const path = e2eReportPath(trace, &path_storage) orelse return false;
    var report_storage: [320]u8 = undefined;
    const report = std.fmt.bufPrint(
        report_storage[0..],
        "R4SNES E2E diagnostic: FAILED id={s} phase={s} error={s} storage_stage={s} storage_code={d}\r\n",
        .{ trace.id, phase, @errorName(fault), storage_stage, storage_code },
    ) catch return false;
    return sys.fileWrite(path, report) == @as(i32, @intCast(report.len));
}

fn writeE2eRuntimeReport(
    sys: *const r4os.r4sys.Context,
    trace: E2eTrace,
    guest_path: []const u8,
    ok: bool,
    battery: bool,
    rtc: bool,
    save_files: bool,
    guest_cycles: u64,
    guest_ns: u64,
    drift_cycles: u64,
    pending_cycles: u64,
    master_hz: u64,
    ppu_frames: u64,
    runtime_stats: runtime_api.RuntimeStats,
    audio_stats: runtime_api.AudioStats,
    dsp_stats: core.sdsp.AudioStats,
    dsp_queued_frames: usize,
    maximum_step_gap_ns: u64,
    controller_witness: u16,
    completion_seen: bool,
    guest_stats: product_host.GuestStats,
    persistence_stats: core.persistence_r4os.AsyncStats,
    published_frames: u64,
    close_result: i32,
) bool {
    var path_storage: [96]u8 = undefined;
    const path = e2eReportPath(trace, &path_storage) orelse return false;
    var report_storage: [1536]u8 = undefined;
    const extension = if (endsWithIgnoreCase(guest_path, ".smc")) ".smc" else ".sfc";
    const non_silent_frames = dsp_stats.frames_rendered -| dsp_stats.silence_frames;
    const prefix_len = (std.fmt.bufPrint(
        report_storage[0..],
        "R4SNES E2E runtime: {s} id={s} extension={s} end={s} battery={d} rtc={d} guest_ns={d} guest_cycles={d} master_hz={d} drift_cycles={d} pending_cycles={d} ppu_frames={d} slices={d} max_slice_grant={d} max_slice_execution={d} max_step_gap_ns={d} input={d} controller=0x{x:0>4} completion={d} frames={d} dropped_presents={d} audio_writes={d} audio_busy={d} audio_failures={d} audio_late={d} audio_discarded={d} audio_suppressed={d}",
        .{
            if (ok) "OK" else "FAILED",
            trace.id,
            extension,
            trace.endName(),
            @intFromBool(battery),
            @intFromBool(rtc),
            guest_ns,
            guest_cycles,
            master_hz,
            drift_cycles,
            pending_cycles,
            ppu_frames,
            runtime_stats.slices,
            guest_stats.maximum_slice_grant,
            guest_stats.maximum_slice_execution,
            maximum_step_gap_ns,
            runtime_stats.input_events,
            controller_witness,
            @intFromBool(completion_seen),
            published_frames,
            runtime_stats.dropped_presents,
            audio_stats.writes,
            audio_stats.busy_writes,
            audio_stats.write_failures,
            audio_stats.late_resyncs,
            audio_stats.discarded_bytes,
            audio_stats.suppressed_bytes,
        },
    ) catch return false).len;
    const suffix_len = (std.fmt.bufPrint(
        report_storage[prefix_len..],
        " dsp_native={d} dsp_resampled={d} dsp_rendered={d} dsp_non_silent={d} dsp_dropped={d} dsp_queued={d} save_async_started={d} save_async_completed={d} save_async_coalesced={d} save_async_errors={d} save_async_max_queued={d} pauses={d} resumes={d} resets={d} save_files={d} close={d} resources=closed\r\n",
        .{
            dsp_stats.native_frames,
            dsp_stats.resampled_frames,
            dsp_stats.frames_rendered,
            non_silent_frames,
            dsp_stats.frames_dropped,
            dsp_queued_frames,
            persistence_stats.started,
            persistence_stats.completed,
            persistence_stats.coalesced,
            persistence_stats.errors,
            persistence_stats.maximum_queued,
            runtime_stats.pauses,
            runtime_stats.resumes,
            runtime_stats.resets,
            @intFromBool(save_files),
            close_result,
        },
    ) catch return false).len;
    const report = report_storage[0 .. prefix_len + suffix_len];
    return sys.fileWrite(path, report) == @as(i32, @intCast(report.len));
}

fn persistenceFilesPresent(
    files: *const r4os.Files,
    digest: *const [core.persistence.digest_bytes]u8,
    ram_bytes: usize,
    has_rtc: bool,
) bool {
    if (ram_bytes != 0) {
        const path = core.persistence_r4os.dataPath(digest, .sram) catch return false;
        const info = switch (files.info(path.asZ())) {
            .value => |value| value,
            .missing, .failure => return false,
        };
        if (info.is_dir != 0 or info.size != ram_bytes) return false;
    }
    if (has_rtc) {
        const path = core.persistence_r4os.dataPath(digest, .rtc) catch return false;
        const info = switch (files.info(path.asZ())) {
            .value => |value| value,
            .missing, .failure => return false,
        };
        if (info.is_dir != 0 or info.size != core.persistence.rtc_record_bytes) return false;
    }
    return true;
}

const ProductTimeContext = struct {
    sys: *const r4os.r4sys.Context,

    fn source(self: *ProductTimeContext) product_host.TimeSource {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: *anyopaque) product_host.TimePoint {
        const self: *ProductTimeContext = @ptrCast(@alignCast(context));
        return .{
            .wall_seconds = core.persistence_r4os.wallSeconds(self.sys.timeState()),
            .monotonic_ns = self.sys.monotonicNanoseconds() orelse 0,
        };
    }
};

const LoadError = error{
    Missing,
    Directory,
    InvalidGeometry,
    WrongSize,
    Metadata,
    Read,
    OutOfMemory,
};

fn hasCartridgeExtension(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".sfc") or endsWithIgnoreCase(path, ".smc");
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn loadCartridgeOwned(
    allocator: std.mem.Allocator,
    files: *const r4os.app_storage.Files,
    path: *r4os.AbsoluteFilePath,
) LoadError![]u8 {
    const info = switch (files.info(path.asZ())) {
        .value => |value| value,
        .missing => return error.Missing,
        .failure => return error.Metadata,
    };
    if (info.is_dir != 0) return error.Directory;
    const size = std.math.cast(usize, info.size) orelse return error.InvalidGeometry;
    _ = core.cartridge.inspectContainerSize(size) catch return error.InvalidGeometry;
    const image = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(image);
    try readExact(files, path, image);
    return image;
}

fn loadExactOwned(
    allocator: std.mem.Allocator,
    files: *const r4os.app_storage.Files,
    raw_path: []const u8,
    expected_size: usize,
) LoadError![]u8 {
    var path = r4os.AbsoluteFilePath.parse(raw_path) catch return error.Metadata;
    const info = switch (files.info(path.asZ())) {
        .value => |value| value,
        .missing => return error.Missing,
        .failure => return error.Metadata,
    };
    if (info.is_dir != 0) return error.Directory;
    if (info.size != expected_size) return error.WrongSize;
    const bytes = allocator.alloc(u8, expected_size) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    try readExact(files, &path, bytes);
    return bytes;
}

fn loadOptionalIpl(files: *const r4os.app_storage.Files) LoadError!?[core.smp.exact_ipl_size]u8 {
    var path = r4os.AbsoluteFilePath.parse(core.persistence.spc700_ipl_path) catch return error.Metadata;
    const info = switch (files.info(path.asZ())) {
        .missing => return null,
        .failure => return error.Metadata,
        .value => |value| value,
    };
    if (info.is_dir != 0 or info.size != core.smp.exact_ipl_size) return error.WrongSize;
    var result: [core.smp.exact_ipl_size]u8 = undefined;
    try readExact(files, &path, result[0..]);
    return result;
}

fn readExact(files: *const r4os.app_storage.Files, path: *r4os.AbsoluteFilePath, out: []u8) LoadError!void {
    var offset: usize = 0;
    while (offset < out.len) {
        const transferred = switch (files.readAt(path.asZ(), @intCast(offset), out[offset..])) {
            .bytes => |count| count,
            .end, .failure => return error.Read,
        };
        if (transferred == 0 or transferred > out.len - offset) return error.Read;
        offset += transferred;
    }
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    @memset(bytes, 0);
    allocator.free(bytes);
}

fn loadFailureMessage(fault: anyerror) []const u8 {
    return switch (fault) {
        error.Missing => "Die Cartridge-Datei wurde nicht gefunden.",
        error.Directory => "Der Cartridge-Pfad bezeichnet ein Verzeichnis.",
        error.InvalidGeometry => "Die Datei besitzt keine gueltige SNES-Cartridge-Geometrie.",
        error.Metadata => "Die Dateiinformationen konnten nicht gelesen werden.",
        error.Read => "Die Cartridge konnte nicht vollstaendig und unveraendert gelesen werden.",
        error.OutOfMemory => "Fuer das unveraenderte ROM-Abbild ist nicht genug Speicher verfuegbar.",
        else => "Die Cartridge konnte nicht geladen werden.",
    };
}

fn loadFailureCode(fault: anyerror) i32 {
    return switch (fault) {
        error.Missing => error_missing,
        error.Directory => error_directory,
        error.InvalidGeometry, error.WrongSize => error_size,
        error.OutOfMemory => error_allocator,
        error.Metadata, error.Read => error_metadata,
        else => error_metadata,
    };
}

fn openFailureMessage(fault: anyerror) []const u8 {
    return switch (fault) {
        error.Busy => "Der Speicherstand dieser Cartridge ist bereits zum Schreiben geoeffnet.",
        error.CorruptSave, error.WrongSize, error.RtcChipMismatch, error.BadMagic, error.UnsupportedVersion, error.BadChecksum, error.InvalidChip, error.InvalidRegisterCount, error.InvalidFlags, error.InvalidReserved, error.InvalidCatchup => "Die vorhandene SRAM-/RTC-Datei ist beschaedigt oder inkompatibel.",
        error.Full => "Der Datentraeger fuer den Speicherstand ist voll.",
        error.Io, error.Unsupported => "Der kanonische Cartridge-Speicherort ist nicht verfuegbar.",
        error.OutOfMemory => "Fuer die private Super-Nintendo-Instanz ist nicht genug Speicher verfuegbar.",
        else => cartridgeError(fault),
    };
}

fn openFailureCode(fault: anyerror) i32 {
    return switch (fault) {
        error.Busy => error_save_busy,
        error.CorruptSave, error.WrongSize, error.RtcChipMismatch, error.BadMagic, error.UnsupportedVersion, error.BadChecksum, error.InvalidChip, error.InvalidRegisterCount, error.InvalidFlags, error.InvalidReserved, error.InvalidCatchup, error.Full, error.Io, error.Unsupported => error_save_open,
        error.OutOfMemory => error_allocator,
        else => error_cartridge,
    };
}

fn showStatus(
    allocator: std.mem.Allocator,
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    title: [*:0]const u8,
    lines: []const []const u8,
    result_code: i32,
) i32 {
    _ = allocator;
    _ = desk.guiSetTitle(title);
    _ = desk.guiSetMinSize(440, 230);
    if (!renderStatus(&draw, lines)) return result_code;
    var activity_sequence: u64 = 0;
    const close_poll_ticks = @max(@as(u64, 1), sys.ticksFromMilliseconds(100));
    while (!sys.programShouldClose()) {
        var event_count: u16 = 0;
        while (event_count < runtime_api.default_max_input_events) : (event_count += 1) {
            var event: r4os.abi.GuiEvent = .{};
            if (desk.guiPollEvent(&event) <= 0) break;
            if (event.kind == @intFromEnum(r4os.abi.GuiEventKind.close)) return result_code;
            if (event.kind == @intFromEnum(r4os.abi.GuiEventKind.key_down) and event.key == 27) return result_code;
            if (event.kind == @intFromEnum(r4os.abi.GuiEventKind.resize)) {
                if (!renderStatus(&draw, lines)) return result_code;
            }
        }
        if (event_count == runtime_api.default_max_input_events) continue;
        if (desk.hasFn("desktop_activity_wait")) {
            var sequence = activity_sequence;
            const raw = desk.desktopActivityWait(activity_sequence, close_poll_ticks, &sequence);
            activity_sequence = sequence;
            if (raw < 0) return result_code;
        } else {
            sys.sleepTicks(1);
        }
    }
    return result_code;
}

fn renderStatus(draw: *const r4os.r4draw.Context, lines: []const []const u8) bool {
    const background: u32 = 0x0014_1820;
    if (draw.guiClear(background) <= 0) return false;
    if (!drawStatusLine(draw, 16, 16, "R4SNES", 0x00FF_FFFF, background)) return false;
    var y: i32 = 48;
    for (lines) |line| {
        if (!drawStatusLine(draw, 16, y, line, 0x00E0_E0E0, background)) return false;
        y += 18;
    }
    if (!drawStatusLine(draw, 16, y + 18, "Fenster schliessen oder Escape druecken.", 0x0090_A0B0, background)) return false;
    return draw.guiPresent() >= 0;
}

fn drawStatusLine(
    draw: *const r4os.r4draw.Context,
    x: i32,
    y: i32,
    value: []const u8,
    foreground: u32,
    background: u32,
) bool {
    var storage: [320]u8 = .{0} ** 320;
    const count = @min(value.len, storage.len - 1);
    @memcpy(storage[0..count], value[0..count]);
    return draw.guiDrawText(x, y, @ptrCast(&storage), foreground, background) >= 0;
}

fn printNecDspFirmwareError(sys: anytype, needed: core.cartridge.NecDspRequirement, fault: anyerror) void {
    sys.write("R4SNES: ");
    sys.write(needed.chipName());
    sys.write(" firmware ");
    sys.write(needed.fileName());
    switch (fault) {
        error.MissingNecDspFirmware => sys.write(" is missing"),
        error.InvalidNecDspFirmwareSize => sys.write(" has the wrong size"),
        error.InvalidNecDspFirmwareDigest => sys.write(" does not match the required chip revision"),
        error.InvalidNecDspFirmwarePath => sys.write(" has an invalid configured path"),
        error.NecDspFirmwareMetadataFailure => sys.write(" metadata could not be read"),
        error.NecDspFirmwareReadFailure => sys.write(" could not be read completely"),
        else => sys.write(" failed validation"),
    }
    sys.write(if (needed.firmwareBytes() == core.nec_dsp.st_firmware_bytes)
        "; expected exactly 53248 bytes at "
    else
        "; expected exactly 8192 bytes at ");
    sys.write(needed.firmwarePath());
    sys.println(".");
}

fn printSt018FirmwareError(sys: anytype, needed: core.cartridge.St018Requirement, fault: anyerror) void {
    sys.write("R4SNES: ");
    sys.write(needed.chipName());
    sys.write(" firmware ");
    sys.write(needed.fileName());
    switch (fault) {
        error.MissingSt018Firmware => sys.write(" is missing"),
        error.InvalidSt018FirmwareSize => sys.write(" has the wrong size"),
        error.InvalidSt018FirmwareDigest => sys.write(" does not match the required chip revision"),
        error.InvalidSt018FirmwarePath => sys.write(" has an invalid configured path"),
        error.St018FirmwareMetadataFailure => sys.write(" metadata could not be read"),
        error.St018FirmwareReadFailure => sys.write(" could not be read completely"),
        else => sys.write(" failed validation"),
    }
    sys.write("; expected exactly 163840 bytes at ");
    sys.write(needed.firmwarePath());
    sys.println(".");
}

fn cartridgeError(fault: anyerror) []const u8 {
    return switch (fault) {
        error.AmbiguousHeader => "R4SNES: cartridge contains ambiguous SNES headers.",
        error.NoValidHeader => "R4SNES: no consistent SNES header was found.",
        error.ExcludedBoard => "R4SNES: cartridge belongs to an excluded adapter or extension system.",
        error.UnsupportedBoard => "R4SNES: cartridge board is unknown or unsupported.",
        error.UnsupportedOBC1Revision => "R4SNES: cartridge declares an unsupported OBC-1 revision.",
        error.UnsupportedSrtcRevision => "R4SNES: cartridge declares an unsupported S-RTC revision.",
        error.UnsupportedSdd1Revision => "R4SNES: cartridge declares an unsupported S-DD1 revision.",
        error.UnsupportedSpc7110Revision => "R4SNES: cartridge declares an unsupported SPC7110 revision.",
        error.UnsupportedSuperFxRevision => "R4SNES: cartridge declares an unsupported Super FX revision.",
        error.UnsupportedSa1Revision => "R4SNES: cartridge declares an unsupported SA-1 revision.",
        error.UnsupportedCx4Revision => "R4SNES: cartridge declares an unsupported CX4 revision.",
        error.MissingNecDspFirmware => "R4SNES: required NEC-DSP firmware is missing.",
        error.InvalidNecDspFirmwareSize => "R4SNES: NEC-DSP firmware has the wrong size.",
        error.InvalidNecDspFirmwareDigest => "R4SNES: NEC-DSP firmware digest does not match its chip revision.",
        error.NecDspFirmwareRevisionMismatch => "R4SNES: appended NEC-DSP firmware contradicts the detected board revision.",
        error.AmbiguousNecDspFirmwareSource => "R4SNES: NEC-DSP firmware was supplied both appended and separately.",
        error.UnexpectedNecDspFirmware, error.UnexpectedAppendedFirmware => "R4SNES: firmware was supplied for a cartridge without a matching NEC-DSP board.",
        error.MissingSt018Firmware => "R4SNES: required ST018 firmware is missing.",
        error.InvalidSt018FirmwareSize => "R4SNES: ST018 firmware has the wrong size.",
        error.InvalidSt018FirmwareDigest => "R4SNES: ST018 firmware digest does not match the required revision.",
        error.UnexpectedSt018Firmware => "R4SNES: ST018 firmware was supplied for a cartridge without an ST018 board.",
        error.ContradictoryOBC1Board => "R4SNES: OBC-1 header contradicts its LoROM, battery or 8-KiB RAM profile.",
        error.ContradictorySrtcBoard => "R4SNES: S-RTC header contradicts its ExHiROM, battery or save-RAM profile.",
        error.ContradictorySdd1Board => "R4SNES: S-DD1 header contradicts its LoROM, battery or 32-KiB RAM profile.",
        error.ContradictorySpc7110Board => "R4SNES: SPC7110 header contradicts its HiROM, battery, 8-KiB RAM or data-ROM profile.",
        error.ContradictorySuperFxBoard => "R4SNES: Super FX header contradicts its LoROM, GSU revision, ROM or 32/64/128-KiB work-RAM profile.",
        error.ContradictorySa1Board => "R4SNES: SA-1 header contradicts its LoROM, ROM or BW-RAM profile.",
        error.ContradictoryCx4Board => "R4SNES: CX4 header contradicts its LoROM, ROM or no-save-RAM profile.",
        error.ContradictoryNecDspBoard => "R4SNES: NEC-DSP revision contradicts the cartridge mapping or header identity.",
        error.ContradictorySt018Board => "R4SNES: ST018 header contradicts its LoROM, subtype, battery or 16-KiB work-RAM profile.",
        error.UnaddressableBoardGeometry => "R4SNES: cartridge board geometry exceeds its implemented address space.",
        error.OutOfMemory => "R4SNES: cartridge memory could not be allocated.",
        else => "R4SNES: cartridge validation failed.",
    };
}

noinline fn hostSelfTest(app: *r4os.App) i32 {
    const sys = app.system();
    const allocator = app.allocator() orelse return error_allocator;
    const fixtures = [_]struct {
        path: [*:0]const u8,
        kind: core.fixture_rom.Kind,
    }{
        .{ .path = e2e_fixture_a_path, .kind = .rom_only },
        .{ .path = e2e_fixture_b_path, .kind = .battery_rtc },
        .{ .path = e2e_fixture_invalid_path, .kind = .invalid },
        .{ .path = e2e_fixture_firmware_path, .kind = .firmware_required },
    };
    for (fixtures) |fixture| {
        const image = allocator.alloc(u8, core.fixture_rom.imageBytes(fixture.kind)) catch {
            sys.println("R4SNES fixture generation: FAILED allocation");
            return error_host_selftest;
        };
        defer allocator.free(image);
        core.fixture_rom.build(image, fixture.kind) catch {
            sys.println("R4SNES fixture generation: FAILED build");
            return error_host_selftest;
        };
        if (fixture.kind == .invalid) {
            if (core.cartridge.inspectNecDspRequirement(image, null)) |_| {
                sys.println("R4SNES fixture generation: FAILED invalid-accepted");
                return error_host_selftest;
            } else |fault| {
                if (fault != error.NoValidHeader) {
                    sys.println("R4SNES fixture generation: FAILED invalid-classification");
                    return error_host_selftest;
                }
            }
        } else {
            const requirement = core.cartridge.inspectNecDspRequirement(image, null) catch {
                sys.println("R4SNES fixture generation: FAILED header");
                return error_host_selftest;
            };
            if ((fixture.kind == .firmware_required) != (requirement != null)) {
                sys.println("R4SNES fixture generation: FAILED firmware-classification");
                return error_host_selftest;
            }
        }
        if (sys.fileWrite(fixture.path, image) != @as(i32, @intCast(image.len))) {
            sys.println("R4SNES fixture generation: FAILED write");
            return error_host_selftest;
        }
    }
    if (sys.fileWrite(host_selftest_marker_path, host_selftest_marker) != @as(i32, @intCast(host_selftest_marker.len))) {
        sys.println("R4SNES fixture generation: FAILED marker-write");
        return error_host_selftest;
    }
    sys.write(host_selftest_marker);
    return 0;
}

noinline fn selfTest(app: *r4os.App) i32 {
    const sys = app.system();
    var machine = core.machine.Machine.init(1);
    if (!machine.foundationReady() or core.cpu.opcode_table.len != 256 or !machine.scpu.cpuMayRun()) return error_not_implemented;
    machine.smp.dsp.beginCapture();
    machine.smp.dsp.runClocks(&machine.smp.aram, 64);
    if (machine.smp.dsp.sample_counter != 2 or machine.smp.dsp.queuedFrames() != 2) return error_not_implemented;
    machine.smp.bus_mode = .vector_ram;
    machine.smp.pc = 0x0200;
    machine.smp.aram[0x0200] = 0x00;
    machine.smp.step() catch return error_not_implemented;
    if (machine.smp.pc != 0x0201) return error_not_implemented;
    var object_ram = [_]u8{0} ** core.obc1.ram_bytes;
    var object = core.obc1.Device{};
    object.power(object_ram[0..]) catch return error_not_implemented;
    if (!object.write(object_ram[0..], 0x007FF0, 0xA5).changed or
        object.read(object_ram[0..], 0x807FF0) != 0xA5)
        return error_not_implemented;
    var rtc = core.srtc.Device{};
    rtc.power();
    if (!rtc.write(0x002801, 0x0E) or !rtc.write(0x002801, 0x04) or !rtc.halted)
        return error_not_implemented;
    var stream: [256]u8 = undefined;
    fillEnhancementSelfTest(&stream);
    stream[0] = 0;
    var sdd1 = core.sdd1.Decompressor{};
    sdd1.init(stream[0..], .{ 0, 1, 2, 3 }, 0xC00000);
    if (sdd1.read(stream[0..], .{ 0, 1, 2, 3 }) != 0x28 or
        sdd1.read(stream[0..], .{ 0, 1, 2, 3 }) != 0x07)
        return error_not_implemented;
    fillEnhancementSelfTest(&stream);
    var spc7110 = core.spc7110.Decompressor{};
    spc7110.init(stream[0..], 0, 0) catch return error_not_implemented;
    if ((spc7110.decode(stream[0..]) & 0xFF) != 0x5D) return error_not_implemented;
    var epson = core.epson_rtc.Device{};
    epson.power();
    if (!epson.isHalted() or !epson.writePort(0x4840, 1) or
        (epson.readPort(0x4842, 0) & 0x80) == 0)
        return error_not_implemented;
    var gsu = core.superfx.Device.init(.gsu2);
    var no_rom: [0]u8 = .{};
    var no_ram: [0]u8 = .{};
    gsu.r[0] = 0x1234;
    gsu.r[1] = 0x02FF;
    gsu.executeDecoded(&no_rom, &no_ram, 0x3D) catch return error_not_implemented;
    gsu.executeDecoded(&no_rom, &no_ram, 0x81) catch return error_not_implemented;
    if (gsu.r[0] != 0x33CC or gsu.revision.versionCode() != 4) return error_not_implemented;
    var sa1 = core.sa1.Device{};
    sa1.power(.ntsc, 256 * 1024, 64 * 1024) catch return error_not_implemented;
    if (!sa1.reset_hold or sa1.master_cycles != 0 or sa1.cpuIrqPending()) return error_not_implemented;
    var cx4 = core.cx4.Device{};
    cx4.power(256 * 1024, 0) catch return error_not_implemented;
    cx4.accumulator = 0x7fffff;
    if (cx4.executeDecoded(0x8401) != .defined or cx4.accumulator != 0x800000 or
        !cx4.negative or !cx4.overflow or cx4.carry or
        core.cx4.dataRomWord(0x240) != 0xb504f3)
        return error_not_implemented;
    const allocator = app.allocator() orelse return error_allocator;
    const nec_firmware = allocator.alloc(u8, core.nec_dsp.firmware_bytes) catch return error_allocator;
    defer {
        @memset(nec_firmware, 0);
        allocator.free(nec_firmware);
    }
    @memset(nec_firmware, 0);
    nec_firmware[0] = 0x06;
    nec_firmware[1] = 0x8d;
    nec_firmware[2] = 0xc4; // LD DR,$1234: asserts RQM through the real decoder.
    var nec = core.nec_dsp.Device.init(
        allocator,
        .dsp1b,
        .lo_rom,
        1024 * 1024,
        0,
        nec_firmware,
        .allow_open_test,
        .open_test,
    ) catch return error_not_implemented;
    defer nec.close();
    nec.step();
    if (nec.dr != 0x1234 or !nec.requestForMaster() or nec.cycles != 1)
        return error_not_implemented;
    const arm_firmware = allocator.alloc(u8, core.st018.firmware_bytes) catch return error_allocator;
    defer {
        @memset(arm_firmware, 0);
        allocator.free(arm_firmware);
    }
    @memset(arm_firmware, 0);
    arm_firmware[0] = 0x2a;
    arm_firmware[1] = 0x00;
    arm_firmware[2] = 0xa0;
    arm_firmware[3] = 0xe3; // MOV r0,#42
    var arm = core.st018.Device.init(allocator, arm_firmware, .allow_open_test, .open_test) catch
        return error_not_implemented;
    defer arm.close();
    arm.reset_delay = 0;
    arm.ready = true;
    const arm_result = arm.runSlice(1);
    if (arm_result.instructions != 1 or arm.cpu.r[0] != 42 or arm.cpu.cpsr.mode != .supervisor)
        return error_not_implemented;
    machine.close();
    machine.close();
    if (!machine.closed or machine.smp.dsp.capture_enabled or machine.smp.dsp.queuedFrames() != 0) return error_not_implemented;
    sys.println("R4SNES SELFTEST OK: OBC-1/S-RTC/S-DD1/SPC7110/Epson-RTC/Super FX GSU-1/GSU-2/SA-1/CX4/NEC-DSP-1/1A/1B/2/3/4/ST010/ST011/ST018-ARMv3, CPU, timed 5A22, byte-bounded DMA, complete PPU, SPC700/S-SMP and cycle-clocked S-DSP owners isolated; productive R4SUBSYS1 host uses bounded master-clock slices, physical port-1 input, native XRGB32, App-Audio and idempotent persistence teardown.");
    return 0;
}

noinline fn persistenceSelfTest(app: *r4os.App) i32 {
    runPersistenceSelfTest(app) catch |fault| {
        const sys = app.system();
        sys.write("R4SNES persistence runtime: FAILED ");
        sys.println(@errorName(fault));
        return error_persistence_selftest;
    };
    app.system().println("R4SNES persistence runtime: OK sav=exact rtc=versioned lock=exclusive atomic=recover async=worker+drain");
    return 0;
}

fn runPersistenceSelfTest(app: *r4os.App) !void {
    const allocator = app.allocator() orelse return error.AllocatorUnavailable;
    const files = app.files() orelse return error.FilesUnavailable;
    const sys = app.system();
    const wall = core.persistence_r4os.wallSeconds(sys.timeState());
    const monotonic = sys.monotonicNanoseconds() orelse 0;
    const generation = (sys.ticks() | 1) +| 2;

    var save_cart = try makePersistenceCart(allocator, 8192, true, .none, 0x73);
    defer save_cart.deinit();
    var async_store = core.persistence_r4os.AsyncStore.init(files, allocator);
    async_store.removeTestFiles(&save_cart.identity);
    defer async_store.removeTestFiles(&save_cart.identity);
    var save_session = try core.persistence.Session.open(&save_cart, async_store.backend(), generation, wall, monotonic);
    defer if (!save_session.closed) save_session.close(&save_cart, generation, wall, monotonic) catch {};
    for (save_cart.sram_storage, 0..) |_, index| save_cart.writeSram(index, @truncate(index *% 37 +% 11));
    try save_session.flush(&save_cart, wall, monotonic);
    save_cart.writeSram(0, 0xA7);
    try save_session.flush(&save_cart, wall, monotonic);

    var competing_cart = try makePersistenceCart(allocator, 8192, true, .none, 0x73);
    defer competing_cart.deinit();
    var competing_store = core.persistence_r4os.Store.init(files);
    const contention = core.persistence.Session.open(&competing_cart, competing_store.backend(), generation + 1, wall, monotonic);
    if (contention) |opened| {
        var unexpected = opened;
        unexpected.close(&competing_cart, generation + 1, wall, monotonic) catch {};
        return error.ExclusiveWriterAcceptedTwice;
    } else |fault| {
        if (fault != error.Busy) return fault;
    }
    try save_session.close(&save_cart, generation, wall, monotonic);
    if (async_store.stats.started == 0 or async_store.stats.started != async_store.stats.completed or async_store.stats.errors != 0)
        return error.AsyncPersistenceMismatch;

    var reopened_cart = try makePersistenceCart(allocator, 8192, true, .none, 0x73);
    defer reopened_cart.deinit();
    var reopened_store = core.persistence_r4os.Store.init(files);
    var reopened = try core.persistence.Session.open(&reopened_cart, reopened_store.backend(), generation + 2, wall, monotonic);
    if (reopened_cart.sram_storage[0] != 0xA7 or
        reopened_cart.sram_storage[1] != @as(u8, @truncate(1 * 37 + 11)) or
        reopened_cart.sram_storage[reopened_cart.sram_storage.len - 1] != @as(u8, @truncate((reopened_cart.sram_storage.len - 1) *% 37 +% 11)))
        return error.SramMismatch;
    try reopened.close(&reopened_cart, generation + 2, wall, monotonic);

    const sav_path = try core.persistence_r4os.dataPath(&save_cart.identity, .sram);
    if (!std.mem.startsWith(u8, sav_path.bytes(), core.persistence.save_root) or
        !std.mem.endsWith(u8, sav_path.bytes(), ".SAV") or
        std.mem.indexOf(u8, sav_path.bytes(), "\\APPDATA\\") != null)
        return error.NonCanonicalSavePath;

    var rtc_cart = try makePersistenceCart(allocator, 0, true, .srtc, 0x74);
    defer rtc_cart.deinit();
    var rtc_store = core.persistence_r4os.Store.init(files);
    rtc_store.removeTestFiles(&rtc_cart.identity);
    defer rtc_store.removeTestFiles(&rtc_cart.identity);
    var rtc_session = try core.persistence.Session.open(&rtc_cart, rtc_store.backend(), generation + 3, wall, monotonic);
    const rtc_state = rtc_session.rtcState() orelse return error.RtcMissing;
    setSrtcCalendar(rtc_state, 9, 7);
    rtc_state.overflow = true;
    try rtc_session.close(&rtc_cart, generation + 3, wall, monotonic);

    var recovery_state = core.persistence.RtcState.init(.s_rtc);
    setSrtcCalendar(&recovery_state, 4, 3);
    var recovery_record: [core.persistence.rtc_record_bytes]u8 = undefined;
    core.persistence.encodeRtc(.{
        .state = recovery_state,
        .wall_anchor_seconds = wall orelse 0,
        .monotonic_anchor_ns = monotonic,
        .generation = generation + 4,
    }, &recovery_record);
    try rtc_store.prepareInterruptedPublishForTest(&rtc_cart.identity, .rtc, recovery_record[0..]);
    var recovered_cart = try makePersistenceCart(allocator, 0, true, .srtc, 0x74);
    defer recovered_cart.deinit();
    var recovered = try core.persistence.Session.open(&recovered_cart, rtc_store.backend(), generation + 4, wall, monotonic);
    if (recovered.peekRtcState() == null or
        recovered.peekRtcState().?.registers[0] != 4 or
        recovered.peekRtcState().?.latched[0] != 3)
        return error.RtcRecoveryMismatch;
    try recovered.close(&recovered_cart, generation + 4, wall, monotonic);

    try rtc_store.prepareInterruptedPublishForTest(
        &rtc_cart.identity,
        .rtc,
        recovery_record[0 .. recovery_record.len / 2],
    );
    var rejected_cart = try makePersistenceCart(allocator, 0, true, .srtc, 0x74);
    defer rejected_cart.deinit();
    const rejected = core.persistence.Session.open(&rejected_cart, rtc_store.backend(), generation + 5, wall, monotonic);
    if (rejected) |opened| {
        var unexpected = opened;
        unexpected.close(&rejected_cart, generation + 5, wall, monotonic) catch {};
        return error.PartialRecoveryAccepted;
    } else |fault| {
        if (fault != error.Io) return fault;
    }
    if (!std.mem.eql(u8, rtc_store.failureStageName(), "atomic_recover") or
        rtc_store.failureCode() != r4os.abi.file_stream_error_size_mismatch)
        return error.PartialRecoveryFailureMismatch;

    var epson_cart = try makePersistenceCart(allocator, 8192, true, .spc7110_epson_rtc, 0x75);
    defer epson_cart.deinit();
    var epson_store = core.persistence_r4os.Store.init(files);
    epson_store.removeTestFiles(&epson_cart.identity);
    defer epson_store.removeTestFiles(&epson_cart.identity);
    var epson_session = try core.persistence.Session.open(&epson_cart, epson_store.backend(), generation + 6, wall, monotonic);
    const epson_state = epson_session.rtcState() orelse return error.EpsonRtcMissing;
    setEpsonCalendar(epson_state);
    try epson_session.close(&epson_cart, generation + 6, wall, monotonic);
    var reopened_epson_cart = try makePersistenceCart(allocator, 8192, true, .spc7110_epson_rtc, 0x75);
    defer reopened_epson_cart.deinit();
    var reopened_epson = try core.persistence.Session.open(&reopened_epson_cart, epson_store.backend(), generation + 7, wall, monotonic);
    const reopened_epson_state = reopened_epson.peekRtcState() orelse return error.EpsonRtcMissing;
    if (reopened_epson_state.chip != .epson or reopened_epson_state.registers[0] != 8 or
        reopened_epson_state.registers[1] != 5 or reopened_epson_state.registers[15] != 4)
        return error.EpsonRtcRecoveryMismatch;
    try reopened_epson.close(&reopened_epson_cart, generation + 7, wall, monotonic);
}

fn fillEnhancementSelfTest(bytes: *[256]u8) void {
    var state: u32 = 0x12345678;
    for (bytes) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 24);
    }
}

fn setSrtcCalendar(state: *core.persistence.RtcState, live_second: u8, latched_second: u8) void {
    const weekday = core.srtc.calculateWeekday(0, 1, 1);
    core.srtc.registersFromCalendar(.{
        .second = live_second,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = 1,
        .year = 0,
        .weekday = weekday,
    }, &state.registers);
    core.srtc.registersFromCalendar(.{
        .second = latched_second,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = 1,
        .year = 0,
        .weekday = weekday,
    }, &state.latched);
    state.halted = false;
}

fn setEpsonCalendar(state: *core.persistence.RtcState) void {
    state.registers = .{ 8, 5, 9, 5, 3, 2, 9, 2, 2, 0, 4, 2, 4, 2, 0, 4 };
    state.latched = state.registers;
    state.halted = false;
    state.pending_catchup_seconds = 0;
}

fn makePersistenceCart(
    allocator: std.mem.Allocator,
    ram_bytes: usize,
    battery: bool,
    enhancement: core.board.Enhancement,
    identity_byte: u8,
) !core.cartridge.Cartridge {
    const rom = try allocator.alloc(u8, core.cartridge.minimum_rom_size);
    errdefer allocator.free(rom);
    @memset(rom, 0);
    const ram = try allocator.alloc(u8, ram_bytes);
    errdefer allocator.free(ram);
    @memset(ram, 0);
    return .{
        .allocator = allocator,
        .rom_storage = rom,
        .sram_storage = ram,
        .identity = .{identity_byte} ** core.persistence.digest_bytes,
        .header = undefined,
        .board = .{
            .mapping = .lo_rom,
            .region = .ntsc_u,
            .fast_rom = false,
            .capability = core.board.capability(enhancement),
            .sram_bytes = ram_bytes,
            .battery = battery,
        },
        .had_copier_header = false,
    };
}
