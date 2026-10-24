const std = @import("std");

const document_module = @import("document.zig");
const scalar = @import("scalar.zig");

const assert = std.debug.assert;

const Version = document_module.Version;

pub const Datetime = struct {
    day: u8,
    hour: u8,
    kind: Kind,
    minute: u8,
    month: u8,
    nanosecond: u32,
    offset_minutes: i16,
    second: u8,
    spelling: Spelling,
    year: u16,

    pub const Kind = enum {
        date_local,
        datetime_local,
        datetime_offset,
        time_local,
    };

    pub const Spelling = packed struct(u8) {
        fraction_present: bool,
        offset_zulu: bool,
        second_present: bool,
        padding: u5,

        pub const canonical: Spelling = .{
            .fraction_present = false,
            .offset_zulu = false,
            .second_present = true,
            .padding = 0,
        };
    };

    pub fn format(datetime: Datetime, out: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(valid(&datetime));
        assert(datetime.nanosecond < nanosecond_count_per_second);

        var text: Text = .{ .bytes = undefined, .length = 0 };

        switch (datetime.kind) {
            .date_local => date_fill(&datetime, &text),
            .datetime_local => {
                date_fill(&datetime, &text);
                text.byte_push('T');
                time_fill(&datetime, &text);
            },
            .datetime_offset => {
                date_fill(&datetime, &text);
                text.byte_push('T');
                time_fill(&datetime, &text);
                offset_fill(&datetime, &text);
            },
            .time_local => time_fill(&datetime, &text),
        }

        try out.writeAll(text.bytes[0..text.length]);
    }
};

const Text = struct {
    bytes: [text_bytes_max]u8,
    length: u32,

    fn byte_push(text: *Text, byte: u8) void {
        assert(text.length < text_bytes_max);
        assert(byte < 0x80);

        text.bytes[text.length] = byte;
        text.length += 1;
    }

    fn pair_push(text: *Text, value: u32) void {
        assert(value < 100);
        assert(text.length + 2 <= text_bytes_max);

        text.bytes[text.length..][0..2].* = std.fmt.digits2(@intCast(value));
        text.length += 2;
    }
};

const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const fraction_digit_count_max: u32 = 9;
const nanosecond_count_per_second: u32 = 1_000_000_000;
const offset_minutes_max: u16 = 23 * 60 + 59;
const text_bytes_max: u32 = 40;
const year_max: u16 = 9999;

const datetime_empty: Datetime = .{
    .day = 0,
    .hour = 0,
    .kind = .time_local,
    .minute = 0,
    .month = 0,
    .nanosecond = 0,
    .offset_minutes = 0,
    .second = 0,
    .spelling = .canonical,
    .year = 0,
};

comptime {
    assert(@sizeOf(Datetime) == 16);
    assert(@sizeOf(Datetime.Spelling) == 1);
    assert(std.math.pow(u32, 10, fraction_digit_count_max) == nanosecond_count_per_second);
    assert(offset_minutes_max < std.math.maxInt(i16));
}

pub fn parse(text: []const u8, version: Version) error{DatetimeInvalid}!Datetime {
    assert(text.len > 0);
    assert(text.len <= document_module.source_bytes_max);
    comptime assert(std.enums.values(@TypeOf(version)).len == 2);

    var result = datetime_empty;

    try fields_parse(text, &result);

    if (!result.spelling.second_present) {
        if (version == .v1_0) return error.DatetimeInvalid;
    }

    assert(result.nanosecond < nanosecond_count_per_second);
    assert(result.spelling.padding == 0);

    return result;
}

fn fields_parse(text: []const u8, result: *Datetime) error{DatetimeInvalid}!void {
    assert(text.len > 0);
    assert(result.kind == .time_local);

    if (scalar.time_shaped(text)) {
        const end = try time_parse(text, 0, result);
        if (end != text.len) return error.DatetimeInvalid;
        return;
    }

    try date_parse(text, result);

    if (text.len == 10) {
        result.kind = .date_local;

        return;
    }

    switch (text[10]) {
        'T', 't', ' ' => {},
        else => return error.DatetimeInvalid,
    }

    const end = try time_parse(text, 11, result);

    result.kind = .datetime_local;

    if (end == text.len) return;

    try offset_parse(text[end..], result);

    result.kind = .datetime_offset;
}

pub fn valid(datetime: *const Datetime) bool {
    if (datetime.spelling.padding != 0) return false;

    const date = switch (datetime.kind) {
        .date_local, .datetime_local, .datetime_offset => date_valid(datetime),
        .time_local => datetime.year == 0 and datetime.month == 0 and datetime.day == 0,
    };

    const time = switch (datetime.kind) {
        .date_local => time_absent(datetime),
        .datetime_local, .datetime_offset, .time_local => time_valid(datetime),
    };

    const offset = switch (datetime.kind) {
        .datetime_offset => offset_valid(datetime),
        .date_local, .datetime_local, .time_local => offset_absent(datetime),
    };

    const result = date and time and offset;

    if (result) assert(datetime.month <= 12);
    if (result) assert(datetime.nanosecond < nanosecond_count_per_second);

    return result;
}

fn date_valid(datetime: *const Datetime) bool {
    assert(datetime.kind != .time_local);

    if (datetime.year > year_max) return false;
    if (datetime.month < 1) return false;
    if (datetime.month > 12) return false;
    if (datetime.day < 1) return false;
    return datetime.day <= month_length(datetime.year, datetime.month);
}

fn time_valid(datetime: *const Datetime) bool {
    assert(datetime.kind != .date_local);

    if (datetime.hour > 23) return false;
    if (datetime.minute > 59) return false;
    if (datetime.second > 59) return false;
    if (datetime.nanosecond >= nanosecond_count_per_second) return false;
    if (datetime.spelling.second_present) return true;
    if (datetime.second != 0) return false;
    if (datetime.nanosecond != 0) return false;
    return !datetime.spelling.fraction_present;
}

fn time_absent(datetime: *const Datetime) bool {
    assert(datetime.kind == .date_local);

    const spelling: u8 = @bitCast(datetime.spelling);
    const canonical: u8 = @bitCast(Datetime.Spelling.canonical);

    if (datetime.hour != 0) return false;
    if (datetime.minute != 0) return false;
    if (datetime.second != 0) return false;
    if (datetime.nanosecond != 0) return false;
    return spelling == canonical;
}

fn offset_valid(datetime: *const Datetime) bool {
    assert(datetime.kind == .datetime_offset);

    if (@abs(datetime.offset_minutes) > offset_minutes_max) return false;
    if (datetime.spelling.offset_zulu) return datetime.offset_minutes == 0;
    return true;
}

fn offset_absent(datetime: *const Datetime) bool {
    assert(datetime.kind != .datetime_offset);

    if (datetime.offset_minutes != 0) return false;
    return !datetime.spelling.offset_zulu;
}

fn date_parse(text: []const u8, result: *Datetime) error{DatetimeInvalid}!void {
    assert(text.len > 0);
    assert(result.kind == .time_local);

    if (text.len < 10) return error.DatetimeInvalid;
    if (text[4] != '-') return error.DatetimeInvalid;
    if (text[7] != '-') return error.DatetimeInvalid;

    const year = try digits_value(text[0..4]);
    const month = try digits_value(text[5..7]);
    const day = try digits_value(text[8..10]);

    if (month < 1) return error.DatetimeInvalid;
    if (month > 12) return error.DatetimeInvalid;
    if (day < 1) return error.DatetimeInvalid;
    if (day > month_length(year, @intCast(month))) return error.DatetimeInvalid;

    result.year = @intCast(year);
    result.month = @intCast(month);
    result.day = @intCast(day);
}

fn month_length(year: u32, month: u8) u32 {
    assert(year <= year_max);
    assert(month >= 1);
    assert(month <= 12);

    var result: u32 = days_in_month[month - 1];

    if (month == 2) {
        const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;

        if (leap) result = 29;
    }

    assert(result >= 28);

    return result;
}

fn time_parse(text: []const u8, start: u32, datetime: *Datetime) error{DatetimeInvalid}!u32 {
    assert(start <= text.len);
    assert(text.len <= document_module.source_bytes_max);

    if (text.len - start < 5) return error.DatetimeInvalid;
    if (text[start + 2] != ':') return error.DatetimeInvalid;

    const hour = try digits_value(text[start .. start + 2]);
    const minute = try digits_value(text[start + 3 .. start + 5]);

    if (hour > 23) return error.DatetimeInvalid;
    if (minute > 59) return error.DatetimeInvalid;

    datetime.hour = @intCast(hour);
    datetime.minute = @intCast(minute);

    const minute_end = start + 5;
    if (byte_at(text, minute_end) != ':') return second_omit(text, minute_end, datetime);
    if (text.len - minute_end < 3) return error.DatetimeInvalid;

    const second = try digits_value(text[minute_end + 1 .. minute_end + 3]);
    if (second > 59) return error.DatetimeInvalid;

    datetime.second = @intCast(second);

    const end = minute_end + 3;
    var result = end;

    if (byte_at(text, end) == '.') result = try fraction_parse(text, end + 1, datetime);

    assert(result >= end);
    assert(result <= text.len);

    return result;
}

fn second_omit(text: []const u8, end: u32, datetime: *Datetime) error{DatetimeInvalid}!u32 {
    assert(end <= text.len);
    assert(datetime.spelling.second_present);

    if (byte_at(text, end) == '.') return error.DatetimeInvalid;

    datetime.spelling.second_present = false;

    return end;
}

fn fraction_parse(text: []const u8, start: u32, result: *Datetime) error{DatetimeInvalid}!u32 {
    assert(start <= text.len);
    assert(result.nanosecond == 0);

    var index = start;
    var nanosecond: u32 = 0;
    var digit_count: u32 = 0;

    for (text[start..]) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        if (digit_count < fraction_digit_count_max) {
            nanosecond = nanosecond * 10 + (byte - '0');
            digit_count += 1;
        }

        index += 1;
    }

    if (index == start) return error.DatetimeInvalid;

    for (digit_count..fraction_digit_count_max) |_| nanosecond *= 10;

    result.nanosecond = nanosecond;
    result.spelling.fraction_present = true;

    assert(result.nanosecond < nanosecond_count_per_second);

    return index;
}

fn offset_parse(text: []const u8, result: *Datetime) error{DatetimeInvalid}!void {
    assert(text.len > 0);
    assert(result.kind == .datetime_local);

    if (text.len == 1) {
        switch (text[0]) {
            'Z', 'z' => {
                result.spelling.offset_zulu = true;

                return;
            },
            else => return error.DatetimeInvalid,
        }
    }

    if (text.len != 6) return error.DatetimeInvalid;
    if (text[3] != ':') return error.DatetimeInvalid;

    const sign: i16 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.DatetimeInvalid,
    };

    const hour = try digits_value(text[1..3]);
    const minute = try digits_value(text[4..6]);

    if (hour > 23) return error.DatetimeInvalid;
    if (minute > 59) return error.DatetimeInvalid;

    result.offset_minutes = sign * @as(i16, @intCast(hour * 60 + minute));
}

inline fn digits_value(digits: []const u8) error{DatetimeInvalid}!u32 {
    assert(digits.len == 2 or digits.len == 4);
    assert(document_module.source_bytes_max > digits.len);

    var value: u32 = 0;

    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return error.DatetimeInvalid;

        value = value * 10 + (byte - '0');
    }

    assert(value < 10_000);

    return value;
}

fn byte_at(text: []const u8, index: u32) u8 {
    assert(index <= text.len);
    assert(text.len <= document_module.source_bytes_max);

    if (index == text.len) return 0;
    return text[index];
}

fn date_fill(datetime: *const Datetime, text: *Text) void {
    assert(datetime.kind != .time_local);
    assert(datetime.year <= year_max);

    text.pair_push(@divFloor(datetime.year, 100));
    text.pair_push(datetime.year % 100);
    text.byte_push('-');
    text.pair_push(datetime.month);
    text.byte_push('-');
    text.pair_push(datetime.day);
}

fn time_fill(datetime: *const Datetime, text: *Text) void {
    assert(datetime.kind != .date_local);
    assert(datetime.hour <= 23);

    text.pair_push(datetime.hour);
    text.byte_push(':');
    text.pair_push(datetime.minute);

    if (datetime.spelling.second_present) {
        text.byte_push(':');
        text.pair_push(datetime.second);
    }

    if (datetime.spelling.fraction_present) return fraction_fill(datetime.nanosecond, text);
    if (datetime.nanosecond != 0) return fraction_fill(datetime.nanosecond, text);
}

fn fraction_fill(nanosecond: u32, text: *Text) void {
    assert(nanosecond < nanosecond_count_per_second);
    assert(text.length + fraction_digit_count_max + 1 <= text_bytes_max);

    var digits: [fraction_digit_count_max]u8 = undefined;
    var rest = nanosecond;

    for (0..fraction_digit_count_max) |position| {
        digits[fraction_digit_count_max - 1 - position] = '0' + @as(u8, @intCast(rest % 10));
        rest = @divFloor(rest, 10);
    }

    assert(rest == 0);

    const significant = std.mem.trimEnd(u8, &digits, "0");
    const kept = if (significant.len == 0) "0" else significant;

    text.byte_push('.');
    @memcpy(text.bytes[text.length..][0..kept.len], kept);
    text.length += @intCast(kept.len);
}

fn offset_fill(datetime: *const Datetime, text: *Text) void {
    assert(datetime.kind == .datetime_offset);
    assert(@abs(datetime.offset_minutes) <= offset_minutes_max);

    if (datetime.spelling.offset_zulu) return text.byte_push('Z');

    const magnitude: u16 = @abs(datetime.offset_minutes);

    text.byte_push(if (datetime.offset_minutes < 0) '-' else '+');
    text.pair_push(@divFloor(magnitude, 60));
    text.byte_push(':');
    text.pair_push(magnitude % 60);
}

const testing = std.testing;

const FormatCase = struct {
    expected: []const u8,
    text: []const u8,
};

fn format_expect(case: *const FormatCase) !void {
    assert(case.expected.len > 0);
    assert(case.text.len > 0);

    const datetime = try parse(case.text, .v1_1);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try datetime.format(&writer);
    try testing.expectEqualStrings(case.expected, writer.buffered());

    const reparsed = try parse(writer.buffered(), .v1_1);

    try testing.expectEqual(datetime, reparsed);
}

test "the specification's datetimes decode to their fields" {
    const offset = try parse("1979-05-27T00:32:00.999999-07:00", .v1_1);

    try testing.expectEqual(Datetime.Kind.datetime_offset, offset.kind);
    try testing.expectEqual(@as(u16, 1979), offset.year);
    try testing.expectEqual(@as(u8, 5), offset.month);
    try testing.expectEqual(@as(u8, 0), offset.hour);
    try testing.expectEqual(@as(u8, 32), offset.minute);
    try testing.expectEqual(@as(u32, 999_999_000), offset.nanosecond);
    try testing.expectEqual(@as(i16, -420), offset.offset_minutes);

    const space = try parse("1979-05-27 07:32:00Z", .v1_1);

    try testing.expectEqual(Datetime.Kind.datetime_offset, space.kind);
    try testing.expectEqual(@as(i16, 0), space.offset_minutes);

    const local = try parse("1979-05-27T07:32:00", .v1_1);
    const date = try parse("1979-05-27", .v1_1);

    try testing.expectEqual(Datetime.Kind.datetime_local, local.kind);
    try testing.expectEqual(Datetime.Kind.date_local, date.kind);

    const time = try parse("00:32:00.999999", .v1_1);
    const truncated = try parse("12:00:00.1234567891", .v1_1);

    try testing.expectEqual(Datetime.Kind.time_local, time.kind);
    try testing.expectEqual(@as(u32, 999_999_000), time.nanosecond);
    try testing.expectEqual(@as(u32, 123_456_789), truncated.nanosecond);
}

test "calendar rules decide which dates exist" {
    _ = try parse("2000-02-29", .v1_1);
    _ = try parse("2024-02-29", .v1_1);
    _ = try parse("1979-04-30", .v1_1);

    const refused = [_][]const u8{
        "1900-02-29",
        "2023-02-29",
        "1979-04-31",
        "1979-13-01",
        "1979-00-10",
        "1979-01-00",
        "1979-01-32",
        "24:00:00",
        "23:60:00",
        "23:59:60",
        "1979-05-27T07:32:00+24:00",
        "1979-05-27T07:32:00+05:60",
        "1979-05-27T07:32:00.",
        "1979-05-27X07:32:00",
        "79-05-27",
    };

    for (refused) |text| try testing.expectError(error.DatetimeInvalid, parse(text, .v1_1));
}

test "a time without seconds is refused by 1.0 and read by 1.1 with its spelling" {
    const short = [_][]const u8{
        "07:32",
        "1979-05-27T07:32",
        "1979-05-27 07:32Z",
        "1979-05-27t07:32-07:00",
    };

    for (short) |text| {
        const datetime = try parse(text, .v1_1);

        try testing.expect(!datetime.spelling.second_present);
        try testing.expectEqual(@as(u8, 0), datetime.second);
        try testing.expectEqual(@as(u8, 32), datetime.minute);
        try testing.expectError(error.DatetimeInvalid, parse(text, .v1_0));
    }

    const full = try parse("07:32:00", .v1_0);

    try testing.expect(full.spelling.second_present);

    const refused = [_][]const u8{ "07:32.5", "07:32:", "07:3", "1979-05-27T07:32.000Z" };

    for (refused) |text| try testing.expectError(error.DatetimeInvalid, parse(text, .v1_1));
}

test "the spelling records a fraction, a zulu offset, and the presence of seconds" {
    const zulu = try parse("1979-05-27T07:32:00.000z", .v1_1);
    const numeric = try parse("1979-05-27T07:32:00+00:00", .v1_1);

    try testing.expect(zulu.spelling.fraction_present);
    try testing.expect(zulu.spelling.offset_zulu);
    try testing.expect(zulu.spelling.second_present);
    try testing.expectEqual(@as(u32, 0), zulu.nanosecond);
    try testing.expect(!numeric.spelling.fraction_present);
    try testing.expect(!numeric.spelling.offset_zulu);
    try testing.expectEqual(zulu.offset_minutes, numeric.offset_minutes);

    const date = try parse("1979-05-27", .v1_1);

    try testing.expectEqual(Datetime.Spelling.canonical, date.spelling);
}

test "format writes each kind the way toml-rs displays it" {
    const cases = [_]FormatCase{
        .{ .expected = "1979-05-27", .text = "1979-05-27" },
        .{ .expected = "0001-01-01T00:00:00", .text = "0001-01-01t00:00:00" },
        .{ .expected = "1979-05-27T07:32:00.5-07:30", .text = "1979-05-27 07:32:00.5-07:30" },
        .{ .expected = "1979-05-27T07:32:00Z", .text = "1979-05-27T07:32:00z" },
        .{ .expected = "1979-05-27T07:32:00+00:00", .text = "1979-05-27T07:32:00-00:00" },
        .{ .expected = "00:32:00.0", .text = "00:32:00.000" },
        .{ .expected = "23:59:59.123456789", .text = "23:59:59.123456789123" },
        .{ .expected = "13:37", .text = "13:37" },
        .{ .expected = "1979-05-27T07:32-08:00", .text = "1979-05-27T07:32-08:00" },
    };

    for (&cases) |*case| try format_expect(case);
}

test "format writes a fraction for a nonzero nanosecond even without its spelling bit" {
    const datetime: Datetime = .{
        .day = 0,
        .hour = 7,
        .kind = .time_local,
        .minute = 32,
        .month = 0,
        .nanosecond = 50_000_000,
        .offset_minutes = 0,
        .second = 9,
        .spelling = .canonical,
        .year = 0,
    };

    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try datetime.format(&writer);
    try testing.expectEqualStrings("07:32:09.05", writer.buffered());
}

test "a datetime is valid only when its fields fit its kind and its spelling" {
    var zulu = try parse("1979-05-27T07:32:00Z", .v1_1);

    try testing.expect(valid(&zulu));

    zulu.offset_minutes = 60;

    try testing.expect(!valid(&zulu));

    var short = try parse("07:32", .v1_1);

    short.nanosecond = 1;

    try testing.expect(!valid(&short));

    var date = try parse("1979-05-27", .v1_1);

    date.hour = 1;

    try testing.expect(!valid(&date));

    var leap = try parse("2024-02-29", .v1_1);

    leap.year = 2023;

    try testing.expect(!valid(&leap));

    var padded = try parse("07:32:00", .v1_1);

    padded.spelling.padding = 1;

    try testing.expect(!valid(&padded));
}

test Datetime {
    const Launch = document_module.DocumentType(.{
        .line_count_max = null,
        .node_count_max = 8,
        .text_bytes_max = 64,
    });

    const launch = try testing.allocator.create(Launch);
    defer testing.allocator.destroy(launch);

    try launch.parse("at = 1979-05-27 07:32Z\n", .{ .version = .v1_1 });

    const at = launch.find("at") orelse return error.AtMissing;

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.print("{f}", .{at.datetime});

    try testing.expectEqual(Datetime.Kind.datetime_offset, at.datetime.kind);
    try testing.expect(!at.datetime.spelling.second_present);
    try testing.expectEqualStrings("1979-05-27T07:32Z", writer.buffered());
}
