const std = @import("std");

const fuzz_model = @import("fuzz_model.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;

const Datetime = toml.Datetime;
const Prng = std.Random.DefaultPrng;

const Counter = enum {
    choice_count,
    choice_label,
    choice_list,
    choice_pair,
    grid_inline,
    items_empty,
    items_sections,
    maybe_absent,
    maybe_present,
    strict,
};

const Coverage = std.EnumArray(Counter, u64);

const Color = enum {
    blue,
    green,
    red,

    pub const toml = .{ .red = "Red" };
};

const Inner = struct {
    flag: bool = false,
    name: []const u8,
    ratio: ?f64 = null,

    pub const toml = .{ .name = "inner-name" };
};

const Choice = union(enum) {
    count: i64,
    label: []const u8,
    list: []const u16,
    pair: Inner,
};

const Root = struct {
    choice: Choice,
    color: Color,
    count: i32,
    grid: []const []const Inner,
    inner: Inner,
    items: []const Inner,
    matrix: []const []const i64,
    maybe: ?Inner = null,
    maybe_items: ?[]const Inner = null,
    ratio: f32,
    tags: []const []const u8,
    when: Datetime,

    pub const toml = .{ .maybe_items = "maybe-items" };
};

const Pool = struct {
    grid_rows: [row_count_max][]const Inner,
    grid_values: [row_count_max][item_count_max]Inner,
    inners: [item_count_max]Inner,
    list: [item_count_max]u16,
    matrix_rows: [row_count_max][]const i64,
    matrix_values: [row_count_max][item_count_max]i64,
    maybe_items: [item_count_max]Inner,
    strings: [string_count_max][string_bytes_max]u8,
    strings_used: u32,
    tags: [item_count_max][]const u8,
};

const State = struct {
    coverage: Coverage,
    document: toml.Document,
    output: [output_bytes_max]u8,
    pool: Pool,
    prng: Prng,
    region_bytes: [region_bytes_max]u8 align(16),
    storage: Storage,
};

const Storage = toml.StorageType(.{
    .line_count_max = null,
    .node_count_max = 4096,
    .text_bytes_max = 1 << 16,
});

const item_count_max: u32 = 4;
const output_bytes_max: u32 = 1 << 16;
const region_bytes_max: u32 = 1 << 16;
const row_count_max: u32 = 3;
const string_bytes_max: u32 = 16;
const string_count_max: u32 = 64;
const unknown_line = "zz-unknown = 1\n";

comptime {
    assert(string_count_max >= 4 * item_count_max * row_count_max);
    assert(std.enums.values(Counter).len == 10);
    assert(item_count_max <= std.math.maxInt(u8));
}

pub fn main(gpa: std.mem.Allocator, options: fuzz_model.Options) !void {
    assert(options.events_max > 0);
    assert(options.events_max <= fuzz_model.events_full);

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    state.coverage = .initFill(0);
    state.pool.strings_used = 0;
    state.prng = .init(options.seed);

    for (0..options.events_max) |_| try event(state);

    const report: fuzz_model.CoverageReport = .{
        .events_max = options.events_max,
        .fuzzer = "codec",
    };

    try fuzz_model.coverage_report(Counter, &state.coverage, report);
}

fn event(state: *State) !void {
    assert(state.pool.strings_used <= string_count_max);

    const random = state.prng.random();

    const options: toml.Writer.Options = .{
        .layout = if (random.boolean()) .compact else .vertical,
        .strings = std.enums.values(toml.Writer.Strings)[random.uintLessThan(u32, 3)],
        .version = if (random.boolean()) .v1_0 else .v1_1,
    };

    state.pool.strings_used = 0;

    var original: Root = undefined;

    root_fill(state, &original);
    coverage_record(state, &original, options);

    var sink: std.Io.Writer = .fixed(&state.output);
    var writer: toml.Writer = undefined;

    writer.init(&sink, options);

    try toml.encode(Root, &writer, &original);

    writer.finish();

    const written = sink.buffered();

    assert(written.len > 0);

    const storage = state.storage.storage();

    state.document.parse(storage, written, .{ .version = options.version }) catch |err| {
        std.debug.print("codec: the encoded text was refused with {t}\n{s}\n", .{ err, written });

        return err;
    };

    try decoded_compare(state, &original, options, .refused);

    const known_bytes: u32 = @intCast(written.len);

    try sink.writeAll(unknown_line);

    const extended = sink.buffered();

    try state.document.parse(storage, extended, .{ .version = options.version });
    try decoded_compare(state, &original, options, .ignored);
    try unknown_refused_check(state, extended, known_bytes);
}

fn decoded_compare(
    state: *State,
    original: *const Root,
    options: toml.Writer.Options,
    unknown_members: toml.DecodeOptions.UnknownMembers,
) !void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(state.document.node_count > 0);
    assert(original.items.len <= item_count_max);
    assert(@backingInt(unknown_members) < 2);

    var region: toml.Region = .init(&state.region_bytes);
    var decoded: Root = undefined;
    var expected = original.*;

    try toml.decode(Root, &region, &state.document, state.document.root(), &decoded, .{
        .diagnostic = null,
        .unknown_members = unknown_members,
    });

    if (options.version == .v1_0) expected.when.spelling.second_present = true;

    std.testing.expectEqualDeep(expected, decoded) catch |err| {
        std.debug.print("codec: the decoded value differs from the encoded one\n", .{});

        return err;
    };
}

fn unknown_refused_check(state: *State, extended: []const u8, known_bytes: u32) !void {
    assert(known_bytes + unknown_line.len == extended.len);
    assert(state.document.node_count > 0);

    var region: toml.Region = .init(&state.region_bytes);
    var decoded: Root = undefined;
    var diagnostic: toml.Position = undefined;

    const refused = toml.decode(Root, &region, &state.document, state.document.root(), &decoded, .{
        .diagnostic = &diagnostic,
        .unknown_members = .refused,
    });

    const line: u32 = @intCast(std.mem.countScalar(u8, extended[0..known_bytes], '\n') + 1);
    const expected: toml.Position = .{ .column = 1, .line = line, .offset = known_bytes };

    try std.testing.expectError(error.MemberUnknown, refused);
    try std.testing.expectEqual(expected, diagnostic);
    try std.testing.expectEqual(@as(u32, 0), region.used);
}

fn string_pick(state: *State) []const u8 {
    assert(state.pool.strings_used < string_count_max);

    const random = state.prng.random();
    const pieces = [_][]const u8{ "a", "Z", " ", "\"", "'", "\\", "\n", "\t", "\x01", "\u{e9}" };
    const slot = &state.pool.strings[state.pool.strings_used];
    var length: u32 = 0;

    state.pool.strings_used += 1;

    for (0..random.uintAtMost(u32, 6)) |_| {
        const piece = pieces[random.uintLessThan(u32, pieces.len)];
        if (length + piece.len > string_bytes_max) break;

        @memcpy(slot[length..][0..piece.len], piece);
        length += @intCast(piece.len);
    }

    assert(length <= string_bytes_max);
    assert(std.unicode.utf8ValidateSlice(slot[0..length]));

    return slot[0..length];
}

fn inner_fill(state: *State, inner: *Inner) void {
    assert(state.pool.strings_used < string_count_max);

    const random = state.prng.random();

    inner.* = .{
        .flag = random.boolean(),
        .name = string_pick(state),
        .ratio = if (random.boolean()) random.float(f64) * 2000 - 1000 else null,
    };

    assert(inner.name.len <= string_bytes_max);
}

fn root_fill(state: *State, root: *Root) void {
    assert(state.pool.strings_used == 0);

    const random = state.prng.random();
    const pool = &state.pool;

    inner_fill(state, &pool.inners[0]);

    root.* = .{
        .choice = choice_pick(state),
        .color = std.enums.values(Color)[random.uintLessThan(u32, 3)],
        .count = random.int(i32),
        .grid = grid_fill(state),
        .inner = pool.inners[0],
        .items = inners_fill(state, &pool.inners),
        .matrix = matrix_fill(state),
        .maybe = null,
        .maybe_items = null,
        .ratio = @floatCast(random.float(f64) * 100 - 50),
        .tags = tags_fill(state),
        .when = datetime_pick(&state.prng),
    };

    if (random.boolean()) {
        var maybe: Inner = undefined;

        inner_fill(state, &maybe);

        root.maybe = maybe;
    }

    if (random.boolean()) root.maybe_items = inners_fill(state, &pool.maybe_items);

    assert(state.pool.strings_used < string_count_max);
}

fn inners_fill(state: *State, inners: []Inner) []const Inner {
    assert(inners.len == item_count_max);
    assert(state.pool.strings_used < string_count_max);

    const count = state.prng.random().uintAtMost(u32, item_count_max);

    for (inners[0..count]) |*inner| inner_fill(state, inner);

    return inners[0..count];
}

fn grid_fill(state: *State) []const []const Inner {
    assert(state.pool.strings_used < string_count_max);

    const random = state.prng.random();
    const row_count = random.uintAtMost(u32, row_count_max);

    for (0..row_count) |row| {
        state.pool.grid_rows[row] = inners_fill(state, &state.pool.grid_values[row]);
    }

    assert(state.pool.strings_used < string_count_max);

    return state.pool.grid_rows[0..row_count];
}

fn matrix_fill(state: *State) []const []const i64 {
    assert(state.pool.strings_used < string_count_max);

    const random = state.prng.random();
    const row_count = random.uintAtMost(u32, row_count_max);

    for (0..row_count) |row| {
        const values = &state.pool.matrix_values[row];
        const count = random.uintAtMost(u32, item_count_max);

        for (values[0..count]) |*value| value.* = random.int(i64);

        state.pool.matrix_rows[row] = values[0..count];
    }

    return state.pool.matrix_rows[0..row_count];
}

fn tags_fill(state: *State) []const []const u8 {
    assert(state.pool.strings_used < string_count_max);

    const count = state.prng.random().uintAtMost(u32, item_count_max);

    for (state.pool.tags[0..count]) |*tag| tag.* = string_pick(state);

    assert(state.pool.strings_used < string_count_max);

    return state.pool.tags[0..count];
}

fn choice_pick(state: *State) Choice {
    assert(state.pool.strings_used < string_count_max);

    const random = state.prng.random();

    switch (random.uintLessThan(u32, 4)) {
        0 => return .{ .count = random.int(i64) },
        1 => return .{ .label = string_pick(state) },
        2 => {
            const count = random.uintAtMost(u32, item_count_max);

            for (state.pool.list[0..count]) |*value| value.* = random.int(u16);

            return .{ .list = state.pool.list[0..count] };
        },
        else => {
            var pair: Inner = undefined;

            inner_fill(state, &pair);

            return .{ .pair = pair };
        },
    }
}

fn datetime_pick(prng: *Prng) toml.Datetime {
    const random = prng.random();
    const kind = std.enums.values(toml.Datetime.Kind)[random.uintLessThan(u32, 4)];
    const dated = kind != .time_local;
    const timed = kind != .date_local;
    const offset = random.intRangeAtMost(i16, -900, 900);

    var result: toml.Datetime = .{
        .day = if (dated) random.intRangeAtMost(u8, 1, 28) else 0,
        .hour = if (timed) random.intRangeAtMost(u8, 0, 23) else 0,
        .kind = kind,
        .minute = if (timed) random.intRangeAtMost(u8, 0, 59) else 0,
        .month = if (dated) random.intRangeAtMost(u8, 1, 12) else 0,
        .nanosecond = 0,
        .offset_minutes = if (kind == .datetime_offset) offset else 0,
        .second = if (timed) random.intRangeAtMost(u8, 0, 59) else 0,
        .spelling = .canonical,
        .year = if (dated) random.intRangeAtMost(u16, 1, 9999) else 0,
    };

    if (timed) {
        if (random.boolean()) {
            result.second = 0;
            result.spelling.second_present = false;
        }
    }

    if (!dated) assert(result.year == 0);
    if (!timed) assert(result.spelling.second_present);

    return result;
}

fn coverage_record(state: *State, root: *const Root, options: toml.Writer.Options) void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(root.items.len <= item_count_max);

    const choice: Counter = switch (root.choice) {
        .count => .choice_count,
        .label => .choice_label,
        .list => .choice_list,
        .pair => .choice_pair,
    };

    state.coverage.getPtr(choice).* += 1;
    state.coverage.getPtr(if (root.items.len == 0) .items_empty else .items_sections).* += 1;
    state.coverage.getPtr(if (root.maybe == null) .maybe_absent else .maybe_present).* += 1;

    for (root.grid) |row| {
        if (row.len > 0) state.coverage.getPtr(.grid_inline).* += 1;
    }

    if (options.version == .v1_0) state.coverage.getPtr(.strict).* += 1;
}
