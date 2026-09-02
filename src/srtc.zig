pub const access_master_cycles: u8 = 6;
pub const register_count: usize = 13;
pub const persisted_register_count: usize = 16;
pub const read_port: u16 = 0x2800;
pub const write_port: u16 = 0x2801;

pub const Mode = enum(u8) {
    ready,
    command,
    read,
    write,
};

pub const Fault = enum(u8) {
    none,
    unsupported_command,
    invalid_write,
    invalid_persistent_calendar,
    invalid_persistent_latch,
    invalid_halt_state,
};

pub const PersistentError = error{
    InvalidSrtcCalendar,
    InvalidSrtcWeekday,
    InvalidSrtcLatch,
    InvalidSrtcHaltState,
    InvalidSrtcReserved,
};

pub const Calendar = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u16,
    weekday: u8,
};

/// Sharp S-RTC state. Protocol writes are staged until all twelve writable
/// nibbles form one valid calendar, so undocumented values never become live
/// or persistable state.
pub const Device = struct {
    live: [persisted_register_count]u8 = .{0} ** persisted_register_count,
    latched: [persisted_register_count]u8 = .{0} ** persisted_register_count,
    write_staging: [12]u8 = .{0} ** 12,
    mode: Mode = .read,
    index: i8 = -1,
    halted: bool = true,
    overflow: bool = false,
    dirty: bool = false,
    fault: Fault = .none,

    pub fn power(self: *Device) void {
        self.mode = .read;
        self.index = -1;
        self.write_staging = .{0} ** 12;
        self.fault = .none;
    }

    pub fn reset(self: *Device) void {
        self.power();
    }

    pub fn read(self: *Device, address: u32, open_bus: u8) ?u8 {
        if (!mapped(address)) return null;
        const port: u16 = @truncate(address);
        if (port != read_port) return open_bus;
        if (self.mode != .read) return 0;
        if (self.index < 0) {
            self.latched = self.live;
            self.index = 0;
            self.dirty = true;
            return 0x0F;
        }
        if (self.index >= register_count) {
            self.index = -1;
            return 0x0F;
        }
        const result = self.latched[@intCast(self.index)];
        self.index += 1;
        return result;
    }

    pub fn write(self: *Device, address: u32, raw: u8) bool {
        if (!mapped(address)) return false;
        const port: u16 = @truncate(address);
        if (port != write_port) return true;
        const value = raw & 0x0F;
        if (value == 0x0D) {
            self.mode = .read;
            self.index = -1;
            return true;
        }
        if (value == 0x0E) {
            self.mode = .command;
            return true;
        }
        if (value == 0x0F) return true;

        switch (self.mode) {
            .command => switch (value) {
                0 => {
                    self.mode = .write;
                    self.index = 0;
                    self.write_staging = .{0} ** 12;
                },
                4 => {
                    self.mode = .ready;
                    self.index = -1;
                    self.live = .{0} ** persisted_register_count;
                    self.latched = .{0} ** persisted_register_count;
                    self.halted = true;
                    self.overflow = false;
                    self.dirty = true;
                    self.fault = .none;
                },
                else => {
                    self.mode = .ready;
                    self.index = -1;
                    self.fault = .unsupported_command;
                },
            },
            .write => {
                if (self.index < 0 or self.index >= self.write_staging.len) return true;
                self.write_staging[@intCast(self.index)] = value;
                self.index += 1;
                if (self.index == self.write_staging.len) self.commitWrite();
            },
            .ready, .read => {},
        }
        return true;
    }

    pub fn advanceSeconds(self: *Device, seconds: u64) void {
        if (seconds == 0 or self.halted) return;
        const current = calendarFromRegisters(&self.live, true) catch {
            self.halted = true;
            self.fault = .invalid_persistent_calendar;
            return;
        };
        const seconds_of_day = @as(u64, current.hour) * 3600 + @as(u64, current.minute) * 60 + current.second;
        const total = seconds_of_day + seconds;
        const added_days = total / 86_400;
        const remainder = total % 86_400;
        const cycle_days: u64 = daysInYearCycle();
        const original_day = dayOfCycle(current);
        const unwrapped = @as(u64, original_day) + added_days;
        if (unwrapped >= cycle_days) self.overflow = true;
        const next = calendarForDay(@intCast(unwrapped % cycle_days));
        const updated = Calendar{
            .second = @intCast(remainder % 60),
            .minute = @intCast((remainder / 60) % 60),
            .hour = @intCast(remainder / 3600),
            .day = next.day,
            .month = next.month,
            .year = next.year,
            .weekday = calculateWeekday(next.year, next.month, next.day),
        };
        registersFromCalendar(updated, &self.live);
        self.dirty = true;
    }

    pub fn loadPersistent(
        self: *Device,
        live: *const [persisted_register_count]u8,
        latched: *const [persisted_register_count]u8,
        halted: bool,
        overflow: bool,
    ) PersistentError!void {
        try validatePersistent(live, latched, halted);
        self.live = live.*;
        self.latched = latched.*;
        self.halted = halted;
        self.overflow = overflow;
        self.dirty = false;
        self.fault = .none;
        self.power();
    }

    pub fn savePersistent(
        self: *const Device,
        live: *[persisted_register_count]u8,
        latched: *[persisted_register_count]u8,
        halted: *bool,
        overflow: *bool,
    ) void {
        live.* = self.live;
        latched.* = self.latched;
        halted.* = self.halted;
        overflow.* = self.overflow;
    }

    pub fn clearDirty(self: *Device) void {
        self.dirty = false;
    }

    fn commitWrite(self: *Device) void {
        var candidate: [persisted_register_count]u8 = .{0} ** persisted_register_count;
        @memcpy(candidate[0..12], self.write_staging[0..]);
        var calendar = calendarFromRegisters(&candidate, false) catch {
            self.mode = .ready;
            self.index = -1;
            self.fault = .invalid_write;
            return;
        };
        calendar.weekday = calculateWeekday(calendar.year, calendar.month, calendar.day);
        registersFromCalendar(calendar, &candidate);
        self.live = candidate;
        self.latched = candidate;
        self.halted = false;
        self.dirty = true;
        self.fault = .none;
    }
};

pub fn mapped(address: u32) bool {
    if (address > 0x00FF_FFFF) return false;
    const bank: u8 = @truncate(address >> 16);
    const port: u16 = @truncate(address);
    return (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and
        (port == read_port or port == write_port);
}

pub fn validatePersistent(
    live: *const [persisted_register_count]u8,
    latched: *const [persisted_register_count]u8,
    halted: bool,
) PersistentError!void {
    if (!allZero(live[13..]) or !allZero(latched[13..])) return error.InvalidSrtcReserved;
    if (halted) {
        if (!allZero(live[0..register_count])) return error.InvalidSrtcHaltState;
    } else {
        _ = try calendarFromRegisters(live, true);
    }
    if (!allZero(latched[0..register_count])) {
        _ = calendarFromRegisters(latched, true) catch return error.InvalidSrtcLatch;
    }
}

pub fn calendarFromRegisters(registers: *const [persisted_register_count]u8, check_weekday: bool) PersistentError!Calendar {
    for (registers[0..12]) |value| if (value > 0x0F) return error.InvalidSrtcCalendar;
    if (registers[0] > 9 or registers[1] > 5 or registers[2] > 9 or registers[3] > 5 or
        registers[4] > 9 or registers[5] > 2 or registers[6] > 9 or registers[7] > 3 or
        registers[8] < 1 or registers[8] > 12 or registers[9] > 9 or registers[10] > 9 or
        registers[11] > 9)
    {
        return error.InvalidSrtcCalendar;
    }
    const calendar = Calendar{
        .second = registers[0] + registers[1] * 10,
        .minute = registers[2] + registers[3] * 10,
        .hour = registers[4] + registers[5] * 10,
        .day = registers[6] + registers[7] * 10,
        .month = registers[8],
        .year = @as(u16, registers[9]) + @as(u16, registers[10]) * 10 + @as(u16, registers[11]) * 100,
        .weekday = registers[12],
    };
    if (calendar.hour > 23 or calendar.day == 0 or calendar.day > monthDays(calendar.year, calendar.month)) {
        return error.InvalidSrtcCalendar;
    }
    if (calendar.weekday > 6) return error.InvalidSrtcWeekday;
    if (check_weekday and calendar.weekday != calculateWeekday(calendar.year, calendar.month, calendar.day)) {
        return error.InvalidSrtcWeekday;
    }
    return calendar;
}

pub fn registersFromCalendar(calendar: Calendar, out: *[persisted_register_count]u8) void {
    @memset(out, 0);
    out[0] = calendar.second % 10;
    out[1] = calendar.second / 10;
    out[2] = calendar.minute % 10;
    out[3] = calendar.minute / 10;
    out[4] = calendar.hour % 10;
    out[5] = calendar.hour / 10;
    out[6] = calendar.day % 10;
    out[7] = calendar.day / 10;
    out[8] = calendar.month;
    out[9] = @intCast(calendar.year % 10);
    out[10] = @intCast((calendar.year / 10) % 10);
    out[11] = @intCast(calendar.year / 100);
    out[12] = calendar.weekday;
}

pub fn calculateWeekday(year: u16, month: u8, day: u8) u8 {
    const calendar = Calendar{ .second = 0, .minute = 0, .hour = 0, .day = day, .month = month, .year = year, .weekday = 0 };
    return @intCast((dayOfCycle(calendar) + 3) % 7); // 1000-01-01 was Wednesday.
}

pub fn isLeapYear(year: u16) bool {
    const absolute: u16 = 1000 + year;
    return absolute % 4 == 0 and (absolute % 100 != 0 or absolute % 400 == 0);
}

pub fn monthDays(year: u16, month: u8) u8 {
    const ordinary = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month < 1 or month > 12) return 0;
    return ordinary[month - 1] + @as(u8, @intFromBool(month == 2 and isLeapYear(year)));
}

fn dayOfCycle(calendar: Calendar) u32 {
    var result: u32 = 0;
    var year: u16 = 0;
    while (year < calendar.year) : (year += 1) result += if (isLeapYear(year)) 366 else 365;
    var month: u8 = 1;
    while (month < calendar.month) : (month += 1) result += monthDays(calendar.year, month);
    return result + calendar.day - 1;
}

fn calendarForDay(raw_day: u32) Calendar {
    var day = raw_day;
    var year: u16 = 0;
    while (year < 999) : (year += 1) {
        const length: u16 = if (isLeapYear(year)) 366 else 365;
        if (day < length) break;
        day -= length;
    }
    var month: u8 = 1;
    while (month < 12) : (month += 1) {
        const length = monthDays(year, month);
        if (day < length) break;
        day -= length;
    }
    return .{
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = @intCast(day + 1),
        .month = month,
        .year = year,
        .weekday = 0,
    };
}

fn daysInYearCycle() u64 {
    var result: u64 = 0;
    var year: u16 = 0;
    while (year < 1000) : (year += 1) result += if (isLeapYear(year)) 366 else 365;
    return result;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
