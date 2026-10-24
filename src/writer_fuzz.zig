const std = @import("std");

const fuzz_model = @import("fuzz_model.zig");
const storage_module = @import("storage.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;

const Counter = enum {
    array_compact,
    array_empty,
    array_vertical,
    float_fraction,
    float_scientific,
    float_small,
    float_special,
    float_whole,
    header_cached,
    header_table,
    header_table_array,
    inline_compact,
    inline_empty,
    inline_single_line,
    inline_vertical,
    integer_negative,
    key_bare,
    key_dotted,
    key_quoted,
    seconds_added,
    string_basic,
    string_basic_escaped,
    string_basic_multiline,
    string_literal,
    string_literal_multiline,
    string_quote_run,
};

const Coverage = std.EnumArray(Counter, u64);

const Style = enum {
    basic,
    basic_multiline,
    literal,
    literal_multiline,
};

const Storage = toml.StorageType(.{
    .line_count_max = null,
    .node_count_max = 1 << 14,
    .text_bytes_max = output_bytes_max,
});

const State = struct {
    coverage: Coverage,
    document_original: toml.Document,
    document_written: toml.Document,
    model: fuzz_model.Model,
    options: toml.Writer.Options,
    output: [output_bytes_max]u8,
    output_second: [output_bytes_max]u8,
    pairs: fuzz_model.Pairs,
    scratch: [scratch_bytes_max]u8,
    storage_original: Storage,
    storage_written: Storage,
};

const mutation_count_max: u32 = 8;
const output_bytes_max: u32 = 8 * fuzz_model.text_bytes_max;
const scratch_bytes_max: u32 = 8 * fuzz_model.text_bytes_max;
const scratch_prefix = "k = ";

comptime {
    assert(output_bytes_max >= 4 * fuzz_model.text_bytes_max);
    assert(std.enums.values(Counter).len == 26);
    assert(fuzz_model.corpus.len > 0);
}

pub fn main(gpa: std.mem.Allocator, options: fuzz_model.Options) !void {
    assert(options.events_max > 0);
    assert(options.events_max <= fuzz_model.events_full);

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    state.coverage = .initFill(0);
    state.model.prng = .init(options.seed);
    state.model.text = .empty;

    for (0..options.events_max) |_| try event(state);

    const report: fuzz_model.CoverageReport = .{
        .events_max = options.events_max,
        .fuzzer = "writer",
    };

    try fuzz_model.coverage_report(Counter, &state.coverage, report);
}

fn event(state: *State) !void {
    assert(state.model.text.count() <= fuzz_model.text_bytes_max);

    const random = state.model.prng.random();
    const version: toml.Version = if (random.boolean()) .v1_0 else .v1_1;
    const generated = random.boolean();
    const source = if (generated) try state.model.generate(version) else try source_mutate(state);
    const storage = state.storage_original.storage();

    state.document_original.parse(storage, source, .{ .version = version }) catch |err| {
        if (!generated) return;

        std.debug.print("writer: the model source was refused with {t}\n{s}\n", .{ err, source });

        return err;
    };

    assert(state.document_original.node_count > 0);

    state.options = .{
        .layout = if (random.boolean()) .compact else .vertical,
        .strings = std.enums.values(toml.Writer.Strings)[random.uintLessThan(u32, 3)],
        .version = if (random.boolean()) .v1_0 else .v1_1,
    };

    const written = try round_trip_check(state, source);

    try coverage_record(state);

    assert(written.len <= output_bytes_max);
}

fn source_mutate(state: *State) ![]const u8 {
    assert(state.model.text.count() <= fuzz_model.text_bytes_max);

    const random = state.model.prng.random();
    const text = &state.model.text;
    const original = fuzz_model.corpus[random.uintLessThan(u32, fuzz_model.corpus.len)];

    text.* = .empty;

    try text.push(original);

    const mutation_count = random.uintAtMost(u32, mutation_count_max);

    for (0..mutation_count) |_| fuzz_model.text_mutate(&state.model.prng, text);

    return text.slice();
}

fn round_trip_check(state: *State, source: []const u8) ![]const u8 {
    assert(source.len <= fuzz_model.text_bytes_max);
    assert(state.document_original.node_count > 0);

    var sink: std.Io.Writer = .fixed(&state.output);

    try state.document_original.write(&sink, state.options);

    const written = sink.buffered();
    const storage = state.storage_written.storage();
    const version = state.options.version;

    state.document_written.parse(storage, written, .{ .version = version }) catch |err| {
        failure_print(.{ .reason = @errorName(err), .source = source, .written = written });

        return err;
    };

    const documents: fuzz_model.Documents = .{
        .left = &state.document_original,
        .right = &state.document_written,
    };

    const compare: fuzz_model.Compare = .{ .forms = true, .seconds = version == .v1_0 };

    fuzz_model.trees_compare(documents, &state.pairs, compare) catch |err| {
        const reason = "the written tree differs";

        failure_print(.{ .reason = reason, .source = source, .written = written });

        return err;
    };

    var second: std.Io.Writer = .fixed(&state.output_second);

    try state.document_original.write(&second, state.options);
    try std.testing.expectEqualStrings(written, second.buffered());

    return written;
}

const Failure = struct {
    reason: []const u8,
    source: []const u8,
    written: []const u8,
};

fn failure_print(failure: Failure) void {
    assert(failure.reason.len > 0);
    assert(failure.written.len <= output_bytes_max);

    std.debug.print("writer: {s}\n--- source ---\n{s}\n--- written ---\n{s}\n--- end ---\n", .{
        failure.reason,
        failure.source,
        failure.written,
    });
}

fn coverage_record(state: *State) !void {
    assert(state.document_original.node_count > 0);

    const document = &state.document_original;

    for (1..document.node_count) |position| {
        const node: toml.Node = @fromBackingInt(@as(u32, @intCast(position)));

        try node_record(state, node);
    }
}

fn node_record(state: *State, node: toml.Node) !void {
    assert(@backingInt(node) > 0);
    assert(@backingInt(node) < state.document_original.node_count);

    const document = &state.document_original;
    const record = &document.nodes[@backingInt(node)];

    if (document.nodes[record.parent].kind == .table) try key_record(state, document.key_of(node));

    switch (record.kind) {
        .array => array_record(state, node),
        .boolean => {},
        .datetime => {
            const short = !record.payload.datetime.spelling.second_present;

            if (short) {
                if (state.options.version == .v1_0) state.coverage.getPtr(.seconds_added).* += 1;
            }
        },
        .float => try float_record(state, node),
        .integer => {
            if (record.payload.integer < 0) state.coverage.getPtr(.integer_negative).* += 1;
        },
        .string => try string_record(state, record.payload.string),
        .table => table_record(state, node),
    }
}

fn single_line_is(state: *const State, node: toml.Node) bool {
    assert(@backingInt(node) < state.document_original.node_count);

    if (state.options.version == .v1_1) return false;

    const document = &state.document_original;
    var current = document.nodes[@backingInt(node)].parent;

    for (0..document.node_count) |_| {
        if (current == 0) return false;

        if (document.nodes[current].kind == .table) {
            if (document.nodes[current].flags.closed) return true;
        }

        current = document.nodes[current].parent;
    }

    return false;
}

fn array_record(state: *State, node: toml.Node) void {
    assert(state.document_original.kind_of(node) == .array);
    assert(@backingInt(node) > 0);

    const document = &state.document_original;
    const record = &document.nodes[@backingInt(node)];
    const count = record.count;

    if (record.flags.array_of_tables) {
        state.coverage.getPtr(.header_table_array).* += 1;

        if (count >= 2) state.coverage.getPtr(.header_cached).* += 1;

        return;
    }

    const wide = state.options.layout == .vertical and count >= 2;
    const vertical = wide and !single_line_is(state, node);
    const filled: Counter = if (vertical) .array_vertical else .array_compact;
    const counter: Counter = if (count == 0) .array_empty else filled;

    state.coverage.getPtr(counter).* += 1;
}

fn table_record(state: *State, node: toml.Node) void {
    assert(state.document_original.kind_of(node) == .table);
    assert(@backingInt(node) > 0);

    const record = &state.document_original.nodes[@backingInt(node)];

    if (record.flags.explicit) state.coverage.getPtr(.header_table).* += 1;

    if (!record.flags.closed) {
        if (record.section != storage_module.none) state.coverage.getPtr(.key_dotted).* += 1;

        return;
    }

    state.coverage.getPtr(inline_counter_of(state, node)).* += 1;
}

fn inline_counter_of(state: *const State, node: toml.Node) Counter {
    assert(state.document_original.kind_of(node) == .table);
    assert(@backingInt(node) > 0);

    const record = &state.document_original.nodes[@backingInt(node)];
    const wide = state.options.layout == .vertical and record.count >= 2;

    if (record.count == 0) return .inline_empty;
    if (!wide) return .inline_compact;
    if (state.options.version == .v1_0) return .inline_single_line;
    if (single_line_is(state, node)) return .inline_compact;
    return .inline_vertical;
}

fn scratch_writer(state: *State, sink: *std.Io.Writer, writer: *toml.Writer) !void {
    assert(state.document_original.node_count > 0);

    sink.* = .fixed(&state.scratch);

    writer.init(sink, state.options);

    try writer.key(&.{"k"});

    assert(std.mem.eql(u8, sink.buffered(), scratch_prefix));
}

fn key_record(state: *State, key: []const u8) !void {
    assert(key.len <= fuzz_model.text_bytes_max);
    assert(state.document_original.node_count > 0);

    var sink: std.Io.Writer = undefined;
    var writer: toml.Writer = undefined;

    sink = .fixed(&state.scratch);

    writer.init(&sink, state.options);

    try writer.key(&.{key});
    try writer.boolean(true);

    writer.finish();

    assert(std.mem.endsWith(u8, sink.buffered(), " = true\n"));

    const quoted = sink.buffered()[0] == '"';
    const bare_expected = bare_expected_is(key);

    if (quoted == bare_expected) {
        std.debug.print("writer: key {f} quoted={} against the rule\n", .{
            std.zig.fmtString(key),
            quoted,
        });

        return error.TestUnexpectedResult;
    }

    state.coverage.getPtr(if (quoted) .key_quoted else .key_bare).* += 1;
}

fn bare_expected_is(key: []const u8) bool {
    assert(key.len <= fuzz_model.text_bytes_max);

    if (key.len == 0) return false;

    for (key) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }

    return true;
}

fn float_record(state: *State, node: toml.Node) !void {
    assert(state.document_original.kind_of(node) == .float);
    assert(@backingInt(node) > 0);

    const value = state.document_original.float_of(node).?;
    var sink: std.Io.Writer = undefined;
    var writer: toml.Writer = undefined;

    try scratch_writer(state, &sink, &writer);
    try writer.float(value);

    writer.finish();

    const written = sink.buffered();

    assert(written[written.len - 1] == '\n');

    const text = written[scratch_prefix.len .. written.len - 1];

    try std.testing.expect(std.mem.findAny(u8, text, ".en") != null);

    state.coverage.getPtr(float_counter_of(value, text)).* += 1;

    if (std.math.isNan(value)) return;

    const parsed = try std.fmt.parseFloat(f64, text);

    try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(parsed)));
}

fn float_counter_of(value: f64, text: []const u8) Counter {
    assert(std.mem.findAny(u8, text, ".en") != null);
    assert(std.math.isNan(value) == std.mem.endsWith(u8, text, "nan"));

    if (!std.math.isFinite(value)) return .float_special;
    if (value == 0) return .float_special;
    if (std.mem.findScalar(u8, text, 'e') != null) return .float_scientific;
    if (@abs(value) < 1) return .float_small;
    if (std.mem.endsWith(u8, text, ".0")) return .float_whole;
    return .float_fraction;
}

fn string_record(state: *State, text: []const u8) !void {
    assert(text.len <= fuzz_model.text_bytes_max);
    assert(state.document_original.node_count > 0);

    var sink: std.Io.Writer = undefined;
    var writer: toml.Writer = undefined;

    try scratch_writer(state, &sink, &writer);
    try writer.string(text);

    writer.finish();

    const written = sink.buffered();

    assert(written[written.len - 1] == '\n');

    const value = written[scratch_prefix.len .. written.len - 1];
    const style = style_written_of(value);
    const expected = style_expected_of(state, text);

    if (style != expected) {
        std.debug.print("writer: {f} under {t} took {t}, the rule gives {t}\n", .{
            std.zig.fmtString(text),
            state.options.strings,
            style,
            expected,
        });

        return error.TestUnexpectedResult;
    }

    const escaped = std.mem.findScalar(u8, value, '\\') != null;

    const counter: Counter = switch (style) {
        .basic => if (escaped) .string_basic_escaped else .string_basic,
        .basic_multiline => .string_basic_multiline,
        .literal => .string_literal,
        .literal_multiline => .string_literal_multiline,
    };

    state.coverage.getPtr(counter).* += 1;

    if (style == .basic_multiline) {
        const run = std.mem.find(u8, text, "\"\"\"") != null;

        if (run) state.coverage.getPtr(.string_quote_run).* += 1;
    }
}

fn style_written_of(value: []const u8) Style {
    assert(value.len >= 2);
    assert(value[0] == '"' or value[0] == '\'');

    if (std.mem.startsWith(u8, value, "\"\"\"\n")) return .basic_multiline;
    if (std.mem.startsWith(u8, value, "'''\n")) return .literal_multiline;
    if (value[0] == '\'') return .literal;
    return .basic;
}

const Classes = struct {
    backslash: bool,
    carriage: bool,
    control: bool,
    newline: bool,
    quote_double: bool,
    quote_single: bool,
};

fn classes_of(text: []const u8) Classes {
    assert(text.len <= fuzz_model.text_bytes_max);

    var result: Classes = .{
        .backslash = false,
        .carriage = false,
        .control = false,
        .newline = false,
        .quote_double = false,
        .quote_single = false,
    };

    for (text) |byte| {
        switch (byte) {
            '\n' => result.newline = true,
            '\r' => result.carriage = true,
            '"' => result.quote_double = true,
            '\\' => result.backslash = true,
            '\'' => result.quote_single = true,
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => result.control = true,
            else => {},
        }
    }

    return result;
}

fn style_expected_of(state: *const State, text: []const u8) Style {
    assert(text.len <= fuzz_model.text_bytes_max);
    assert(state.document_original.node_count > 0);

    const classes = classes_of(text);
    const literal_clean = !classes.control and !classes.carriage and !classes.quote_single;

    switch (state.options.strings) {
        .basic => return .basic,
        .auto => {
            if (classes.newline) return .basic_multiline;
            if (!literal_clean) return .basic;
            if (classes.quote_double) return .literal;
            if (classes.backslash) return .literal;
            return .basic;
        },
        .literal => {
            if (!classes.newline) return if (literal_clean) .literal else .basic;
            if (classes.control) return .basic;
            if (classes.carriage) return .basic;
            if (std.mem.find(u8, text, "'''") != null) return .basic;
            return .literal_multiline;
        },
    }
}
