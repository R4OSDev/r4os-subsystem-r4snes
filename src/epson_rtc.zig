pub const register_count: usize = 16;

pub const ProtocolState = enum(u8) {
    inactive,
    mode_select,
    index_select,
    read,
    write,
};

pub const Mode = enum(u8) {
    linear = 0x03,
    indexed = 0x0C,
};

pub const Fault = enum(u8) {
    none,
    unsupported_mode,
    invalid_write,
    invalid_persistent_calendar,
    invalid_persistent_latch,
    invalid_halt_state,
};

pub const PersistentError = error{
    InvalidEpsonCalendar,
    InvalidEpsonWeekday,
    InvalidEpsonLatch,
    InvalidEpsonHaltState,
    InvalidEpsonControl,
};

pub const Calendar = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u8,
    weekday: u8,
};

const initial_registers = [register_count]u8{
    0, 0, // seconds
    0, 0, // minutes
    0, 0, // hours
    1, 0, // day
    1, 0, // month
    0, 0, // year 2000
    6, // Saturday
    2, 0, 6, // CR0 calendar enabled; CR2 stopped in 24-hour mode
};

/// Epson RTC-4513 owner used by SPC7110. Host wall time never enters the
/// protocol: the persistence owner supplies a bounded, forward-only number of
/// elapsed seconds, keeping tests and guest slices deterministic.
pub const Device = struct {
    live: [register_count]u8 = initial_registers,
    latched: [register_count]u8 = initial_registers,
    staging: [register_count]u8 = initial_registers,
    enabled_latch: u8 = 0,
    status: u8 = 0,
    state: ProtocolState = .inactive,
    mode: Mode = .linear,
    index: u8 = 0,
    writes: u8 = 0,
    mdr: u8 = 0,
    hold_tick: bool = false,
    dirty: bool = false,
    overflow: bool = false,
    fault: Fault = .none,

    pub fn power(self: *Device) void {
        self.enabled_latch = 0;
        self.status = 0;
        self.state = .inactive;
        self.mode = .linear;
        self.index = 0;
        self.writes = 0;
        self.mdr = 0;
        self.hold_tick = false;
        self.staging = self.live;
        self.fault = .none;
    }

    pub fn reset(self: *Device) void {
        self.power();
    }

    pub fn readPort(self: *Device, port: u16, open_bus: u8) u8 {
        return switch (port) {
            0x4840 => self.enabled_latch,
            0x4841 => blk: {
                if (self.state == .write) break :blk self.mdr;
                if (self.state != .read) break :blk 0;
                const result = self.latched[self.index];
                self.index = (self.index + 1) & 0x0F;
                self.ready();
                break :blk result;
            },
            0x4842 => blk: {
                break :blk self.status;
            },
            else => open_bus,
        };
    }

    pub fn writePort(self: *Device, port: u16, raw: u8) bool {
        switch (port) {
            0x4840 => {
                self.enabled_latch = raw & 3;
                if ((raw & 1) == 0) {
                    self.state = .inactive;
                    self.index = 0;
                    self.writes = 0;
                    const before = self.live[15];
                    self.live[15] &= 0x06;
                    self.staging = self.live;
                    if (before != self.live[15]) self.dirty = true;
                } else {
                    self.state = .mode_select;
                    self.index = 0;
                    self.writes = 0;
                    self.ready();
                }
                return true;
            },
            0x4841 => {
                const value = raw & 0x0F;
                switch (self.state) {
                    .inactive => {},
                    .mode_select => {
                        self.mode = switch (value) {
                            @intFromEnum(Mode.linear) => .linear,
                            @intFromEnum(Mode.indexed) => .indexed,
                            else => {
                                self.fault = .unsupported_mode;
                                return true;
                            },
                        };
                        self.state = .index_select;
                        self.index = 0;
                        self.latched = self.live;
                        self.mdr = value;
                        self.dirty = true;
                        self.ready();
                    },
                    .index_select => {
                        self.index = value;
                        self.latched = self.live;
                        if (self.mode == .linear) {
                            self.state = .write;
                            self.staging = self.live;
                            self.writes = 0;
                        } else {
                            self.state = .read;
                        }
                        self.mdr = value;
                        self.ready();
                    },
                    .read => {},
                    .write => {
                        self.writeRegister(value);
                        self.mdr = value;
                        self.ready();
                    },
                }
                return true;
            },
            0x4842 => return true,
            else => return false,
        }
    }

    pub fn isHalted(self: *const Device) bool {
        return haltedRegisters(&self.live);
    }

    pub fn advanceSeconds(self: *Device, seconds: u64) void {
        if (seconds == 0) return;
        if ((self.live[13] & 1) != 0) {
            self.hold_tick = true;
            return;
        }
        if ((self.live[15] & 3) != 0) return;
        advanceRegisters(&self.live, seconds, &self.overflow) catch {
            self.fault = .invalid_persistent_calendar;
            self.live[15] |= 2;
            self.dirty = true;
            return;
        };
        self.latched = self.live;
        self.staging = self.live;
        self.dirty = true;
    }

    pub fn loadPersistent(
        self: *Device,
        live: *const [register_count]u8,
        latched: *const [register_count]u8,
        halted: bool,
        overflow: bool,
    ) PersistentError!void {
        try validatePersistent(live, latched, halted);
        self.live = live.*;
        self.latched = latched.*;
        self.staging = live.*;
        self.overflow = overflow;
        self.dirty = false;
        self.fault = .none;
        self.power();
    }

    pub fn savePersistent(
        self: *const Device,
        live: *[register_count]u8,
        latched: *[register_count]u8,
        halted: *bool,
        overflow: *bool,
    ) void {
        live.* = self.live;
        latched.* = self.latched;
        halted.* = self.isHalted();
        overflow.* = self.overflow;
    }

    pub fn clearDirty(self: *Device) void {
        self.dirty = false;
    }

    fn ready(self: *Device) void {
        self.status |= 0x80;
    }

    fn writeRegister(self: *Device, value: u8) void {
        const target = self.index;
        var candidate = self.staging;
        const previous_calendar = validateRegisters(&candidate) catch null;
        const was_held = (candidate[13] & 1) != 0;

        if (target == 13) {
            if ((value & 8) != 0) {
                const seconds = candidate[0] + (candidate[1] & 7) * 10;
                candidate[0] = 0;
                candidate[1] &= 8;
                if (seconds >= 30) advanceRegisters(&candidate, 60, &self.overflow) catch {};
            }
        }
        const prior_control = candidate[15];
        candidate[target] = value;
        if (target == 15) {
            if (((prior_control ^ value) & 4) != 0) {
                if (previous_calendar) |calendar| registersFromCalendar(calendar, &candidate);
            }
            if ((value & 1) != 0 and (prior_control & 1) == 0) {
                candidate[0] = 0;
                candidate[1] &= 8;
            }
        }
        if (target == 13 and was_held and (value & 1) == 0 and self.hold_tick) {
            advanceRegisters(&candidate, 1, &self.overflow) catch {};
            self.hold_tick = false;
        }
        self.staging = candidate;
        self.writes +%= 1;
        self.index = (self.index + 1) & 0x0F;

        if (validateRegisters(&candidate)) |_| {
            self.live = candidate;
            self.latched = candidate;
            self.dirty = true;
            self.fault = .none;
        } else |_| {
            if (self.writes >= register_count) {
                self.staging = self.live;
                self.fault = .invalid_write;
            }
        }
    }
};

pub fn validatePersistent(
    live: *const [register_count]u8,
    latched: *const [register_count]u8,
    halted: bool,
) PersistentError!void {
    _ = try validateRegisters(live);
    if (!allZero(latched)) _ = validateRegisters(latched) catch return error.InvalidEpsonLatch;
    if (halted != haltedRegisters(live)) return error.InvalidEpsonHaltState;
}

pub fn calendarFromRegisters(registers: *const [register_count]u8) PersistentError!Calendar {
    return validateRegisters(registers);
}

fn validateRegisters(registers: *const [register_count]u8) PersistentError!Calendar {
    for (registers) |value| if (value > 0x0F) return error.InvalidEpsonControl;
    const second_high = registers[1] & 7;
    const minute_high = registers[3] & 7;
    const hour_high = registers[5] & 3;
    const day_high = registers[7] & 3;
    const month_high = registers[9] & 1;
    if (registers[0] > 9 or second_high > 5 or registers[2] > 9 or minute_high > 5 or
        registers[4] > 9 or registers[6] > 9 or day_high > 3 or
        registers[8] > 9 or month_high > 1 or registers[10] > 9 or registers[11] > 9)
    {
        return error.InvalidEpsonCalendar;
    }
    const raw_hour = registers[4] + hour_high * 10;
    const astronomical = (registers[15] & 4) != 0;
    const hour: u8 = if (astronomical)
        raw_hour
    else if (raw_hour >= 1 and raw_hour <= 12)
        @as(u8, if ((registers[5] & 4) != 0) 12 else 0) + (raw_hour % 12)
    else
        return error.InvalidEpsonCalendar;
    const result = Calendar{
        .second = registers[0] + second_high * 10,
        .minute = registers[2] + minute_high * 10,
        .hour = hour,
        .day = registers[6] + day_high * 10,
        .month = registers[8] + month_high * 10,
        .year = registers[10] + registers[11] * 10,
        .weekday = registers[12] & 7,
    };
    if (result.hour > 23 or result.month == 0 or result.month > 12 or result.day == 0 or
        result.day > monthDays(fullYear(result.year), result.month)) return error.InvalidEpsonCalendar;
    if (result.weekday > 6) return error.InvalidEpsonWeekday;
    return result;
}

fn haltedRegisters(registers: *const [register_count]u8) bool {
    return (registers[13] & 1) != 0 or (registers[15] & 3) != 0;
}

fn advanceRegisters(registers: *[register_count]u8, seconds: u64, overflow: *bool) PersistentError!void {
    const current = try validateRegisters(registers);
    const seconds_of_day = @as(u64, current.hour) * 3600 + @as(u64, current.minute) * 60 + current.second;
    const total = seconds_of_day + seconds;
    const added_days = total / 86_400;
    const remainder = total % 86_400;
    const calendar_enabled = (registers[13] & 2) != 0;
    const old_day = dayOfCycle(current);
    const cycle_days: u64 = 36_525;
    const unwrapped = @as(u64, old_day) + added_days;
    if (calendar_enabled and unwrapped >= cycle_days) overflow.* = true;
    const date = if (calendar_enabled) calendarForDay(@intCast(unwrapped % cycle_days)) else current;
    const weekday: u8 = if (calendar_enabled)
        @intCast((@as(u64, current.weekday) + added_days) % 7)
    else
        current.weekday;
    const next = Calendar{
        .second = @intCast(remainder % 60),
        .minute = @intCast((remainder / 60) % 60),
        .hour = @intCast(remainder / 3600),
        .day = date.day,
        .month = date.month,
        .year = date.year,
        .weekday = weekday,
    };
    registersFromCalendar(next, registers);
}

fn registersFromCalendar(calendar: Calendar, registers: *[register_count]u8) void {
    writeClockRegisters(calendar, registers);
    writeDateRegisters(calendar, registers);
}

noinline fn writeClockRegisters(calendar: Calendar, registers: *[register_count]u8) void {
    const second_flags = registers[1] & 8;
    const minute_flags = registers[3] & 8;
    const hour_flags = registers[5] & 8;
    registers[0] = calendar.second % 10;
    registers[1] = calendar.second / 10 | second_flags;
    registers[2] = calendar.minute % 10;
    registers[3] = calendar.minute / 10 | minute_flags;
    if ((registers[15] & 4) != 0) {
        registers[4] = calendar.hour % 10;
        registers[5] = calendar.hour / 10 | hour_flags;
    } else {
        const hour12: u8 = if (calendar.hour % 12 == 0) 12 else calendar.hour % 12;
        var meridian: u8 = 0;
        if (calendar.hour >= 12) meridian = 4;
        registers[4] = hour12 % 10;
        registers[5] = hour12 / 10 | meridian | hour_flags;
    }
}

noinline fn writeDateRegisters(calendar: Calendar, registers: *[register_count]u8) void {
    const day_flags = registers[7] & 0x0C;
    const month_flags = registers[9] & 0x0E;
    const weekday_flags = registers[12] & 8;
    registers[6] = calendar.day % 10;
    registers[7] = calendar.day / 10 | day_flags;
    registers[8] = calendar.month % 10;
    registers[9] = calendar.month / 10 | month_flags;
    registers[10] = calendar.year % 10;
    registers[11] = calendar.year / 10;
    registers[12] = calendar.weekday | weekday_flags;
}

fn dayOfCycle(calendar: Calendar) u32 {
    var day: u32 = 0;
    var index: u8 = 0;
    const target = yearIndex(calendar.year);
    while (index < target) : (index += 1) day += yearDays(yearForIndex(index));
    var month: u8 = 1;
    const year = fullYear(calendar.year);
    while (month < calendar.month) : (month += 1) day += monthDays(year, month);
    return day + calendar.day - 1;
}

fn calendarForDay(raw_day: u32) Calendar {
    var day = raw_day;
    var index: u8 = 0;
    while (index < 100) : (index += 1) {
        const days = yearDays(yearForIndex(index));
        if (day < days) break;
        day -= days;
    }
    const year = yearForIndex(index);
    var month: u8 = 1;
    while (month < 12) : (month += 1) {
        const days = monthDays(year, month);
        if (day < days) break;
        day -= days;
    }
    return .{
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = @intCast(day + 1),
        .month = month,
        .year = if (year >= 2000) @intCast(year - 2000) else @intCast(year - 1900),
        .weekday = 0,
    };
}

fn yearIndex(year: u8) u8 {
    return if (year >= 90) year - 90 else year + 10;
}

fn yearForIndex(index: u8) u16 {
    return if (index < 10) 1990 + @as(u16, index) else 2000 + @as(u16, index - 10);
}

fn fullYear(year: u8) u16 {
    return if (year >= 90) 1900 + @as(u16, year) else 2000 + @as(u16, year);
}

fn yearDays(year: u16) u16 {
    return if (leapYear(year)) 366 else 365;
}

fn monthDays(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leapYear(year)) 29 else 28,
        else => 0,
    };
}

fn leapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn allZero(registers: *const [register_count]u8) bool {
    for (registers) |value| if (value != 0) return false;
    return true;
}
