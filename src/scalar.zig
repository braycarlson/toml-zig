const std = @import("std");

const document_module = @import("document.zig");

const assert = std.debug.assert;

const Position = document_module.Position;

const lane_count: u32 = 32;
pub const source_bytes_max: u32 = 1 << 31;

comptime {
    assert(std.math.isPowerOfTwo(lane_count));
    assert(source_bytes_max < std.math.maxInt(u32));
}

pub const Number = union(enum) {
    float: f64,
    integer: i64,
};

pub const StringError = error{
    CharacterInvalid,
    EscapeInvalid,
    NewlineInvalid,
    StringInvalid,
    StringUnterminated,
};

pub const StringScan = struct {
    content_end: u32,
    content_start: u32,
    extended: ?u32,
    processed: bool,
};

pub const Stops = struct {
    closing: u8,
    escape: u8,
};

const Chunk = @Vector(lane_count, u8);
const Lanes = @Vector(lane_count, u1);
const Mask = @Int(.unsigned, lane_count);

const Quote = enum(u8) {
    apostrophe = '\'',
    quotation = '"',
};

const lanes_case: Chunk = @splat(0x20);
const lanes_dash: Chunk = @splat('-');
const lanes_delete: Chunk = @splat(0x7f);
const lanes_digit_count: Chunk = @splat(10);
const lanes_digit_zero: Chunk = @splat('0');
const lanes_letter_a: Chunk = @splat('a');
const lanes_letter_count: Chunk = @splat(26);
const lanes_space: Chunk = @splat(' ');
const lanes_underscore: Chunk = @splat('_');
pub const stops_basic: Stops = .{ .closing = '"', .escape = '\\' };
pub const stops_comment: Stops = .{ .closing = '\n', .escape = '\n' };
pub const stops_literal: Stops = .{ .closing = '\'', .escape = '\'' };

pub fn basic_scan(source: []const u8, index: *u32, scan: *StringScan) align(64) StringError!void {
    assert(index.* < source.len);
    assert(source[index.*] == '"');

    index.* += 1;

    scan.* = .{
        .content_end = index.*,
        .content_start = index.*,
        .extended = null,
        .processed = false,
    };

    const budget = source.len - index.* + 1;

    for (0..budget) |_| {
        index.* = stop_skip(source, index.*, stops_basic);

        if (index.* == source.len) return error.StringUnterminated;

        switch (source[index.*]) {
            '"' => {
                scan.content_end = index.*;
                index.* += 1;

                return;
            },
            '\\' => {
                try escape_skip(source, index, scan);

                scan.processed = true;
            },
            '\n', '\r' => return error.StringUnterminated,
            else => try character_skip(source, index),
        }
    }

    unreachable;
}

pub inline fn stop_skip(source: []const u8, start: u32, comptime stops: Stops) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);
    assert(stops.closing < 0x80);
    assert(stops.escape < 0x80);

    const closing: Chunk = @splat(stops.closing);
    const escape: Chunk = @splat(stops.escape);
    var index = start;

    for (0..@divFloor(source.len - start, lane_count)) |_| {
        const bytes: Chunk = source[index..][0..lane_count].*;
        const control: Lanes = @intFromBool(bytes < lanes_space);
        const delete: Lanes = @intFromBool(bytes == lanes_delete);
        const closed: Lanes = @intFromBool(bytes == closing);
        const escaped: Lanes = @intFromBool(bytes == escape);
        const mask: Mask = @bitCast(control | delete | closed | escaped);

        if (mask != 0) {
            index += @ctz(mask);

            break;
        }

        index += lane_count;
    }

    assert(index >= start);
    assert(index <= source.len);

    return index;
}

pub inline fn bare_skip(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    var index = start;

    for (0..@divFloor(source.len - start, lane_count)) |_| {
        const bytes: Chunk = source[index..][0..lane_count].*;
        const folded = (bytes | lanes_case) -% lanes_letter_a;
        const letter: Lanes = @intFromBool(folded < lanes_letter_count);
        const digit: Lanes = @intFromBool(bytes -% lanes_digit_zero < lanes_digit_count);
        const underscore: Lanes = @intFromBool(bytes == lanes_underscore);
        const dash: Lanes = @intFromBool(bytes == lanes_dash);
        const mask: Mask = @bitCast(~(letter | digit | underscore | dash));

        if (mask != 0) {
            index += @ctz(mask);

            break;
        }

        index += lane_count;
    }

    assert(index >= start);
    assert(index <= source.len);

    return index;
}

pub fn literal_scan(source: []const u8, index: *u32, scan: *StringScan) StringError!void {
    assert(index.* < source.len);
    assert(source[index.*] == '\'');

    index.* += 1;

    scan.* = .{
        .content_end = index.*,
        .content_start = index.*,
        .extended = null,
        .processed = false,
    };

    const budget = source.len - index.* + 1;

    for (0..budget) |_| {
        index.* = stop_skip(source, index.*, stops_literal);

        if (index.* == source.len) return error.StringUnterminated;

        switch (source[index.*]) {
            '\'' => {
                scan.content_end = index.*;
                index.* += 1;

                return;
            },
            '\n', '\r' => return error.StringUnterminated,
            else => try character_skip(source, index),
        }
    }

    unreachable;
}

pub fn basic_multiline_scan(source: []const u8, index: *u32, scan: *StringScan) StringError!void {
    assert(std.mem.startsWith(u8, source[index.*..], "\"\"\""));
    assert(source.len <= source_bytes_max);

    index.* += 3;

    newline_trim(source, index);

    scan.* = .{
        .content_end = index.*,
        .content_start = index.*,
        .extended = null,
        .processed = false,
    };

    const budget = source.len - index.* + 1;

    for (0..budget) |_| {
        index.* = stop_skip(source, index.*, stops_basic);

        if (index.* == source.len) return error.StringUnterminated;

        switch (source[index.*]) {
            '"' => if (try quotes_close(source, index, .quotation, scan)) return,
            '\\' => {
                try backslash_skip(source, index, scan);

                scan.processed = true;
            },
            '\r' => {
                try crlf_skip(source, index);

                scan.processed = true;
            },
            '\n' => index.* += 1,
            else => try character_skip(source, index),
        }
    }

    unreachable;
}

pub fn literal_multiline_scan(source: []const u8, index: *u32, scan: *StringScan) StringError!void {
    assert(std.mem.startsWith(u8, source[index.*..], "'''"));
    assert(source.len <= source_bytes_max);

    index.* += 3;

    newline_trim(source, index);

    scan.* = .{
        .content_end = index.*,
        .content_start = index.*,
        .extended = null,
        .processed = false,
    };

    const budget = source.len - index.* + 1;

    for (0..budget) |_| {
        index.* = stop_skip(source, index.*, stops_literal);

        if (index.* == source.len) return error.StringUnterminated;

        switch (source[index.*]) {
            '\'' => if (try quotes_close(source, index, .apostrophe, scan)) return,
            '\r' => {
                try crlf_skip(source, index);

                scan.processed = true;
            },
            '\n' => index.* += 1,
            else => try character_skip(source, index),
        }
    }

    unreachable;
}

fn newline_trim(source: []const u8, index: *u32) void {
    assert(index.* <= source.len);
    assert(source.len <= source_bytes_max);

    const rest = source[index.*..];

    if (std.mem.startsWith(u8, rest, "\n")) {
        index.* += 1;
    } else if (std.mem.startsWith(u8, rest, "\r\n")) {
        index.* += 2;
    } else {}
}

fn quotes_close(source: []const u8, index: *u32, quote: Quote, scan: *StringScan) StringError!bool {
    assert(index.* < source.len);
    assert(source[index.*] == @backingInt(quote));

    const start = index.*;
    const run = run_length(source, start, @backingInt(quote));

    if (run < 3) {
        index.* = start + run;

        return false;
    }

    if (run > 5) return error.StringInvalid;

    scan.content_end = start + run - 3;
    index.* = start + run;

    assert(scan.content_end >= scan.content_start);

    return true;
}

fn run_length(source: []const u8, start: u32, byte: u8) u32 {
    assert(start < source.len);
    assert(source[start] == byte);

    var length: u32 = 0;

    for (source[start..]) |each| {
        if (each != byte) break;

        length += 1;
    }

    assert(length > 0);

    return length;
}

fn backslash_skip(source: []const u8, index: *u32, scan: *StringScan) StringError!void {
    assert(index.* < source.len);
    assert(source[index.*] == '\\');

    const after = whitespace_end(source, index.* + 1);

    if (after < source.len) {
        switch (source[after]) {
            '\n', '\r' => {
                index.* = after;

                return;
            },
            else => {},
        }
    }

    try escape_skip(source, index, scan);
}

pub fn whitespace_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    var index = start;

    for (source[start..]) |byte| {
        switch (byte) {
            ' ', '\t' => index += 1,
            else => break,
        }
    }

    assert(index <= source.len);

    return index;
}

fn crlf_skip(source: []const u8, index: *u32) StringError!void {
    assert(index.* < source.len);
    assert(source[index.*] == '\r');

    if (index.* + 1 == source.len) return error.NewlineInvalid;
    if (source[index.* + 1] != '\n') return error.NewlineInvalid;

    index.* += 2;
}

fn character_skip(source: []const u8, index: *u32) StringError!void {
    assert(index.* < source.len);
    assert(source.len <= source_bytes_max);

    switch (source[index.*]) {
        0x00...0x08, 0x0a...0x1f, 0x7f => return error.CharacterInvalid,
        else => index.* += 1,
    }
}

fn escape_skip(source: []const u8, index: *u32, scan: *StringScan) StringError!void {
    assert(index.* < source.len);
    assert(source[index.*] == '\\');

    const start = index.*;
    if (start + 1 == source.len) return error.EscapeInvalid;

    const escape = source[start + 1];

    const length: u32 = switch (escape) {
        'b', 't', 'n', 'f', 'r', '"', '\\' => 2,
        'e' => extended: {
            escape_extended_note(scan, start);

            break :extended 2;
        },
        'u' => 6,
        'U' => 10,
        'x' => extended: {
            escape_extended_note(scan, start);

            break :extended 4;
        },
        else => return error.EscapeInvalid,
    };

    if (length > 2) {
        if (length > source.len - start) return error.EscapeInvalid;

        _ = try codepoint_of(source[start + 2 .. start + length]);
    }

    index.* = start + length;
}

fn escape_extended_note(scan: *StringScan, start: u32) void {
    assert(start >= scan.content_start);
    assert(scan.content_end == scan.content_start);

    if (scan.extended == null) scan.extended = start;
}

fn codepoint_of(digits: []const u8) StringError!u21 {
    assert(digits.len == 2 or digits.len == 4 or digits.len == 8);
    assert(source_bytes_max > digits.len);

    var value: u32 = 0;

    for (digits) |digit| {
        const nibble = std.fmt.charToDigit(digit, 16) catch return error.EscapeInvalid;

        value = value * 16 + nibble;
    }

    if (value > 0x10ffff) return error.EscapeInvalid;

    switch (value) {
        0xd800...0xdfff => return error.EscapeInvalid,
        else => {},
    }

    const result: u21 = @intCast(value);

    assert(result <= 0x10ffff);

    return result;
}

pub fn basic_decode(content: []const u8, target: []u8) []u8 {
    assert(target.len >= content.len);
    assert(content.len <= source_bytes_max);

    var cursor: Cursor = .{ .source = 0, .target = 0 };

    for (0..content.len) |_| {
        if (cursor.source == content.len) break;

        if (content[cursor.source] == '\\') {
            escape_decode(content, &cursor, target);
        } else {
            target[cursor.target] = content[cursor.source];
            cursor.source += 1;
            cursor.target += 1;
        }
    }

    assert(cursor.source == content.len);

    return target[0..cursor.target];
}

pub fn basic_multiline_decode(content: []const u8, target: []u8) []u8 {
    assert(target.len >= content.len);
    assert(content.len <= source_bytes_max);

    var cursor: Cursor = .{ .source = 0, .target = 0 };

    for (0..content.len) |_| {
        if (cursor.source == content.len) break;

        switch (content[cursor.source]) {
            '\\' => {
                const after = whitespace_end(content, cursor.source + 1);

                if (newline_at(content, after)) {
                    cursor.source = trim_end(content, after);
                } else {
                    escape_decode(content, &cursor, target);
                }
            },
            '\r' => newline_decode(&cursor, target),
            else => byte_copy(content, &cursor, target),
        }
    }

    assert(cursor.source == content.len);

    return target[0..cursor.target];
}

pub fn literal_multiline_decode(content: []const u8, target: []u8) []u8 {
    assert(target.len >= content.len);
    assert(content.len <= source_bytes_max);

    var cursor: Cursor = .{ .source = 0, .target = 0 };

    for (0..content.len) |_| {
        if (cursor.source == content.len) break;

        switch (content[cursor.source]) {
            '\r' => newline_decode(&cursor, target),
            else => byte_copy(content, &cursor, target),
        }
    }

    assert(cursor.source == content.len);

    return target[0..cursor.target];
}

const Cursor = struct {
    source: u32,
    target: u32,
};

fn newline_at(content: []const u8, index: u32) bool {
    assert(index <= content.len);
    assert(content.len <= source_bytes_max);

    const result = switch (byte_at(content, index)) {
        '\n', '\r' => true,
        else => false,
    };

    if (result) assert(index < content.len);

    return result;
}

fn byte_at(text: []const u8, index: u32) u8 {
    assert(index <= text.len);
    assert(text.len <= source_bytes_max);

    if (index == text.len) return 0;
    return text[index];
}

fn sign_length(text: []const u8, index: u32) u32 {
    assert(index <= text.len);
    assert(text.len <= source_bytes_max);

    const result: u32 = switch (byte_at(text, index)) {
        '+', '-' => 1,
        else => 0,
    };

    assert(result <= 1);

    return result;
}

fn trim_end(content: []const u8, start: u32) u32 {
    assert(start <= content.len);
    assert(content.len <= source_bytes_max);

    var index = start;

    for (content[start..]) |byte| {
        switch (byte) {
            ' ', '\t', '\n', '\r' => index += 1,
            else => break,
        }
    }

    assert(index <= content.len);

    return index;
}

fn newline_decode(cursor: *Cursor, target: []u8) void {
    assert(cursor.target < target.len);
    assert(cursor.target <= cursor.source);

    target[cursor.target] = '\n';
    cursor.source += 2;
    cursor.target += 1;
}

fn byte_copy(content: []const u8, cursor: *Cursor, target: []u8) void {
    assert(cursor.source < content.len);
    assert(cursor.target <= cursor.source);

    target[cursor.target] = content[cursor.source];
    cursor.source += 1;
    cursor.target += 1;
}

fn escape_decode(content: []const u8, cursor: *Cursor, target: []u8) void {
    assert(cursor.source + 1 < content.len);
    assert(content[cursor.source] == '\\');
    assert(cursor.target < target.len);

    const simple: u8 = switch (content[cursor.source + 1]) {
        'b' => 0x08,
        'e' => 0x1b,
        't' => '\t',
        'n' => '\n',
        'f' => 0x0c,
        'r' => '\r',
        '"' => '"',
        '\\' => '\\',
        else => 0,
    };

    if (simple != 0) {
        target[cursor.target] = simple;
        cursor.source += 2;
        cursor.target += 1;

        return;
    }

    const length: u32 = switch (content[cursor.source + 1]) {
        'u' => 6,
        'U' => 10,
        'x' => 4,
        else => unreachable,
    };

    const digits = content[cursor.source + 2 .. cursor.source + length];
    const value = hex_value(digits);

    cursor.target += utf8_write(value, target[cursor.target..]);
    cursor.source += length;
}

fn hex_value(digits: []const u8) u21 {
    assert(digits.len == 2 or digits.len == 4 or digits.len == 8);
    assert(source_bytes_max > digits.len);

    var value: u32 = 0;

    for (digits) |digit| {
        const nibble: u32 = switch (digit) {
            '0'...'9' => digit - '0',
            'a'...'f' => digit - 'a' + 10,
            'A'...'F' => digit - 'A' + 10,
            else => unreachable,
        };

        value = value * 16 + nibble;
    }

    assert(value <= 0x10ffff);

    return @intCast(value);
}

fn utf8_write(codepoint: u21, target: []u8) u32 {
    assert(codepoint <= 0x10ffff);
    assert(target.len >= utf8_length_of(codepoint));

    const length = utf8_length_of(codepoint);

    switch (length) {
        1 => target[0] = @intCast(codepoint),
        2 => {
            target[0] = @intCast(0xc0 | (codepoint >> 6));
            target[1] = @intCast(0x80 | (codepoint & 0x3f));
        },
        3 => {
            target[0] = @intCast(0xe0 | (codepoint >> 12));
            target[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
            target[2] = @intCast(0x80 | (codepoint & 0x3f));
        },
        4 => {
            target[0] = @intCast(0xf0 | (codepoint >> 18));
            target[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
            target[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
            target[3] = @intCast(0x80 | (codepoint & 0x3f));
        },
        else => unreachable,
    }

    return length;
}

fn utf8_length_of(codepoint: u21) u32 {
    assert(codepoint <= 0x10ffff);
    assert(source_bytes_max > 4);

    if (codepoint < 0x80) return 1;
    if (codepoint < 0x800) return 2;
    if (codepoint < 0x10000) return 3;
    return 4;
}

pub inline fn token_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    var index = start;

    for (source[start..]) |byte| {
        switch (byte) {
            '0'...'9', 'a'...'z', 'A'...'Z', '_', '+', '-', '.', ':' => index += 1,
            else => break,
        }
    }

    assert(index >= start);

    return index;
}

pub inline fn value_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    var result = token_end(source, start);

    if (result - start == 10) {
        if (date_shaped(source[start..result])) {
            if (time_follows(source, result)) result = token_end(source, result + 1);
        }
    }

    assert(result >= start);

    return result;
}

pub fn value_skip(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source.len <= source_bytes_max);

    switch (source[start]) {
        '"', '\'' => return string_end_of(source, start) orelse unreachable,
        '[', '{' => return container_end_of(source, start),
        else => return value_end(source, start),
    }
}

fn container_end_of(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '[' or source[start] == '{');

    var depth: u32 = 0;
    var index = start;

    for (0..source.len - start) |_| {
        switch (source[index]) {
            '[', '{' => {
                depth += 1;
                index += 1;

                assert(depth <= document_module.depth_max);
            },
            ']', '}' => {
                depth -= 1;
                index += 1;

                if (depth == 0) return index;
            },
            '"', '\'' => index = string_end_of(source, index) orelse unreachable,
            '#' => {
                const newline = std.mem.findScalarPos(u8, source, index, '\n') orelse source.len;

                index = @intCast(newline);
            },
            else => index += 1,
        }

        assert(index <= source.len);
    }

    unreachable;
}

pub fn datetime_shaped(token: []const u8) bool {
    assert(token.len <= source_bytes_max);
    assert(source_bytes_max > 5);

    if (date_shaped(token)) return true;
    return time_shaped(token);
}

pub fn date_shaped(token: []const u8) bool {
    assert(token.len <= source_bytes_max);
    assert(source_bytes_max > 5);

    if (token.len < 5) return false;
    if (token[4] != '-') return false;

    for (token[0..4]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }

    return true;
}

pub fn time_shaped(token: []const u8) bool {
    assert(token.len <= source_bytes_max);
    assert(source_bytes_max > 3);

    if (token.len < 3) return false;
    if (token[2] != ':') return false;
    if (!std.ascii.isDigit(token[0])) return false;
    return std.ascii.isDigit(token[1]);
}

pub inline fn time_follows(source: []const u8, index: u32) bool {
    assert(index <= source.len);
    assert(source.len <= source_bytes_max);

    if (source.len - index < 4) return false;
    if (source[index] != ' ') return false;
    return time_shaped(source[index + 1 .. index + 4]);
}

pub fn number_parse(text: []const u8) error{NumberInvalid}!Number {
    assert(text.len > 0);
    assert(text.len <= source_bytes_max);

    if (special_of(text)) |value| return .{ .float = value };

    const radix = radix_of(text);

    if (radix > 0) {
        const value = try radix_parse(text[2..], radix);
        return .{ .integer = value };
    }

    const float = try decimal_validate(text);

    if (float) {
        const value = std.fmt.parseFloat(f64, text) catch return error.NumberInvalid;
        return .{ .float = value };
    }

    const value = try decimal_integer(text);
    return .{ .integer = value };
}

fn special_of(text: []const u8) ?f64 {
    assert(text.len > 0);
    assert(text.len <= source_bytes_max);

    const body = text[sign_length(text, 0)..];
    const infinite = std.mem.eql(u8, body, "inf");

    if (!infinite) {
        if (!std.mem.eql(u8, body, "nan")) return null;
    }

    const magnitude = if (infinite) std.math.inf(f64) else std.math.nan(f64);
    const result = if (text[0] == '-') -magnitude else magnitude;

    assert(!std.math.isFinite(result));

    return result;
}

fn radix_of(text: []const u8) u8 {
    assert(text.len > 0);
    assert(text.len <= source_bytes_max);

    if (text.len < 2) return 0;
    if (text[0] != '0') return 0;

    return switch (text[1]) {
        'b' => 2,
        'o' => 8,
        'x' => 16,
        else => 0,
    };
}

fn radix_parse(digits: []const u8, radix: u8) error{NumberInvalid}!i64 {
    assert(radix == 2 or radix == 8 or radix == 16);
    assert(digits.len <= source_bytes_max);

    var value: u64 = 0;
    var underscore_previous = true;

    for (digits) |byte| {
        if (byte == '_') {
            if (underscore_previous) return error.NumberInvalid;

            underscore_previous = true;

            continue;
        }

        const digit = std.fmt.charToDigit(byte, radix) catch return error.NumberInvalid;
        const shifted = std.math.mul(u64, value, radix) catch return error.NumberInvalid;

        value = std.math.add(u64, shifted, digit) catch return error.NumberInvalid;
        underscore_previous = false;
    }

    if (underscore_previous) return error.NumberInvalid;
    if (value > std.math.maxInt(i64)) return error.NumberInvalid;

    const result: i64 = @intCast(value);

    assert(result >= 0);

    return result;
}

fn decimal_validate(text: []const u8) error{NumberInvalid}!bool {
    assert(text.len > 0);
    assert(text.len <= source_bytes_max);

    var index = sign_length(text, 0);

    switch (byte_at(text, index)) {
        '0' => {
            index += 1;

            switch (byte_at(text, index)) {
                '0'...'9', '_' => return error.NumberInvalid,
                else => {},
            }
        },
        '1'...'9' => index = try digits_skip(text, index),
        else => return error.NumberInvalid,
    }

    var float = false;

    if (byte_at(text, index) == '.') {
        index = try digits_skip(text, index + 1);
        float = true;
    }

    switch (byte_at(text, index)) {
        'e', 'E' => {
            index += 1;
            index += sign_length(text, index);
            index = try digits_skip(text, index);
            float = true;
        },
        else => {},
    }

    if (index != text.len) return error.NumberInvalid;
    return float;
}

fn digits_skip(text: []const u8, start: u32) error{NumberInvalid}!u32 {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    if (start == text.len) return error.NumberInvalid;
    if (!std.ascii.isDigit(text[start])) return error.NumberInvalid;

    var index = start;

    for (text[start..]) |byte| {
        if (std.ascii.isDigit(byte)) {
            index += 1;

            continue;
        }

        if (byte != '_') break;
        if (index + 1 == text.len) return error.NumberInvalid;
        if (!std.ascii.isDigit(text[index + 1])) return error.NumberInvalid;

        index += 1;
    }

    assert(index > start);

    return index;
}

fn decimal_integer(text: []const u8) error{NumberInvalid}!i64 {
    assert(text.len > 0);
    assert(text.len <= source_bytes_max);

    const negative = text[0] == '-';
    const start = sign_length(text, 0);
    var magnitude: u64 = 0;

    for (text[start..]) |byte| {
        if (byte == '_') continue;

        const shifted = std.math.mul(u64, magnitude, 10) catch return error.NumberInvalid;

        magnitude = std.math.add(u64, shifted, byte - '0') catch return error.NumberInvalid;
    }

    const limit: u64 = if (negative) 1 << 63 else std.math.maxInt(i64);
    if (magnitude > limit) return error.NumberInvalid;

    const result: i64 = if (negative) negated_of(magnitude) else @intCast(magnitude);

    assert((result < 0) == (negative and magnitude > 0));

    return result;
}

fn negated_of(magnitude: u64) i64 {
    assert(magnitude <= 1 << 63);
    assert(@as(u64, 1) << 63 == @as(u64, std.math.maxInt(i64)) + 1);

    if (magnitude == 1 << 63) return std.math.minInt(i64);

    const result = -@as(i64, @intCast(magnitude));

    assert(result <= 0);

    return result;
}

pub fn token_end_after(region: []const u8, start: u32) u32 {
    assert(start <= region.len);
    assert(region.len <= source_bytes_max);

    const end: u32 = @intCast(region.len);
    var index = start;
    var result = start;

    for (0..end - start + 1) |_| {
        if (index == end) break;

        switch (region[index]) {
            ' ', '\t', '\r', '\n' => index += 1,
            '#' => index = @intCast(std.mem.findScalarPos(u8, region, index, '\n') orelse end),
            '"', '\'' => {
                index = string_end_of(region, index) orelse return result;
                result = index;
            },
            else => {
                index += 1;
                result = index;
            },
        }
    }

    assert(result <= end);
    assert(result >= start);

    return result;
}

pub fn string_end_of(region: []const u8, start: u32) ?u32 {
    assert(start < region.len);
    assert(region.len <= source_bytes_max);

    const quote = region[start];
    const triple = std.mem.startsWith(u8, region[start..], &[3]u8{ quote, quote, quote });
    var index = start;
    var scan: StringScan = undefined;

    const scanned = switch (quote) {
        '"' => if (triple)
            basic_multiline_scan(region, &index, &scan)
        else
            basic_scan(region, &index, &scan),
        '\'' => if (triple)
            literal_multiline_scan(region, &index, &scan)
        else
            literal_scan(region, &index, &scan),
        else => unreachable,
    };

    scanned catch return null;

    assert(index > start);

    return index;
}

pub fn position_of(source: []const u8, index: u32) Position {
    assert(index <= source.len);
    assert(source.len <= source_bytes_max);

    var result: Position = .{ .column = 1, .line = 1, .offset = index };

    for (source[0..index]) |byte| {
        switch (byte) {
            '\n' => {
                result.line += 1;
                result.column = 1;
            },
            0x80...0xbf => {},
            else => result.column += 1,
        }
    }

    assert(result.line >= 1);

    return result;
}

pub fn utf8_invalid_index(source: []const u8) u32 {
    assert(source.len <= source_bytes_max);
    assert(source_bytes_max < std.math.maxInt(u32));

    var index: u32 = 0;

    for (0..source.len) |_| {
        if (index == source.len) break;

        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch return index;
        if (length > source.len - index) return index;

        _ = std.unicode.utf8Decode(source[index..][0..length]) catch return index;

        index += length;
    }

    assert(index == source.len);

    return index;
}

const testing = std.testing;

const IntegerCase = struct {
    expected: i64,
    text: []const u8,
};

test "the specification's integers decode to the values it states" {
    const cases = [_]IntegerCase{
        .{ .expected = 99, .text = "+99" },
        .{ .expected = 42, .text = "42" },
        .{ .expected = 0, .text = "0" },
        .{ .expected = -17, .text = "-17" },
        .{ .expected = 1000, .text = "1_000" },
        .{ .expected = 5349221, .text = "5_349_221" },
        .{ .expected = 5349221, .text = "53_49_221" },
        .{ .expected = 12345, .text = "1_2_3_4_5" },
        .{ .expected = 3735928559, .text = "0xDEADBEEF" },
        .{ .expected = 3735928559, .text = "0xdeadbeef" },
        .{ .expected = 3735928559, .text = "0xdead_beef" },
        .{ .expected = 342391, .text = "0o01234567" },
        .{ .expected = 493, .text = "0o755" },
        .{ .expected = 214, .text = "0b11010110" },
        .{ .expected = std.math.maxInt(i64), .text = "9223372036854775807" },
        .{ .expected = std.math.minInt(i64), .text = "-9223372036854775808" },
        .{ .expected = std.math.maxInt(i64), .text = "0x7FFFFFFFFFFFFFFF" },
    };

    for (cases) |case| {
        const number = try number_parse(case.text);

        try testing.expectEqual(case.expected, number.integer);
    }
}

test "numbers the specification forbids are refused" {
    const refused = [_][]const u8{
        "01",
        "+01",
        "0_0",
        "1__2",
        "_1",
        "1_",
        "0x_1",
        "0X10",
        "+0x10",
        "0o8",
        "0b2",
        ".7",
        "7.",
        "3.e+20",
        "1e",
        "1e_1",
        "9223372036854775808",
        "-9223372036854775809",
        "0x8000000000000000",
        "Inf",
        "nan_",
        "infinity",
        "1.5.5",
    };

    for (refused) |text| try testing.expectError(error.NumberInvalid, number_parse(text));
}

test "the specification's floats decode to the values it states" {
    const cases = [_]struct { expected: f64, text: []const u8 }{
        .{ .expected = 1.0, .text = "+1.0" },
        .{ .expected = 3.1415, .text = "3.1415" },
        .{ .expected = -0.01, .text = "-0.01" },
        .{ .expected = 5e22, .text = "5e+22" },
        .{ .expected = 1e6, .text = "1e06" },
        .{ .expected = -2e-2, .text = "-2E-2" },
        .{ .expected = 6.626e-34, .text = "6.626e-34" },
        .{ .expected = 224617.445991228, .text = "224_617.445_991_228" },
    };

    for (cases) |case| try testing.expectEqual(case.expected, (try number_parse(case.text)).float);

    try testing.expect(std.math.isPositiveInf((try number_parse("inf")).float));
    try testing.expect(std.math.isPositiveInf((try number_parse("+inf")).float));
    try testing.expect(std.math.isNegativeInf((try number_parse("-inf")).float));
    try testing.expect(std.math.isNan((try number_parse("nan")).float));
    try testing.expect(std.math.isNan((try number_parse("-nan")).float));
    try testing.expect(std.math.signbit((try number_parse("-0.0")).float));
}

const Decoded = struct {
    extended: ?u32,
    text: []const u8,
};

fn scan_decode(text: []const u8, target: []u8) !Decoded {
    assert(text.len > 0);
    assert(target.len >= text.len);

    var index: u32 = 0;
    var scan: StringScan = undefined;

    if (std.mem.startsWith(u8, text, "\"\"\"")) {
        try basic_multiline_scan(text, &index, &scan);

        const content = text[scan.content_start..scan.content_end];
        return .{ .extended = scan.extended, .text = basic_multiline_decode(content, target) };
    }

    if (std.mem.startsWith(u8, text, "'''")) {
        try literal_multiline_scan(text, &index, &scan);

        const content = text[scan.content_start..scan.content_end];
        return .{ .extended = scan.extended, .text = literal_multiline_decode(content, target) };
    }

    if (text[0] == '\'') {
        try literal_scan(text, &index, &scan);

        return .{ .extended = scan.extended, .text = text[scan.content_start..scan.content_end] };
    }

    try basic_scan(text, &index, &scan);

    assert(index == text.len);

    const content = text[scan.content_start..scan.content_end];
    return .{ .extended = scan.extended, .text = basic_decode(content, target) };
}

fn scan_refuse(text: []const u8) !u32 {
    assert(text.len > 0);
    assert(text[0] == '"');

    var index: u32 = 0;
    var scan: StringScan = undefined;

    const refused = if (std.mem.startsWith(u8, text, "\"\"\""))
        basic_multiline_scan(text, &index, &scan)
    else
        basic_scan(text, &index, &scan);

    try testing.expectError(error.EscapeInvalid, refused);

    return index;
}

const StringCase = struct {
    expected: []const u8,
    source: []const u8,
};

test "the specification's strings decode to the text it states" {
    const fox = "The quick brown fox jumps over the lazy dog.";

    const cases = [_]StringCase{
        .{
            .expected = "I'm a string. \"You can quote me\". Name\tJos\u{e9}\nLocation\tSF.",
            .source = "\"I'm a string. \\\"You can quote me\\\". Name\\tJos\\u00E9" ++
                "\\nLocation\\tSF.\"",
        },
        .{
            .expected = fox,
            .source = "\"\"\"\nThe quick brown \\\n\n\n  fox jumps over \\\n" ++
                "    the lazy dog.\"\"\"",
        },
        .{
            .expected = fox,
            .source = "\"\"\"\\\n       The quick brown \\\n       fox jumps over \\\n" ++
                "       the lazy dog.\\\n       \"\"\"",
        },
        .{
            .expected = "Here are three quotation marks: \"\"\".",
            .source = "\"\"\"Here are three quotation marks: \"\"\\\".\"\"\"",
        },
        .{
            .expected = "\"This,\" she said, \"is just a pointless statement.\"",
            .source = "\"\"\"\"This,\" she said, \"is just a pointless statement.\"\"\"\"",
        },
        .{ .expected = "C:\\Users\\nodejs\\templates", .source = "'C:\\Users\\nodejs\\templates'" },
        .{
            .expected = "I [dw]on't need \\d{2} apples",
            .source = "'''I [dw]on't need \\d{2} apples'''",
        },
        .{
            .expected = "'That,' she said, 'is still pointless.'",
            .source = "''''That,' she said, 'is still pointless.''''",
        },
        .{ .expected = "\u{1f600}\u{10ffff}", .source = "\"\\U0001F600\\U0010FFFF\"" },
        .{ .expected = "a\\b\"\x08\x0c\r", .source = "\"a\\\\b\\\"\\b\\f\\r\"" },
    };

    var buffer: [256]u8 = undefined;

    for (cases) |case| {
        const decoded = try scan_decode(case.source, &buffer);

        try testing.expectEqualStrings(case.expected, decoded.text);
        try testing.expectEqual(@as(?u32, null), decoded.extended);
    }
}

test "string escapes and characters the specification forbids are refused" {
    const cases = [_]struct { expected: StringError, source: []const u8 }{
        .{ .expected = error.EscapeInvalid, .source = "\"\\uD800\"" },
        .{ .expected = error.EscapeInvalid, .source = "\"\\U00110000\"" },
        .{ .expected = error.EscapeInvalid, .source = "\"\\u12\"" },
        .{ .expected = error.EscapeInvalid, .source = "\"\\X41\"" },
        .{ .expected = error.EscapeInvalid, .source = "\"\\E\"" },
        .{ .expected = error.CharacterInvalid, .source = "\"a\x01b\"" },
        .{ .expected = error.CharacterInvalid, .source = "'a\x7fb'" },
        .{ .expected = error.StringUnterminated, .source = "\"line\nbreak\"" },
        .{ .expected = error.StringInvalid, .source = "\"\"\"six\"\"\"\"\"\"" },
        .{ .expected = error.NewlineInvalid, .source = "'''bare\rreturn'''" },
    };

    var buffer: [64]u8 = undefined;

    for (cases) |case| {
        const refused = scan_decode(case.source, &buffer);

        try testing.expectError(case.expected, refused);
    }
}

test "the 1.1 escapes decode and the scan notes the first one at its backslash" {
    const cases = [_]StringCase{
        .{ .expected = "a\x1bb", .source = "\"a\\eb\"" },
        .{ .expected = "\u{e9}t", .source = "\"\\xE9t\"" },
        .{ .expected = "\x00\x7f\u{ff}", .source = "\"\\x00\\x7F\\xff\"" },
        .{ .expected = "\t\x1b", .source = "\"\\t\\e\"" },
        .{ .expected = "\x1b\n", .source = "\"\"\"\n\\e\n\"\"\"" },
        .{ .expected = "ok \u{e9}", .source = "\"\"\"ok \\xe9\"\"\"" },
    };

    const firsts = [_]u32{ 2, 1, 1, 3, 4, 6 };

    var buffer: [64]u8 = undefined;

    for (cases, firsts) |case, first| {
        const decoded = try scan_decode(case.source, &buffer);

        try testing.expectEqualStrings(case.expected, decoded.text);
        try testing.expectEqual(@as(?u32, first), decoded.extended);
        try testing.expectEqual('\\', case.source[first]);
    }

    const malformed = [_][]const u8{ "\"\\x4\"", "\"\\xG1\"", "\"\\x\"", "\"\"\"\\x1\"\"\"" };

    for (malformed) |source| {
        const backslash = std.mem.findScalar(u8, source, '\\').?;
        const refused_at = try scan_refuse(source);

        try testing.expectEqual(backslash, refused_at);
    }
}

const stop_candidates = [_]u8{
    0x00,
    '\t',
    '\n',
    '\r',
    0x1f,
    ' ',
    '"',
    '\'',
    '\\',
    'a',
    0x7f,
    0x80,
    0xff,
};

const stop_fillers = "ab #~\x80\xc3\xff";

fn stop_table_of(stops: Stops) [256]bool {
    assert(stops.closing < 0x80);
    assert(stops.escape < 0x80);

    var table: [256]bool = @splat(false);

    for (0..' ') |byte| {
        table[byte] = true;
    }

    table[0x7f] = true;
    table[stops.closing] = true;
    table[stops.escape] = true;

    assert(table[0x7f]);
    assert(!table['a']);

    return table;
}

fn stop_reference(source: []const u8, start: u32, table: *const [256]bool) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    const whole: u32 = @intCast(@divFloor(source.len - start, lane_count) * lane_count);
    var result = start + whole;

    for (source[start..][0..whole], start..) |byte, position| {
        if (table[byte]) {
            result = @intCast(position);

            break;
        }
    }

    assert(result >= start);
    assert(result <= source.len);

    return result;
}

fn stop_skip_check(comptime stops: Stops, buffer: []const u8, position: u32) !void {
    assert(position < buffer.len);
    assert(buffer.len <= 128);
    assert(stops.closing < 0x80);

    const table = stop_table_of(stops);

    for ([_]u32{ 0, 1, 31, 32, 33 }) |start| {
        for ([_]usize{ position, position + 1, 63, 64, 65, buffer.len }) |length| {
            if (start > length) continue;
            if (length > buffer.len) continue;

            const source = buffer[0..length];
            const expected = stop_reference(source, start, &table);

            try testing.expectEqual(expected, stop_skip(source, start, stops));
        }
    }
}

test "a stop skip finds the first stop byte of a whole chunk and leaves a partial chunk" {
    var buffer: [80]u8 = undefined;

    inline for (.{ stops_basic, stops_comment, stops_literal }) |stops| {
        for (stop_candidates) |candidate| {
            for (0..buffer.len) |position| {
                for (&buffer, 0..) |*byte, index| {
                    byte.* = stop_fillers[@mod(index, stop_fillers.len)];
                }

                buffer[position] = candidate;

                try stop_skip_check(stops, &buffer, @intCast(position));
            }
        }
    }
}

const StringOffset = struct {
    length: u32,
    position: u32,
};

fn long_string_refuse(source: []u8, offset: StringOffset) !void {
    assert(offset.position < offset.length);
    assert(offset.length + 2 <= source.len);

    const length = offset.length;
    const position = offset.position;

    for ([_]u8{ '"', '\'' }) |quote| {
        source[0] = quote;

        @memset(source[1..][0..length], 'a');
        source[1 + length] = quote;
        source[1 + position] = 0x01;
        @memset(source[length + 2 ..], 'x');

        for ([_]usize{ length + 2, source.len }) |end| {
            var index: u32 = 0;
            var scan: StringScan = undefined;
            const text = source[0..end];

            const refused = switch (quote) {
                '"' => basic_scan(text, &index, &scan),
                else => literal_scan(text, &index, &scan),
            };

            try testing.expectError(error.CharacterInvalid, refused);
            try testing.expectEqual(1 + position, index);
        }
    }
}

fn long_string_escape(source: []u8, offset: StringOffset) !void {
    assert(offset.position + 2 <= offset.length);
    assert(offset.length + 2 <= source.len);

    const length = offset.length;
    const position = offset.position;

    source[0] = '"';

    @memset(source[1..][0..length], 'a');
    source[1 + length] = '"';
    source[1 + position] = '\\';
    source[2 + position] = 't';

    var expected: [96]u8 = undefined;

    @memset(expected[0 .. length - 1], 'a');
    expected[position] = '\t';

    var target: [96]u8 = undefined;
    const decoded = try scan_decode(source[0 .. length + 2], &target);

    try testing.expectEqualStrings(expected[0 .. length - 1], decoded.text);
}

const bare_candidates = "-_09azAZ@[`{/:. \x00\x7f\x80\xc1\xe1\xff";
const bare_fillers = "aZ09_-k";

fn bare_skip_check(buffer: []const u8, position: u32, table: *const [256]bool) !void {
    assert(position < buffer.len);
    assert(!table['a']);

    for ([_]u32{ 0, 1, 31, 32, 33 }) |start| {
        for ([_]usize{ position, position + 1, 63, 64, 65, buffer.len }) |length| {
            if (start > length) continue;
            if (length > buffer.len) continue;

            const source = buffer[0..length];
            const expected = stop_reference(source, start, table);

            try testing.expectEqual(expected, bare_skip(source, start));
        }
    }
}

test "a bare key skip finds the first byte outside a bare key in a whole chunk" {
    var table: [256]bool = undefined;

    for (&table, 0..) |*entry, byte| {
        entry.* = !std.ascii.isAlphanumeric(@intCast(byte));
    }

    table['_'] = false;
    table['-'] = false;

    var buffer: [80]u8 = undefined;

    for (bare_candidates) |candidate| {
        for (0..buffer.len) |position| {
            for (&buffer, 0..) |*byte, index| {
                byte.* = bare_fillers[@mod(index, bare_fillers.len)];
            }

            buffer[position] = candidate;

            try bare_skip_check(&buffer, @intCast(position), &table);
        }
    }
}

test "a long string refuses a control byte and decodes an escape at every offset" {
    var source: [128]u8 = undefined;

    for (1..72) |length| {
        for (0..length) |position| {
            const offset: StringOffset = .{
                .length = @intCast(length),
                .position = @intCast(position),
            };

            try long_string_refuse(&source, offset);

            if (position + 2 <= length) {
                try long_string_escape(&source, offset);
            }
        }
    }
}

test "a position counts lines and characters rather than bytes" {
    const source = "a = 1\n\u{e9}\u{e9} = x\n";
    const first: Position = .{ .column = 1, .line = 1, .offset = 0 };
    const second: Position = .{ .column = 1, .line = 2, .offset = 6 };
    const third: Position = .{ .column = 3, .line = 2, .offset = 10 };

    try testing.expectEqual(first, position_of(source, 0));
    try testing.expectEqual(second, position_of(source, 6));
    try testing.expectEqual(third, position_of(source, 10));
    try testing.expectEqual(@as(u32, 2), utf8_invalid_index("ab\xc3"));
    try testing.expectEqual(@as(u32, 1), utf8_invalid_index("a\xed\xa0\x80"));
}

test "a value skip steps over every value kind and stops at the first byte after it" {
    const cases = [_]struct { end: u32, text: []const u8 }{
        .{ .end = 3, .text = "0x1 # c" },
        .{ .end = 10, .text = "1979-05-27, x" },
        .{ .end = 19, .text = "1979-05-27 07:32:00 # c" },
        .{ .end = 5, .text = "\"a\\\"\" b" },
        .{ .end = 9, .text = "'''a'b''' c" },
        .{ .end = 11, .text = "\"\"\"x\n\"\"y\"\"\" z" },
        .{ .end = 13, .text = "[1, \"]\", [2]] x" },
        .{ .end = 23, .text = "[ # ] [\n  1,\n  {a=[]}\n] tail" },
        .{ .end = 20, .text = "{ a.b = '}', c = 1 } x" },
        .{ .end = 5, .text = "false\n" },
    };

    for (cases) |case| {
        try testing.expectEqual(case.end, value_skip(case.text, 0));
    }
}
