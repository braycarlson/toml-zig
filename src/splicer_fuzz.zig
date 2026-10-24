const std = @import("std");

const document_fuzz = @import("document_fuzz.zig");
const fuzz_model = @import("fuzz_model.zig");
const serializer = @import("serializer.zig");
const splicer = @import("splicer.zig");
const storage_module = @import("storage.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;

const Prng = std.Random.DefaultPrng;
const Record = storage_module.Record;

const element_append = toml.Document.append;

const Counter = enum {
    append_empty,
    append_multi_line,
    append_section,
    append_single_line,
    byte_order_mark,
    crlf,
    displaced,
    dotted_member,
    element_remove_line,
    element_remove_single,
    element_replace,
    final_newline,
    implicit_header,
    line_drop,
    member_new,
    merge,
    root_headerless,
    section_drop,
    section_new,
    value_replace,
};

const Coverage = std.EnumArray(Counter, u64);

const Span = struct {
    end: u32,
    start: u32,
};

const Spans = @import("bounded").ArrayType(Span, span_count_max);

const capacity_kept: toml.Capacity = .{
    .line_count_max = line_count_max,
    .node_count_max = node_count_max,
    .text_bytes_max = output_bytes_max,
};

const StorageKept = toml.StorageType(capacity_kept);

const StorageMerge = toml.StorageType(.{
    .line_count_max = null,
    .node_count_max = 64,
    .text_bytes_max = 1024,
});

const State = struct {
    counts: [node_count_max]u32,
    coverage: Coverage,
    document: toml.Document,
    document_again: toml.Document,
    document_merge: toml.Document,
    document_reference: toml.Document,
    corpus: bool,
    dump: ?*std.Io.Writer,
    model: fuzz_model.Model,
    output: [output_bytes_max]u8,
    output_again: [output_bytes_max]u8,
    output_reference: [output_bytes_max]u8,
    pairs: fuzz_model.Pairs,
    spans: Spans,
    storage: StorageKept,
    storage_again: StorageKept,
    storage_merge: StorageMerge,
    storage_reference: StorageKept,
    version: toml.Version,
};

const line_count_max: u32 = 2048;
const node_count_max: u32 = 2048;
const none = storage_module.none;
const operation_count_max: u32 = 6;
const output_bytes_max: u32 = 1 << 18;
const span_count_max: u32 = 4096;

comptime {
    assert(output_bytes_max > fuzz_model.text_bytes_max);
    assert(span_count_max >= 2 * line_count_max);
}

pub fn main(gpa: std.mem.Allocator, options: fuzz_model.Options) !void {
    assert(options.events_max > 0);
    assert(options.events_max <= fuzz_model.events_full);

    try run(gpa, options, null);
}

pub fn run(gpa: std.mem.Allocator, options: fuzz_model.Options, dump: ?*std.Io.Writer) !void {
    assert(options.events_max > 0);
    assert(options.events_max <= fuzz_model.events_full);
    assert(dump == null or dump.?.end <= dump.?.buffer.len);

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    state.coverage = .initFill(0);
    state.dump = dump;
    state.model.prng = .init(options.seed);
    state.model.text = .empty;

    for (0..options.events_max) |_| try event(state);

    const report: fuzz_model.CoverageReport = .{
        .events_max = options.events_max,
        .fuzzer = "splicer",
    };

    try fuzz_model.coverage_report(Counter, &state.coverage, report);
}

fn event(state: *State) !void {
    assert(state.model.text.count() <= fuzz_model.text_bytes_max);

    const random = state.model.prng.random();
    const source = try source_pick(state);
    const document = &state.document;

    document.parse(state.storage.storage(), source, .{ .version = state.version }) catch |err| {
        if (state.corpus) return;

        std.debug.print("splicer: the source was refused with {t}\n{s}\n", .{ err, source });

        return err;
    };

    try identity_check(state, source);

    for (0..document.node_count) |position| state.counts[position] = document.nodes[position].count;

    const operation_count = random.intRangeAtMost(u32, 1, operation_count_max);

    for (0..operation_count) |_| try operation_run(state);

    rules_record(state);
    try script_check(state);
}

fn source_pick(state: *State) ![]const u8 {
    assert(state.model.text.count() <= fuzz_model.text_bytes_max);
    assert(fuzz_model.corpus.len > 0);

    const random = state.model.prng.random();

    state.corpus = random.uintLessThan(u32, 4) == 0;

    if (!state.corpus) {
        state.version = if (random.boolean()) .v1_0 else .v1_1;

        return state.model.generate(state.version);
    }

    const text = &state.model.text;
    const entry = fuzz_model.corpus[random.uintLessThan(u32, fuzz_model.corpus.len)];

    state.version = .v1_1;
    text.* = .empty;

    try text.push(entry);

    if (random.boolean()) {
        const trimmed = std.mem.trimEnd(u8, text.slice(), "\n");

        text.truncate(@intCast(trimmed.len));
    }

    return text.slice();
}

fn identity_check(state: *State, source: []const u8) !void {
    assert(state.document.lines.len > 0);
    assert(source.len <= fuzz_model.text_bytes_max);

    var sink: std.Io.Writer = .fixed(&state.output);

    try state.document.write(&sink, .{ .version = state.version });
    try std.testing.expectEqualStrings(source, sink.buffered());

    sink = .fixed(&state.output);

    try splicer.splice(&state.document, &sink, .{ .version = state.version });

    std.testing.expectEqualStrings(source, sink.buffered()) catch |err| {
        std.debug.print("splicer: the walk changed an unedited document\n", .{});

        return err;
    };
}

fn operation_run(state: *State) !void {
    assert(state.document.node_count > 0);
    assert(state.document.lines.len > 0);

    const random = state.model.prng.random();

    switch (random.uintLessThan(u32, 100)) {
        0...39 => try set_random(state),
        40...54 => try replace_random(state),
        55...69 => try append_random(state),
        70...94 => remove_random(state),
        else => try merge_random(state),
    }
}

fn node_pick(state: *State, kind: ?toml.Kind) u32 {
    assert(state.document.node_count > 0);
    assert(state.document.node_count <= node_count_max);
    assert(kind == null or kind.? == .array or kind.? == .table);

    const document = &state.document;
    const random = state.model.prng.random();
    const start = random.uintLessThan(u32, document.node_count);

    for (0..document.node_count) |offset| {
        const index: u32 = @intCast((start + offset) % document.node_count);
        const record = &document.nodes[index];
        if (record.flags.detached) continue;

        if (kind) |wanted| {
            if (record.kind != wanted) continue;
        }

        assert(index < document.node_count);

        return index;
    }

    return none;
}

fn set_random(state: *State) !void {
    assert(state.document.node_count > 0);
    assert(state.document.nodes[0].kind == .table);

    const table = node_pick(state, .table);

    var key: document_fuzz.Key = undefined;
    var text: document_fuzz.Text = undefined;

    try document_fuzz.key_pick(&state.model.prng, &key);

    const content = try document_fuzz.content_pick(&state.model.prng, &text);

    _ = state.document.set(@fromBackingInt(table), key.slice(), content) catch return;
}

fn replace_random(state: *State) !void {
    assert(state.document.node_count > 0);
    assert(state.document.nodes[0].kind == .table);

    const document = &state.document;
    const member = node_pick(state, null);
    if (member == 0) return;
    if (member == none) return;

    const parent = document.nodes[member].parent;
    if (document.nodes[parent].kind != .table) return;

    var text: document_fuzz.Text = undefined;

    const content = try document_fuzz.content_pick(&state.model.prng, &text);
    const key = document.nodes[member].key;

    _ = document.set(@fromBackingInt(parent), key, content) catch return;
}

fn append_random(state: *State) !void {
    assert(state.document.node_count > 0);
    assert(state.document.nodes[0].kind == .table);

    const array = node_pick(state, .array);
    if (array == none) return;

    var text: document_fuzz.Text = undefined;

    const random = state.model.prng.random();
    const record = &state.document.nodes[array];
    const tables = record.flags.array_of_tables and random.uintLessThan(u32, 4) > 0;

    const content: toml.Document.Content = if (tables)
        .{ .table = .implicit }
    else
        try document_fuzz.content_pick(&state.model.prng, &text);

    const element = element_append(&state.document, @fromBackingInt(array), content) catch return;

    if (!tables) return;

    _ = state.document.set(element, "n", .{ .integer = random.int(i8) }) catch return;
}

fn remove_random(state: *State) void {
    assert(state.document.node_count > 0);
    assert(state.document.nodes[0].kind == .table);

    const node = node_pick(state, null);
    if (node == 0) return;
    if (node == none) return;

    state.document.remove(@fromBackingInt(node));
}

fn merge_random(state: *State) !void {
    assert(state.document.node_count > 0);
    assert(fuzz_model.corpus.len > 0);

    const random = state.model.prng.random();
    const entry = fuzz_model.corpus[random.uintLessThan(u32, fuzz_model.corpus.len)];
    const storage = state.storage_merge.storage();

    state.document_merge.parse(storage, entry, .{ .version = .v1_1 }) catch return;

    const arrays: toml.Document.Merge.Arrays = if (random.boolean()) .join else .replace;

    state.document.merge(&state.document_merge, .{ .arrays = arrays }) catch return;
    state.coverage.getPtr(.merge).* += 1;
}

fn script_check(state: *State) !void {
    assert(state.document.node_count > 0);
    assert(state.document.lines.len > 0);

    const random = state.model.prng.random();

    const options: toml.Writer.Options = .{
        .layout = if (random.boolean()) .compact else .vertical,
        .strings = std.enums.values(toml.Writer.Strings)[random.uintLessThan(u32, 3)],
        .version = state.version,
    };

    var sink: std.Io.Writer = .fixed(&state.output);

    try state.document.write(&sink, options);

    const written = sink.buffered();
    errdefer std.debug.print("splicer: the script failed on\n{s}\n-- written --\n{s}\n", .{
        state.document.source,
        written,
    });

    try again_check(state, written, options);
    try reference_check(state, written, options);
    try untouched_check(state, written);

    if (state.dump) |dump| try dump_write(state, dump, written);
}

fn again_check(state: *State, written: []const u8, options: toml.Writer.Options) !void {
    assert(written.len <= output_bytes_max);
    assert(state.document.node_count > 0);
    assert(options.version == state.version);

    const again = &state.document_again;
    const parse_options: toml.Document.Options = .{ .version = state.version };

    again.parse(state.storage_again.storage(), written, parse_options) catch |err| {
        std.debug.print("splicer: the written text was refused with {t}\n", .{err});

        return err;
    };

    const documents: fuzz_model.Documents = .{ .left = &state.document, .right = again };
    const compare: fuzz_model.Compare = .{ .forms = false, .seconds = state.version == .v1_0 };

    try fuzz_model.trees_compare(documents, &state.pairs, compare);

    var sink: std.Io.Writer = .fixed(&state.output_again);

    try splicer.splice(again, &sink, options);

    std.testing.expectEqualStrings(written, sink.buffered()) catch |err| {
        std.debug.print("splicer: a second parse and write changed the bytes\n", .{});

        return err;
    };
}

fn reference_check(state: *State, written: []const u8, options: toml.Writer.Options) !void {
    assert(written.len <= output_bytes_max);
    assert(state.document_again.node_count > 0);
    assert(options.version == state.version);

    var sink: std.Io.Writer = .fixed(&state.output_reference);

    try serializer.write(&state.document, &sink, options);

    const reference = &state.document_reference;
    const storage = state.storage_reference.storage();

    try reference.parse(storage, sink.buffered(), .{ .version = state.version });

    const documents: fuzz_model.Documents = .{
        .left = &state.document_again,
        .right = reference,
    };

    const compare: fuzz_model.Compare = .{ .forms = true, .seconds = false };

    fuzz_model.trees_compare(documents, &state.pairs, compare) catch |err| {
        std.debug.print("splicer: the forms differ from the serializer's\n{s}\n", .{
            sink.buffered(),
        });

        return err;
    };
}

fn dump_write(state: *State, dump: *std.Io.Writer, written: []const u8) !void {
    assert(written.len <= output_bytes_max);
    assert(state.document_reference.node_count > 0);

    const reference = state.document_reference.source;

    try dump.print("{t} {d} {d}\n", .{ state.version, written.len, reference.len });
    try dump.writeAll(written);
    try dump.writeAll(reference);
}

fn untouched_check(state: *State, written: []const u8) !void {
    assert(written.len <= output_bytes_max);
    assert(state.document.line_count <= line_count_max);

    try spans_collect(state);

    const source = state.document.source;
    var cursor: u32 = 0;

    for (state.spans.slice()) |span| {
        const text = source[span.start..span.end];

        const found: u32 = @intCast(std.mem.findPos(u8, written, cursor, text) orelse {
            std.debug.print("splicer: an untouched line is missing or out of order: {f}\n", .{
                std.zig.fmtString(text),
            });

            return error.TestUnexpectedResult;
        });

        cursor = found + span.end - span.start;
    }
}

fn spans_collect(state: *State) !void {
    assert(state.document.line_count <= line_count_max);
    assert(state.document.node_count_parsed <= state.document.node_count);

    const document = &state.document;
    const lines = document.lines[0..document.line_count];
    var previous = true;

    state.spans = .empty;

    for (lines, 0..) |line, number| {
        const kept = untouched(document, line.node);

        if (kept) {
            const gap_start = if (number == 0) 0 else lines[number - 1].end;

            if (previous) try comments_push(state, .{ .end = line.start, .start = gap_start });

            try state.spans.push_slice(&.{.{ .end = line.end, .start = line.start }});
        }

        previous = kept;
    }
}

fn comments_push(state: *State, gap: Span) !void {
    assert(gap.start <= gap.end);
    assert(gap.end <= state.document.source.len);

    const source = state.document.source;
    var cursor = gap.start;

    for (0..gap.end - gap.start + 1) |_| {
        if (cursor >= gap.end) return;

        const newline = std.mem.findScalarPos(u8, source[0..gap.end], cursor, '\n');
        const line_end: u32 = if (newline) |found| @intCast(found) else gap.end;
        const text = std.mem.trimStart(u8, source[cursor..line_end], " \t");

        if (std.mem.startsWith(u8, text, "#")) {
            try state.spans.push_slice(&.{.{ .end = line_end, .start = cursor }});
        }

        cursor = line_end + 1;
    }
}

fn untouched(document: *const toml.Document, owner: u32) bool {
    assert(owner < document.node_count_parsed);
    assert(document.node_count_parsed <= document.node_count);

    const record = &document.nodes[owner];

    if (!chain_untouched(document, owner)) return false;
    if (record.flags.owner == .header) return true;

    for (owner..subtree_end(document, owner)) |index| {
        const below = &document.nodes[index];
        if (below.flags.detached) return false;
        if (below.flags.edited) return false;
        if (below.child_last == none) continue;
        if (below.child_last >= document.node_count_parsed) return false;
    }

    return true;
}

fn chain_untouched(document: *const toml.Document, owner: u32) bool {
    assert(owner < document.node_count_parsed);
    assert(owner > 0);

    var current = owner;

    for (0..toml.limits.depth_max + 2) |_| {
        if (current == 0) return true;

        const record = &document.nodes[current];
        if (record.flags.detached) return false;
        if (record.flags.edited) return false;

        switch (record.kind) {
            .array => if (record.flags.array_of_tables) {
                if (!serializer.array_of_tables_writable(document, record)) return false;
            },
            .table => if (dotted_emptied(record)) return false,
            .boolean, .datetime, .float, .integer, .string => {},
        }

        current = record.parent;
    }

    unreachable;
}

fn dotted_emptied(record: *const Record) bool {
    assert(record.kind == .table);
    assert(!record.flags.detached);

    if (record.flags.closed) return false;
    if (record.flags.explicit) return false;
    if (record.section == none) return false;
    return record.count == 0;
}

fn subtree_end(document: *const toml.Document, node: u32) u32 {
    assert(node < document.node_count_parsed);
    assert(document.node_count_parsed <= document.node_count);

    var index = node + 1;

    for (node + 1..document.node_count_parsed) |_| {
        const parent = document.nodes[index].parent;
        if (parent == none) break;
        if (parent < node) break;

        index += 1;
    }

    assert(index > node);

    return index;
}

fn rules_record(state: *State) void {
    assert(state.document.node_count > 0);
    assert(state.document.node_count_parsed <= state.document.node_count);

    const document = &state.document;
    const source = document.source;

    if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) {
        state.coverage.getPtr(.byte_order_mark).* += 1;
    }

    if (std.mem.findScalar(u8, source, '\n')) |newline| {
        if (std.mem.endsWith(u8, source[0..newline], "\r")) state.coverage.getPtr(.crlf).* += 1;
    }

    if (document.nodes[0].flags.edited) {
        if (final_newline_missing(source)) state.coverage.getPtr(.final_newline).* += 1;
    }

    for (1..document.node_count) |position| {
        const index: u32 = @intCast(position);

        if (index < document.node_count_parsed) {
            parsed_record(state, index);
        } else {
            fresh_record(state, index);
        }
    }
}

fn final_newline_missing(source: []const u8) bool {
    assert(source.len <= fuzz_model.text_bytes_max);
    assert(fuzz_model.text_bytes_max < output_bytes_max);

    if (source.len == 0) return false;
    return source[source.len - 1] != '\n';
}

fn parsed_record(state: *State, index: u32) void {
    assert(index > 0);
    assert(index < state.document.node_count_parsed);

    const document = &state.document;
    const record = &document.nodes[index];
    const parent = &document.nodes[record.parent];
    const inside = parent.flags.closed or (parent.kind == .array and !parent.flags.array_of_tables);

    if (record.flags.detached) {
        if (inside) state.coverage.getPtr(element_removal(state, index)).* += 1;
        if (record.flags.owner == .pair) state.coverage.getPtr(.line_drop).* += 1;
        if (record.flags.owner == .header) state.coverage.getPtr(.section_drop).* += 1;

        return;
    }

    if (record.flags.edited) {
        if (inside) state.coverage.getPtr(.element_replace).* += 1;

        if (record.flags.owner == .pair) {
            const line = serializer.line_kind_of(document, index) == .line;
            const counter: Counter = if (line) .value_replace else .displaced;

            state.coverage.getPtr(counter).* += 1;
        }
    }

    if (record.kind != .array) return;
    if (!record.flags.array_of_tables) return;

    if (!serializer.array_of_tables_writable(document, record)) {
        state.coverage.getPtr(.displaced).* += 1;
    }
}

fn element_removal(state: *const State, index: u32) Counter {
    assert(index > 0);
    assert(index < state.document.node_count_parsed);

    const document = &state.document;
    const record = &document.nodes[index];
    const parent = record.parent;
    if (parent == 0) return .element_remove_single;
    if (document.nodes[parent].flags.detached) return .element_remove_single;

    const lines = multi_line(document, parent, record);
    return if (lines) .element_remove_line else .element_remove_single;
}

fn multi_line(document: *const toml.Document, container: u32, inner: *const Record) bool {
    assert(container > 0);
    assert(container < document.node_count_parsed);

    const outer = &document.nodes[container];
    const source = document.source;
    const start = @intFromPtr(outer.key.ptr) -| @intFromPtr(source.ptr);
    const end = @intFromPtr(inner.key.ptr) -| @intFromPtr(source.ptr);
    if (start >= end) return false;
    if (end > source.len) return false;
    return std.mem.findScalar(u8, source[start..end], '\n') != null;
}

fn fresh_record(state: *State, index: u32) void {
    assert(index >= state.document.node_count_parsed);
    assert(index < state.document.node_count);

    const document = &state.document;
    const record = &document.nodes[index];
    if (record.flags.detached) return;
    if (record.parent >= document.node_count_parsed) return;

    const parent = &document.nodes[record.parent];
    const line = serializer.line_kind_of(document, index) != .section;

    if (parent.kind == .array) {
        state.coverage.getPtr(append_kind(state, index)).* += 1;

        return;
    }

    if (parent.flags.closed) return;

    if (!line) {
        state.coverage.getPtr(.section_new).* += 1;

        return;
    }

    if (record.parent == 0) {
        if (root_headerless(document)) state.coverage.getPtr(.root_headerless).* += 1;

        return;
    }

    if (parent.flags.explicit) {
        state.coverage.getPtr(.member_new).* += 1;
    } else if (parent.section == none) {
        state.coverage.getPtr(.implicit_header).* += 1;
    } else {
        state.coverage.getPtr(.dotted_member).* += 1;
    }
}

fn append_kind(state: *const State, index: u32) Counter {
    assert(index >= state.document.node_count_parsed);
    assert(state.document.nodes[index].parent < state.document.node_count_parsed);

    const document = &state.document;
    const record = &document.nodes[index];
    const array = &document.nodes[record.parent];

    if (array.flags.array_of_tables) {
        if (serializer.array_of_tables_writable(document, array)) return .append_section;
    }

    if (state.counts[record.parent] == 0) return .append_empty;

    var last = none;
    var child = array.child_first;

    for (0..array.count) |_| {
        if (child == none) break;

        if (child < document.node_count_parsed) last = child;

        child = document.nodes[child].sibling_next;
    }

    if (last == none) return .append_empty;

    const lines = multi_line(document, record.parent, &document.nodes[last]);
    return if (lines) .append_multi_line else .append_single_line;
}

fn root_headerless(document: *const toml.Document) bool {
    assert(document.node_count > 0);
    assert(document.line_count <= document.lines.len);

    if (document.line_count == 0) return true;
    return document.nodes[document.lines[0].node].flags.owner == .header;
}
