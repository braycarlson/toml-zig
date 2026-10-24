const std = @import("std");

const bounded = @import("bounded");
const datetime_module = @import("datetime.zig");
const storage_module = @import("storage.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;

const Prng = std.Random.DefaultPrng;

pub const CoverageReport = struct {
    events_max: u32,
    fuzzer: []const u8,
};

pub const Options = struct {
    events_max: u32,
    seed: u64,
};

pub const Model = struct {
    checks: Checks,
    crlf: bool,
    prng: Prng,
    text: Text,
    version: toml.Version,

    pub fn generate(model: *Model, version: toml.Version) ![]const u8 {
        comptime assert(@sizeOf(@TypeOf(version)) == 1);

        model.text = .empty;
        model.checks = .empty;
        model.crlf = model.prng.random().uintLessThan(u32, 4) == 0;
        model.version = version;

        try model_generate(model);

        assert(model.checks.count <= check_count_max);
        assert(model.text.count() <= text_bytes_max);

        return model.text.slice();
    }

    pub fn verify(model: *const Model, document: *const toml.Document) !void {
        assert(document.node_count > 0);
        assert(model.checks.count <= check_count_max);

        const source = model.text.slice();

        for (model.checks.slice()) |*check| try check_verify(document, check, source);
    }
};

const Path = bounded.BufferType(path_bytes_max);
const Short = bounded.BufferType(short_bytes_max);
pub const Text = bounded.BufferType(text_bytes_max);

const Expected = union(enum) {
    boolean: bool,
    count: u32,
    datetime: toml.Datetime,
    float: f64,
    integer: i64,
    string: Short,
};

const Check = struct {
    element: u32,
    expected: Expected,
    head: Path,
    item: u32,
    offset: u32,
    tail: Path,
};

const Checks = bounded.ArrayType(Check, check_count_max);
const key_names = [_][]const u8{ "k", "kk", "k0", "k00", "k_0" };

comptime {
    assert(key_names.len == key_count_max);
    assert(key_names.len == item_count_max);
}

const byte_order_mark = "\xef\xbb\xbf";
const equals = [_][]const u8{ " = ", "=", "\t=  ", " =", "=\t" };
const gaps = [_][]const u8{ "", " ", "\n", " # gap\n", "\r\n  ", "\n\n  # own line\n  " };
const quotes = "\"'";
const special_names = [_][]const u8{ "", "k.k", "k[0]", "k k" };

const string_alphabet = [_]u21{
    'a',
    'Z',
    ' ',
    '"',
    '\\',
    '\'',
    '\t',
    '\n',
    0x01,
    0x1b,
    0x7f,
    0xe9,
    0x4e2d,
    0x1f600,
};

const Newline = struct {
    codepoint: u21,
    literal: bool,
    multi_line: bool,
    raw: bool,
};

const Section = struct {
    element: u32,
    head: []const u8,
};

const root_section: Section = .{ .element = none, .head = "" };

const Target = struct {
    key: []const u8,
    offset: u32,
    section: *const Section,
};

pub const corpus = [_][]const u8{
    "title = \"TOML Example\"\n[owner]\nname = \"Tom\"\ndob = 1979-05-27T07:32:00-08:00\n" ++
        "[database]\nports = [ 8000, 8001 ]\ntemp = { cpu = 79.5, case = 72.0 }\n",
    "[[fruits]]\nname = \"apple\"\n[fruits.physical]\ncolor = \"red\"\n" ++
        "[[fruits.varieties]]\nname = \"red delicious\"\n[[fruits]]\nname = \"banana\"\n",
    "str = \"\"\"\\\n  The quick \\\n  fox.\\\n  \"\"\"\n" ++
        "lit = '''a''b'''\nu = \"\\u00e9\\U0001F600\"\n",
    "a.b.c = 1\na.b.d = 0x_ff\n[x.y]\nz = [ [1, 2], [\"a\"], { k = 1979-05-27 } ]\n",
    "int = +1_000\nhex = 0xDEAD_beef\noct = 0o755\nbin = 0b1101\n" ++
        "flt = -6.626e-34\ninf = -inf\nnan = nan\ntime = 07:32:00.999999\n" ++
        "local = 1979-05-27 07:32:00\n",
    "kkk = 1\nkk = 2\nk = 3\n'' = 4\n[tt]\nab_c = 5\nab = 6\na = 7\n" ++
        "[t]\nx.yy.z = 8\nx.y = 9\n\"x\".yyy = 10\n",
    "t = { # open\n  a = 1,\n  b.c = \"\\e\\x41\", # note\n}\nshort = 07:32\n" ++
        "at = 1979-05-27 07:32Z\nu = { k = [ 1,\n 2 ], }\n",
    "\"a.b\" = { \"c[0]\" = [7, [8]] }\n'' = [9]\n'k k' = [[1], [2, 3]]\n" ++
        "[[s]]\nx = [{ y = 1 }]\n",
};

const check_count_max: u32 = 1024;
const item_count_max: u32 = 5;
const key_count_max: u32 = 5;
const none = storage_module.none;
const path_bytes_max: u32 = 64;
const repeat_count_max: u32 = 3;
const section_count_max: u32 = 6;
const short_bytes_max: u32 = 64;
const string_codepoint_count_max: u32 = 12;
pub const events_full: u32 = 20_000;
pub const text_bytes_max: u32 = 64 * 1024;

comptime {
    assert(string_codepoint_count_max * 4 <= short_bytes_max);
    assert(section_count_max * repeat_count_max * key_count_max * 4 < check_count_max);
}

pub fn document_audit(document: *const toml.Document, source: []const u8) !void {
    assert(document.node_count > 0);
    assert(source.len <= text_bytes_max);

    try std.testing.expectEqual(source.ptr, document.source.ptr);
    try std.testing.expectEqual(source.len, document.source.len);

    for (0..document.node_count) |position| {
        const index: u32 = @intCast(position);
        const record = &document.nodes[index];
        const node: toml.Node = @fromBackingInt(index);

        if (index > 0) try std.testing.expect(record.parent < index);
        if (record.kind == .string) try slice_check(document, record.payload.string);
        if (record.kind == .datetime) try datetime_check(&record.payload.datetime);

        try slice_check(document, record.key);
        try position_check(document, node, source);

        _ = document.value_of(node);

        switch (record.kind) {
            .array => {
                var items = document.items(node);

                try children_audit(toml.Items, document, node, &items);
            },
            .table => {
                var entries = document.entries(node);

                try children_audit(toml.Entries, document, node, &entries);
            },
            .boolean, .datetime, .float, .integer, .string => {
                try std.testing.expectEqual(@as(u32, 0), record.count);
            },
        }
    }
}

fn children_audit(
    comptime Iterator: type,
    document: *const toml.Document,
    node: toml.Node,
    iterator: *Iterator,
) !void {
    assert(document.node_count > 0);
    assert(@backingInt(node) < document.node_count);

    const kind = document.kind_of(node);
    var count: u32 = 0;

    try std.testing.expectEqual(document.count_of(node), iterator.remaining);

    for (0..document.node_count + 1) |_| {
        const child = iterator.next() orelse break;
        const parent = document.nodes[@backingInt(child)].parent;

        count += 1;

        try std.testing.expectEqual(@backingInt(node), parent);

        if (kind == .table) {
            const key = document.key_of(child);
            const found = document.member(node, key) orelse return error.TestUnexpectedResult;

            try std.testing.expectEqual(child, found);
        }
    }

    try std.testing.expectEqual(document.count_of(node), count);
    try std.testing.expectEqual(@as(u32, 0), iterator.remaining);
}

fn slice_check(document: *const toml.Document, text: []const u8) !void {
    assert(document.source.len <= text_bytes_max);
    assert(text.len <= text_bytes_max);

    const start = @intFromPtr(text.ptr);
    const end = start + text.len;
    const source_start = @intFromPtr(document.source.ptr);
    const text_start = @intFromPtr(document.text.ptr);

    if (text.len == 0) return;

    if (start >= source_start) {
        if (end <= source_start + document.source.len) return;
    }

    if (start >= text_start) {
        if (end <= text_start + document.text_used) return;
    }

    return error.TestUnexpectedResult;
}

fn datetime_check(datetime: *const toml.Datetime) !void {
    assert(datetime_module.valid(datetime));
    assert(text_bytes_max > 64);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try datetime.format(&writer);

    const reparsed = try datetime_module.parse(writer.buffered(), .v1_1);

    try std.testing.expectEqual(datetime.*, reparsed);
}

fn position_check(document: *const toml.Document, node: toml.Node, source: []const u8) !void {
    assert(@backingInt(node) < document.node_count);
    assert(source.len <= text_bytes_max);

    const index = @backingInt(node);
    const record = &document.nodes[index];
    const key_start = @intFromPtr(record.key.ptr);
    const key_end = key_start + record.key.len;
    const source_start = @intFromPtr(source.ptr);
    const source_end = source_start + source.len;
    const inside = key_start >= source_start and key_end <= source_end;
    const found = document.position_of(node);
    if (!inside) return std.testing.expectEqual(@as(?toml.Position, null), found);

    const position = found orelse return error.TestUnexpectedResult;
    const offset = offset_of_position(source, position) orelse return error.TestUnexpectedResult;
    const key_offset: u32 = @intCast(key_start - source_start);

    if (index == 0) return std.testing.expectEqual(@as(u32, 0), offset);

    if (document.nodes[record.parent].kind == .array) {
        return std.testing.expectEqual(key_offset, offset);
    }

    if (offset == key_offset) {
        if (offset == 0) return;

        const before = source[offset - 1];

        try std.testing.expect(std.mem.findScalar(u8, quotes, before) == null);

        return;
    }

    try std.testing.expectEqual(key_offset, offset + 1);
    try std.testing.expect(std.mem.findScalar(u8, quotes, source[offset]) != null);
}

fn offset_of_position(source: []const u8, position: toml.Position) ?u32 {
    assert(source.len <= text_bytes_max);
    assert(position.line >= 1);
    assert(position.column >= 1);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_start: u32 = 0;

    for (1..position.line) |_| {
        const line = lines.next() orelse return null;

        line_start += @intCast(line.len + 1);
    }

    const line = lines.next() orelse return null;
    var view = std.unicode.Utf8View.init(line) catch return null;
    var characters = view.iterator();
    var offset = line_start;

    for (1..position.column) |_| {
        const character = characters.nextCodepointSlice() orelse return null;

        offset += @intCast(character.len);
    }

    return offset;
}

pub fn coverage_report(
    comptime Counter: type,
    coverage: *const std.EnumArray(Counter, u64),
    report: CoverageReport,
) error{CoverageMissing}!void {
    assert(report.events_max > 0);
    assert(report.fuzzer.len > 0);

    var missing: u32 = 0;

    for (std.enums.values(Counter)) |counter| {
        const count = coverage.get(counter);

        std.debug.print("  {t}: {d}\n", .{ counter, count });

        if (count > 0) continue;
        if (report.events_max < events_full) continue;

        std.debug.print("fuzz {s}: {t} was never reached\n", .{ report.fuzzer, counter });

        missing += 1;
    }

    if (missing > 0) return error.CoverageMissing;
}

pub fn text_mutate(prng: *Prng, text: *Text) void {
    assert(text.count() <= text_bytes_max);

    const random = prng.random();
    const alphabet = "[]{}=,.\"'#\\ \t\n\r_-+:0123456789aeinfrtuxzTZ\x00\x7f\xc3\xa9\xff";
    const position = random.uintAtMost(u32, text.count());
    const replacement = alphabet[random.uintLessThan(u32, alphabet.len)];
    const bytes = text.slice_mutable();

    switch (random.uintLessThan(u32, 3)) {
        0 => {
            text.push_byte(replacement) catch return;

            const grown = text.slice_mutable();

            std.mem.copyBackwards(u8, grown[position + 1 ..], grown[position .. grown.len - 1]);
            grown[position] = replacement;
        },
        1 => {
            if (position == bytes.len) return;

            std.mem.copyForwards(u8, bytes[position .. bytes.len - 1], bytes[position + 1 ..]);
            text.truncate(text.count() - 1);
        },
        2 => {
            if (position == bytes.len) return;

            bytes[position] = replacement;
        },
        else => unreachable,
    }
}

fn model_generate(model: *Model) !void {
    assert(model.text.count() == 0);
    assert(model.checks.count == 0);

    const random = model.prng.random();
    const section_count = random.uintAtMost(u32, section_count_max);

    if (random.uintLessThan(u32, 8) == 0) {
        try model.text.push(byte_order_mark ++ "# marked");
        try line_break_write(model);
    }

    const root_key_count = try keys_generate(model, &root_section);
    var tables: [section_count_max]bool = @splat(false);

    for (0..section_count) |position| {
        const index: u32 = @intCast(position);

        tables[index] = random.boolean();

        if (tables[index]) {
            try table_section_generate(model, index);
        } else {
            try array_section_generate(model, index);
        }
    }

    for (0..section_count) |position| {
        const index: u32 = @intCast(position);
        if (!tables[index]) continue;
        if (random.uintLessThan(u32, 3) > 0) continue;

        try late_section_generate(model, index);
    }

    const root: Target = .{ .key = "", .offset = 0, .section = &root_section };

    try check_push(model, &root, .{ .count = root_key_count + section_count });
}

fn table_section_generate(model: *Model, index: u32) !void {
    assert(index < section_count_max);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const nested = random.boolean();
    var head: Path = .empty;

    try head.print("t{d}", .{index});
    try line_break_write(model);

    const parent_offset = model.text.count() + 1;
    const child_offset = parent_offset + head.count() + 1;

    if (nested) try head.print(".s{d}", .{index});

    try model.text.print("[{s}]", .{head.slice()});
    try line_end_write(model);

    const section: Section = .{ .element = none, .head = head.slice() };
    const count = try keys_generate(model, &section);
    const offset = if (nested) child_offset else parent_offset;
    const table: Target = .{ .key = "", .offset = offset, .section = &section };

    try check_push(model, &table, .{ .count = count });

    if (!nested) return;

    var parent: Path = .empty;

    try parent.print("t{d}", .{index});

    const parent_section: Section = .{ .element = none, .head = parent.slice() };

    const parent_table: Target = .{
        .key = "",
        .offset = parent_offset,
        .section = &parent_section,
    };

    try check_push(model, &parent_table, .{ .count = 1 });
}

fn array_section_generate(model: *Model, index: u32) !void {
    assert(index < section_count_max);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const repeat_count = random.intRangeAtMost(u32, 1, repeat_count_max);
    const array_offset = model.text.count() + 3 + @intFromBool(model.crlf);
    var head: Path = .empty;

    try head.print("a{d}", .{index});

    for (0..repeat_count) |position| {
        const element: u32 = @intCast(position);

        try line_break_write(model);

        const element_offset = model.text.count() + 2;

        try model.text.print("[[{s}]]", .{head.slice()});
        try line_end_write(model);

        const section: Section = .{ .element = element, .head = head.slice() };
        const count = try keys_generate(model, &section);
        const table: Target = .{ .key = "", .offset = element_offset, .section = &section };

        try check_push(model, &table, .{ .count = count });
    }

    const array_section: Section = .{ .element = none, .head = head.slice() };
    const array: Target = .{ .key = "", .offset = array_offset, .section = &array_section };

    try check_push(model, &array, .{ .count = repeat_count });
}

fn late_section_generate(model: *Model, index: u32) !void {
    assert(index < section_count_max);
    assert(model.text.count() < text_bytes_max);

    var parent: Path = .empty;
    var head: Path = .empty;

    try parent.print("t{d}", .{index});
    try head.print("t{d}.late", .{index});
    try line_break_write(model);

    const offset = model.text.count() + 1 + parent.count() + 1;

    try model.text.print("[{s}]", .{head.slice()});
    try line_end_write(model);

    const section: Section = .{ .element = none, .head = head.slice() };
    const count = try keys_generate(model, &section);
    const table: Target = .{ .key = "", .offset = offset, .section = &section };

    try check_push(model, &table, .{ .count = count });

    for (model.checks.slice_mutable()) |*check| {
        if (check.item != none) continue;
        if (check.tail.count() > 0) continue;
        if (!std.mem.eql(u8, check.head.slice(), parent.slice())) continue;

        check.expected.count += 1;

        return;
    }

    unreachable;
}

fn line_break_write(model: *Model) !void {
    assert(model.text.count() < text_bytes_max);

    try model.text.push(if (model.crlf) "\r\n" else "\n");
}

fn line_end_write(model: *Model) !void {
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const ends = [_][]const u8{ "", "", " # note", "\t#", "  ## twice # \u{e9}" };

    try model.text.push(ends[random.uintLessThan(u32, ends.len)]);
    try line_break_write(model);

    switch (random.uintLessThan(u32, 8)) {
        0 => try line_break_write(model),
        1 => {
            try model.text.push("  # between");
            try line_break_write(model);
        },
        else => {},
    }
}

fn keys_generate(model: *Model, section: *const Section) !u32 {
    assert(section.head.len <= path_bytes_max);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const key_count = random.uintAtMost(u32, key_count_max);
    var names = key_names;

    random.shuffle([]const u8, &names);

    for (names[0..key_count]) |name| {
        var key: Path = .empty;

        if (random.uintLessThan(u32, 4) == 0) {
            var table: Path = .empty;

            try table.print("d{s}", .{name});
            try key.print("{s}.{s}", .{ table.slice(), name });

            const dotted: Target = .{
                .key = table.slice(),
                .offset = model.text.count(),
                .section = section,
            };

            try key_write(model, table.slice());
            try model.text.push(" . ");
            try check_push(model, &dotted, .{ .count = 1 });
        } else {
            try key.push(name);
        }

        const target: Target = .{
            .key = key.slice(),
            .offset = model.text.count(),
            .section = section,
        };

        try key_write(model, name);
        try model.text.push(equals[random.uintLessThan(u32, equals.len)]);
        try value_generate(model, &target);
        try line_end_write(model);
    }

    if (random.uintLessThan(u32, 4) > 0) return key_count;

    try special_write(model);

    const result = key_count + 1;

    assert(result <= key_count_max + 1);

    return result;
}

fn special_write(model: *Model) !void {
    assert(model.text.count() < text_bytes_max);
    assert(special_names.len > 1);

    const random = model.prng.random();
    const name = special_names[random.uintLessThan(u32, special_names.len)];
    const quote = quotes[random.uintLessThan(u32, quotes.len)];
    const value = random.uintAtMost(u32, 99);

    try model.text.print("{c}{s}{c} = ", .{ quote, name, quote });

    switch (random.uintLessThan(u32, 3)) {
        0 => try model.text.print("{d}", .{value}),
        1 => try model.text.print("[{d}, [{d}]]", .{ value, value }),
        2 => try model.text.print("{{ k = {d} }}", .{value}),
        else => unreachable,
    }

    try line_end_write(model);
}

fn key_write(model: *Model, name: []const u8) !void {
    assert(name.len > 0);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();

    switch (random.uintLessThan(u32, 3)) {
        0 => try model.text.push(name),
        1 => try model.text.print("\"{s}\"", .{name}),
        2 => try model.text.print("'{s}'", .{name}),
        else => unreachable,
    }
}

fn value_generate(model: *Model, target: *const Target) !void {
    assert(target.key.len > 0);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();

    switch (random.uintLessThan(u32, 7)) {
        0 => try check_push(model, target, .{ .integer = try integer_write(model) }),
        1 => try check_push(model, target, .{ .float = try float_write(model) }),
        2 => try check_push(model, target, .{ .string = try string_write(model) }),
        3 => try check_push(model, target, .{ .datetime = try datetime_write(model) }),
        4 => {
            const value = random.boolean();

            try model.text.push(if (value) "true" else "false");
            try check_push(model, target, .{ .boolean = value });
        },
        5 => try array_write(model, target),
        6 => try inline_write(model, target),
        else => unreachable,
    }
}

fn array_write(model: *Model, target: *const Target) !void {
    assert(target.key.len > 0);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const item_count = random.uintAtMost(u32, item_count_max);

    try model.text.push("[");

    for (0..item_count) |position| {
        const item: u32 = @intCast(position);

        try model.text.push(gaps[random.uintLessThan(u32, gaps.len)]);

        const item_offset = model.text.count();
        const expected = try element_write(model);
        var check = try check_build(target, expected);

        check.item = item;
        check.offset = item_offset;

        try model.checks.push_slice(&.{check});

        const comma = if (item + 1 < item_count) true else random.boolean();

        if (comma) try model.text.push(",");
    }

    try model.text.push(gaps[random.uintLessThan(u32, gaps.len)]);
    try model.text.push("]");
    try check_push(model, target, .{ .count = item_count });
}

fn element_write(model: *Model) !Expected {
    assert(model.text.count() < text_bytes_max);
    assert(item_count_max > 1);

    const random = model.prng.random();
    if (random.uintLessThan(u32, 4) > 0) return .{ .integer = try integer_write(model) };

    const count = random.uintAtMost(u32, item_count_max);

    try model.text.push("[");

    for (0..count) |position| {
        if (position > 0) try model.text.push(", ");

        try model.text.print("{d}", .{random.uintAtMost(u32, 99)});
    }

    try model.text.push("]");

    return .{ .count = count };
}

fn inline_write(model: *Model, target: *const Target) !void {
    assert(target.key.len > 0);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const member_count = random.uintAtMost(u32, item_count_max);

    try model.text.push("{");

    var names = key_names;

    random.shuffle([]const u8, &names);

    for (names[0..member_count], 0..) |name, position| {
        var member: Path = .empty;

        try member.print("{s}.{s}", .{ target.key, name });

        if (position > 0) try model.text.push(",");

        try inline_gap_write(model);

        const member_target: Target = .{
            .key = member.slice(),
            .offset = model.text.count(),
            .section = target.section,
        };

        try key_write(model, name);
        try model.text.push(" = ");

        const expected: Expected = if (random.boolean())
            .{ .integer = try integer_write(model) }
        else
            .{ .string = try string_write(model) };

        try check_push(model, &member_target, expected);
    }

    if (member_count > 0) try inline_close_write(model);

    try inline_gap_write(model);
    try model.text.push("}");
    try check_push(model, target, .{ .count = member_count });
}

fn inline_gap_write(model: *Model) !void {
    assert(model.text.count() < text_bytes_max);
    assert(gaps.len > 1);

    const random = model.prng.random();

    if (model.version == .v1_0) return model.text.push(" ");

    try model.text.push(gaps[random.uintLessThan(u32, gaps.len)]);
}

fn inline_close_write(model: *Model) !void {
    assert(model.text.count() < text_bytes_max);
    assert(gaps.len > 1);

    const random = model.prng.random();

    if (model.version == .v1_0) return;
    if (random.boolean()) return;

    try inline_gap_write(model);
    try model.text.push(",");
}

fn integer_write(model: *Model) !i64 {
    assert(model.text.count() < text_bytes_max);
    assert(text_bytes_max > 64);

    const random = model.prng.random();
    const start = model.text.count();
    const magnitude_bits = random.uintAtMost(u6, 63);
    const magnitude = random.uintAtMost(u64, (@as(u64, 1) << magnitude_bits) - 1);

    const value: i64 = switch (random.uintLessThan(u32, 4)) {
        0 => random.int(i64),
        1 => @intCast(magnitude),
        2 => if (random.boolean()) std.math.maxInt(i64) else std.math.minInt(i64),
        3 => -@as(i64, @intCast(magnitude)),
        else => unreachable,
    };

    const radix = if (value >= 0) random.uintLessThan(u32, 6) else 0;

    switch (radix) {
        0, 1, 2 => {
            var digits: Short = .empty;

            try digits.print("{d}", .{value});
            try digits_underscore_write(model, digits.slice());
        },
        3 => try model.text.print("0x{X}", .{value}),
        4 => try model.text.print("0o{o}", .{value}),
        5 => try model.text.print("0b{b}", .{value}),
        else => unreachable,
    }

    const written = model.text.slice()[start..];
    const decoded = std.fmt.parseInt(i64, written, 0) catch return error.TestUnexpectedResult;

    assert(decoded == value);

    return value;
}

fn digits_underscore_write(model: *Model, digits: []const u8) !void {
    assert(digits.len > 0);
    assert(digits.len <= short_bytes_max);

    const random = model.prng.random();
    const start: u32 = if (digits[0] == '-') 1 else 0;

    if (start == 0) {
        if (random.uintLessThan(u32, 4) == 0) try model.text.push("+");
    }

    for (digits, 0..) |byte, position| {
        const interior = position > start and digits[start] != '0';

        if (interior) {
            if (random.uintLessThan(u32, 5) == 0) try model.text.push("_");
        }

        try model.text.push(&.{byte});
    }
}

fn float_decimal_write(model: *Model, value: f64) !void {
    assert(std.math.isFinite(value));
    assert(@abs(value) < 1e6);

    const start = model.text.count();

    try model.text.print("{d}", .{value});

    const digits = model.text.slice()[start..];

    if (std.mem.findAny(u8, digits, ".e") == null) try model.text.push(".0");
}

fn float_exponent_write(model: *Model, value: f64) !void {
    assert(std.math.isFinite(value));
    assert(model.text.count() < text_bytes_max);

    try model.text.print("{e}", .{value});

    if (model.prng.random().boolean()) {
        const digits = model.text.slice_mutable();
        const exponent = std.mem.findScalarLast(u8, digits, 'e') orelse unreachable;

        digits[exponent] = 'E';
    }
}

fn float_write(model: *Model) !f64 {
    assert(model.text.count() < text_bytes_max);
    assert(text_bytes_max > 64);

    const start = model.text.count();
    const random = model.prng.random();

    const value: f64 = switch (random.uintLessThan(u32, 9)) {
        0 => -std.math.inf(f64),
        1 => std.math.inf(f64),
        2, 3, 4 => random.float(f64) * 1000 - 500,
        5, 6 => @bitCast(random.int(u64) & 0x7fef_ffff_ffff_ffff),
        7 => @floatFromInt(random.intRangeAtMost(i32, -100, 100)),
        8 => random.float(f64) * 0.001,
        else => unreachable,
    };

    if (std.math.isInf(value)) {
        try model.text.push(if (value < 0) "-inf" else "+inf");
    } else if (@abs(value) < 1e6) {
        if (random.boolean()) {
            try float_decimal_write(model, value);
        } else {
            try float_exponent_write(model, value);
        }
    } else {
        try float_exponent_write(model, value);
    }

    const written = model.text.slice()[start..];
    const decoded = std.fmt.parseFloat(f64, written) catch return error.TestUnexpectedResult;

    assert(@as(u64, @bitCast(decoded)) == @as(u64, @bitCast(value)));

    return value;
}

fn string_write(model: *Model) !Short {
    assert(model.text.count() < text_bytes_max);
    assert(string_codepoint_count_max > 0);

    const random = model.prng.random();
    const literal = random.boolean();
    const multi_line = random.uintLessThan(u32, 4) == 0;
    const quote: []const u8 = if (literal) "'" else "\"";
    const triple: []const u8 = if (literal) "'''" else "\"\"\"";
    const delimiter = if (multi_line) triple else quote;
    var result: Short = .empty;

    try model.text.push(delimiter);

    const trimmed = multi_line and random.boolean();

    if (trimmed) try line_break_write(model);

    for (0..random.uintAtMost(u32, string_codepoint_count_max)) |_| {
        var codepoint = string_alphabet[random.uintLessThan(u32, string_alphabet.len)];

        const raw = trimmed or result.count() > 0;

        if (literal) codepoint = literal_codepoint(codepoint, multi_line and raw);

        const newline: Newline = .{
            .codepoint = codepoint,
            .literal = literal,
            .multi_line = multi_line,
            .raw = raw,
        };

        if (newline_raw_is(newline)) {
            if (random.boolean()) {
                try result.push("\n");
                try model.text.push("\n");

                continue;
            }
        }

        var encoded: [4]u8 = undefined;

        const length = std.unicode.utf8Encode(codepoint, &encoded) catch {
            return error.TestUnexpectedResult;
        };

        const repeat: u32 = if (codepoint == '"') random.intRangeAtMost(u32, 1, 3) else 1;

        for (0..repeat) |_| {
            try result.push(encoded[0..length]);
            try codepoint_write(model, codepoint, encoded[0..length], literal);
        }
    }

    try model.text.push(delimiter);

    return result;
}

fn newline_raw_is(newline: Newline) bool {
    assert(newline.codepoint > 0);
    assert(newline.codepoint <= 0x10ffff);

    if (!newline.multi_line) return false;
    if (!newline.raw) return false;
    if (newline.literal) return false;
    return newline.codepoint == '\n';
}

fn literal_codepoint(codepoint: u21, newline_allowed: bool) u21 {
    assert(codepoint <= 0x10ffff);
    assert(codepoint != 'q');

    return switch (codepoint) {
        0x00...0x08, 0x0b...0x1f, '\'', 0x7f => 'q',
        '\n' => if (newline_allowed) codepoint else 'q',
        else => codepoint,
    };
}

fn codepoint_write(model: *Model, codepoint: u21, encoded: []const u8, literal: bool) !void {
    assert(codepoint <= 0x10ffff);
    assert(encoded.len > 0);
    assert(encoded.len <= 4);

    if (literal) return model.text.push(encoded);

    if (model.version == .v1_1) {
        if (try escape_extended_write(model, codepoint)) return;
    }

    switch (codepoint) {
        '"' => try model.text.push("\\\""),
        '\\' => try model.text.push("\\\\"),
        '\t' => try model.text.push("\\t"),
        '\n' => try model.text.push("\\n"),
        0x00...0x08, 0x0b...0x1f, 0x7f => try model.text.print("\\u{X:0>4}", .{codepoint}),
        0x1f600 => try model.text.print("\\U{X:0>8}", .{codepoint}),
        else => try model.text.push(encoded),
    }
}

fn escape_extended_write(model: *Model, codepoint: u21) !bool {
    assert(model.version == .v1_1);
    assert(codepoint <= 0x10ffff);

    const random = model.prng.random();

    if (codepoint > 0xff) return false;
    if (random.uintLessThan(u32, 3) == 0) return false;

    if (codepoint == 0x1b) {
        if (random.boolean()) {
            try model.text.push("\\e");

            return true;
        }
    }

    try model.text.print("\\x{X:0>2}", .{codepoint});

    return true;
}

fn datetime_write(model: *Model) !toml.Datetime {
    assert(model.text.count() < text_bytes_max);
    assert(text_bytes_max > 64);

    const random = model.prng.random();
    const kinds = std.enums.values(toml.Datetime.Kind);
    const kind = kinds[random.uintLessThan(u32, kinds.len)];

    var result: toml.Datetime = .{
        .day = 0,
        .hour = 0,
        .kind = kind,
        .minute = 0,
        .month = 0,
        .nanosecond = 0,
        .offset_minutes = 0,
        .second = 0,
        .spelling = .canonical,
        .year = 0,
    };

    if (kind != .time_local) try date_write(model, &result);
    if (kind == .date_local) return result;

    if (kind != .time_local) {
        const separators = "Tt ";

        try model.text.push(&.{separators[random.uintLessThan(u32, separators.len)]});
    }

    try time_write(model, &result);

    if (kind == .datetime_offset) try offset_write(model, &result);

    return result;
}

fn date_write(model: *Model, result: *toml.Datetime) !void {
    assert(result.kind != .time_local);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const year = random.intRangeAtMost(u16, 1, 9999);
    const month = random.intRangeAtMost(u8, 1, 12);
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const lengths = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const day = random.intRangeAtMost(u8, 1, lengths[month - 1]);

    result.year = year;
    result.month = month;
    result.day = day;

    try model.text.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
}

fn time_write(model: *Model, result: *toml.Datetime) !void {
    assert(result.kind != .date_local);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();

    result.hour = random.intRangeAtMost(u8, 0, 23);
    result.minute = random.intRangeAtMost(u8, 0, 59);

    try model.text.print("{d:0>2}:{d:0>2}", .{ result.hour, result.minute });

    if (model.version == .v1_1) {
        if (random.uintLessThan(u32, 3) == 0) {
            result.spelling.second_present = false;

            return;
        }
    }

    result.second = random.intRangeAtMost(u8, 0, 59);

    try model.text.print(":{d:0>2}", .{result.second});

    const digit_count = random.uintAtMost(u32, 9);
    if (digit_count == 0) return;

    var scale: u32 = 1;

    for (0..digit_count) |_| scale *= 10;

    const fraction = random.uintLessThan(u32, scale);

    result.nanosecond = fraction * @divExact(1_000_000_000, scale);
    result.spelling.fraction_present = true;

    try model.text.print(".{d:0>[1]}", .{ fraction, digit_count });
}

fn offset_write(model: *Model, result: *toml.Datetime) !void {
    assert(result.kind == .datetime_offset);
    assert(model.text.count() < text_bytes_max);

    const random = model.prng.random();
    const minutes = random.intRangeAtMost(i16, -(23 * 60 + 59), 23 * 60 + 59);
    const magnitude: u16 = @abs(minutes);

    result.offset_minutes = minutes;

    if (minutes == 0) {
        if (random.boolean()) {
            result.spelling.offset_zulu = true;

            return model.text.push(if (random.boolean()) "Z" else "z");
        }
    }

    try model.text.print("{s}{d:0>2}:{d:0>2}", .{
        if (minutes < 0) "-" else "+",
        @divFloor(magnitude, 60),
        magnitude % 60,
    });
}

fn expected_valid(expected: *const Expected) bool {
    assert(check_count_max > 0);
    assert(short_bytes_max > 0);

    const result = switch (expected.*) {
        .boolean, .integer => true,
        .count => |count| count <= check_count_max,
        .datetime => |*datetime| datetime_module.valid(datetime),
        .float => |float| !std.math.isNan(float),
        .string => |*string| std.unicode.utf8ValidateSlice(string.slice()),
    };

    return result;
}

fn check_build(target: *const Target, expected: Expected) !Check {
    assert(target.section.head.len <= path_bytes_max);
    assert(target.key.len <= path_bytes_max);
    assert(expected_valid(&expected));

    var check: Check = .{
        .element = target.section.element,
        .expected = expected,
        .head = .empty,
        .item = none,
        .offset = target.offset,
        .tail = .empty,
    };

    try check.head.push(target.section.head);
    try check.tail.push(target.key);

    return check;
}

fn check_push(model: *Model, target: *const Target, expected: Expected) !void {
    assert(target.key.len <= path_bytes_max);
    assert(expected_valid(&expected));
    assert(model.checks.count <= check_count_max);

    const check = try check_build(target, expected);

    try model.checks.push_slice(&.{check});
}

fn check_verify(document: *const toml.Document, check: *const Check, source: []const u8) !void {
    assert(document.node_count > 0);
    assert(source.len <= text_bytes_max);

    var node = try path_walk(document, document.root(), check.head.slice());

    if (check.element != none) node = try nth(document, node, check.element);

    node = try path_walk(document, node, check.tail.slice());

    if (check.item != none) node = try nth(document, node, check.item);

    check_compare(document, node, check, source) catch |err| {
        std.debug.print("model check {s}[{d}].{s}[{d}] failed in\n{s}\n", .{
            check.head.slice(),
            check.element,
            check.tail.slice(),
            check.item,
            source,
        });

        return err;
    };
}

fn check_compare(
    document: *const toml.Document,
    node: toml.Node,
    check: *const Check,
    source: []const u8,
) !void {
    assert(@backingInt(node) < document.node_count);
    assert(check.offset <= source.len);

    try expected_compare(document, node, &check.expected);

    const position = document.position_of(node) orelse return error.TestUnexpectedResult;
    const expected = try position_expected(source, check.offset);

    try std.testing.expectEqual(expected, position);
}

fn position_expected(source: []const u8, offset: u32) !toml.Position {
    assert(offset <= source.len);
    assert(source.len <= text_bytes_max);

    const before = source[0..offset];
    const newline = std.mem.findScalarLast(u8, before, '\n');
    const line_start = if (newline) |found| found + 1 else 0;
    const line_count = std.mem.countScalar(u8, before, '\n');
    const characters = try std.unicode.utf8CountCodepoints(before[line_start..]);

    return .{
        .column = @intCast(characters + 1),
        .line = @intCast(line_count + 1),
        .offset = offset,
    };
}

fn path_walk(document: *const toml.Document, start: toml.Node, dotted: []const u8) !toml.Node {
    assert(@backingInt(start) < document.node_count);
    assert(dotted.len <= path_bytes_max);

    if (dotted.len == 0) return start;

    var node = start;
    var segments = std.mem.splitScalar(u8, dotted, '.');

    for (0..path_bytes_max) |_| {
        const segment = segments.next() orelse return node;

        if (document.kind_of(node) != .table) return error.TestUnexpectedResult;

        node = document.member(node, segment) orelse return error.TestUnexpectedResult;
    }

    return error.TestUnexpectedResult;
}

fn nth(document: *const toml.Document, array: toml.Node, index: u32) !toml.Node {
    assert(@backingInt(array) < document.node_count);
    assert(index < check_count_max);

    if (document.kind_of(array) != .array) return error.TestUnexpectedResult;

    var elements = document.items(array);

    for (0..index) |_| _ = elements.next() orelse return error.TestUnexpectedResult;

    return elements.next() orelse error.TestUnexpectedResult;
}

fn expected_compare(
    document: *const toml.Document,
    node: toml.Node,
    expected: *const Expected,
) !void {
    assert(@backingInt(node) < document.node_count);
    assert(expected_valid(expected));

    const testing = std.testing;

    switch (expected.*) {
        .boolean => |value| try testing.expectEqual(value, document.boolean_of(node).?),
        .count => |value| try testing.expectEqual(value, document.count_of(node)),
        .datetime => |value| try testing.expectEqual(value, document.datetime_of(node).?),
        .float => |value| {
            const actual = document.float_of(node).?;

            try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(actual)));
        },
        .integer => |value| try testing.expectEqual(value, document.integer_of(node).?),
        .string => |*value| {
            try testing.expectEqualStrings(value.slice(), document.string_of(node).?);
        },
    }
}

pub const Compare = struct {
    forms: bool,
    seconds: bool,
};

const Pair = struct {
    left: toml.Node,
    right: toml.Node,
};

const pair_count_max: u32 = 1 << 16;
const reached_count_max: u32 = 1 << 16;
pub const Pairs = bounded.ArrayType(Pair, pair_count_max);
const Reached = std.StaticBitSet(reached_count_max);

pub fn invariants_check(document: *const toml.Document) !void {
    assert(document.node_count > 0);
    assert(document.node_count <= reached_count_max);

    var reached: Reached = .empty;
    var reached_count: u32 = 0;
    var parent: u32 = 0;
    var cursor = document.nodes[0].child_first;

    reached.set(0);
    reached_count += 1;

    for (0..2 * document.node_count + 1) |_| {
        if (cursor == none) {
            if (parent == 0) break;

            cursor = document.nodes[parent].sibling_next;
            parent = document.nodes[parent].parent;

            continue;
        }

        try std.testing.expect(!reached.isSet(cursor));
        try std.testing.expectEqual(parent, document.nodes[cursor].parent);
        try std.testing.expect(parent < cursor);

        reached.set(cursor);
        reached_count += 1;

        if (document.nodes[cursor].child_first != none) {
            parent = cursor;
            cursor = document.nodes[cursor].child_first;

            continue;
        }

        cursor = document.nodes[cursor].sibling_next;
    }

    try records_check(document, &reached);
    try indexed_check(document, &reached);
}

fn records_check(document: *const toml.Document, reached: *const Reached) !void {
    assert(document.node_count > 0);
    assert(reached.isSet(0));

    for (0..document.node_count) |position| {
        const index: u32 = @intCast(position);
        const record = &document.nodes[index];

        try std.testing.expectEqual(reached.isSet(index), !record.flags.detached);

        if (record.flags.detached) continue;

        try slice_check(document, record.key);

        switch (record.kind) {
            .array, .table => try children_count_check(document, index),
            .datetime => try std.testing.expect(datetime_module.valid(&record.payload.datetime)),
            .string => try slice_check(document, record.payload.string),
            .boolean, .float, .integer => try std.testing.expectEqual(@as(u32, 0), record.count),
        }

        if (record.kind == .table) try members_unique_check(document, index);
    }
}

fn children_count_check(document: *const toml.Document, index: u32) !void {
    assert(index < document.node_count);
    assert(document.nodes[index].kind == .array or document.nodes[index].kind == .table);

    const record = &document.nodes[index];
    var child = record.child_first;
    var last: u32 = none;
    var count: u32 = 0;

    for (0..document.node_count) |_| {
        if (child == none) break;

        count += 1;
        last = child;
        child = document.nodes[child].sibling_next;
    }

    try std.testing.expectEqual(record.count, count);
    try std.testing.expectEqual(record.child_last, last);
}

fn members_unique_check(document: *const toml.Document, index: u32) !void {
    assert(index < document.node_count);
    assert(document.nodes[index].kind == .table);

    const table: toml.Node = @fromBackingInt(index);
    var entries = document.entries(table);

    for (0..document.count_of(table)) |_| {
        const entry = entries.next() orelse return error.TestUnexpectedResult;
        const found = document.member(table, document.key_of(entry));

        try std.testing.expectEqual(@as(?toml.Node, entry), found);
    }
}

fn indexed_check(document: *const toml.Document, reached: *const Reached) !void {
    assert(document.node_count > 0);
    assert(document.indexed_count <= document.node_count);

    var listed: Reached = .empty;
    var expected: u32 = 0;
    var table = document.indexed_first;

    for (0..document.node_count) |_| {
        if (table == none) break;

        try std.testing.expect(reached.isSet(table));
        try std.testing.expect(document.nodes[table].flags.indexed);
        try std.testing.expect(!listed.isSet(table));

        listed.set(table);
        expected += document.nodes[table].count;
        table = document.nodes[table].indexed_next;
    }

    try std.testing.expectEqual(none, table);
    try std.testing.expectEqual(expected, document.indexed_count);

    for (0..document.node_count) |position| {
        const record = &document.nodes[position];
        if (record.flags.detached) continue;
        if (record.kind != .table) continue;

        try std.testing.expectEqual(record.flags.indexed, listed.isSet(position));
    }
}

pub fn trees_compare(documents: Documents, pairs: *Pairs, compare: Compare) !void {
    comptime assert(@sizeOf(@TypeOf(compare)) <= 16);
    assert(documents.left.node_count > 0);
    assert(documents.right.node_count > 0);

    pairs.* = .empty;

    pairs.push_slot_assume_capacity().* = .{
        .left = documents.left.root(),
        .right = documents.right.root(),
    };

    for (0..pair_count_max) |_| {
        if (pairs.count == 0) return;

        const pair = pairs.get(pairs.count - 1).*;

        pairs.truncate(pairs.count - 1);

        try pair_compare(documents, pair, compare);
        try children_push(documents, pair, pairs);
    }

    return error.TestUnexpectedResult;
}

pub const Documents = struct {
    left: *const toml.Document,
    right: *const toml.Document,
};

fn pair_compare(documents: Documents, pair: Pair, compare: Compare) !void {
    comptime assert(@sizeOf(@TypeOf(compare)) <= 16);
    assert(@backingInt(pair.left) < documents.left.node_count);
    assert(@backingInt(pair.right) < documents.right.node_count);

    const left = &documents.left.nodes[@backingInt(pair.left)];
    const right = &documents.right.nodes[@backingInt(pair.right)];

    try std.testing.expectEqual(left.kind, right.kind);
    try std.testing.expectEqual(left.count, right.count);

    if (compare.forms) {
        try std.testing.expectEqual(left.flags.array_of_tables, right.flags.array_of_tables);
        try std.testing.expectEqual(left.flags.closed, right.flags.closed);
        try std.testing.expectEqual(left.flags.explicit, right.flags.explicit);
        try std.testing.expectEqual(left.section == none, right.section == none);
    }

    switch (left.kind) {
        .array, .table => {},
        .boolean => try std.testing.expectEqual(left.payload.boolean, right.payload.boolean),
        .datetime => {
            var expected = left.payload.datetime;

            if (compare.seconds) expected.spelling.second_present = true;

            try std.testing.expectEqual(expected, right.payload.datetime);
        },
        .float => {
            const left_bits: u64 = @bitCast(left.payload.float);
            const right_bits: u64 = @bitCast(right.payload.float);

            try std.testing.expectEqual(left_bits, right_bits);
        },
        .integer => try std.testing.expectEqual(left.payload.integer, right.payload.integer),
        .string => try std.testing.expectEqualStrings(left.payload.string, right.payload.string),
    }
}

fn children_push(documents: Documents, pair: Pair, pairs: *Pairs) !void {
    assert(@backingInt(pair.left) < documents.left.node_count);
    assert(pairs.count < pair_count_max);

    const left = documents.left;
    const right = documents.right;

    switch (left.kind_of(pair.left)) {
        .array => {
            var left_items = left.items(pair.left);
            var right_items = right.items(pair.right);

            for (0..left.count_of(pair.left)) |_| {
                const left_item = left_items.next() orelse return error.TestUnexpectedResult;
                const right_item = right_items.next() orelse return error.TestUnexpectedResult;
                const slot = try pairs.push_slot();

                slot.* = .{ .left = left_item, .right = right_item };
            }
        },
        .table => {
            var entries = left.entries(pair.left);

            for (0..left.count_of(pair.left)) |_| {
                const entry = entries.next() orelse return error.TestUnexpectedResult;
                const key = left.key_of(entry);

                const found = right.member(pair.right, key) orelse {
                    std.debug.print("compare: the written tree lacks the key {f}\n", .{
                        std.zig.fmtString(key),
                    });

                    return error.TestUnexpectedResult;
                };

                const slot = try pairs.push_slot();

                slot.* = .{ .left = entry, .right = found };
            }
        },
        .boolean, .datetime, .float, .integer, .string => {},
    }
}
