const std = @import("std");

const fuzz_model = @import("fuzz_model.zig");
const storage_module = @import("storage.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;

const Counter = enum {
    find_index,
    find_index_key,
    find_index_nested,
    find_key_quoted,
    kept_accepted,
    kept_lines_exhausted,
    path_only,
};

const Coverage = std.EnumArray(Counter, u64);

const Kept = struct {
    hash_seed: u64,
    outcome: toml.Document.Error!void,
    storage: toml.Storage,
    version: toml.Version,
};

const Reach = enum {
    find_bare,
    find_quoted,
    path_only,
};

const index_digits_max: u32 = 10;
const model_node_count_max: u32 = 1024;
const mutation_count_max: u32 = 8;

comptime {
    assert(fuzz_model.corpus.len > 0);
    assert(std.enums.values(Counter).len == 7);
    assert(std.math.log10_int(@as(u64, std.math.maxInt(u32))) + 1 == index_digits_max);
}

const StorageModel = toml.StorageType(.{
    .line_count_max = null,
    .node_count_max = model_node_count_max,
    .text_bytes_max = fuzz_model.text_bytes_max,
});

const StorageModelKept = toml.StorageType(.{
    .line_count_max = model_node_count_max,
    .node_count_max = model_node_count_max,
    .text_bytes_max = fuzz_model.text_bytes_max,
});

const StorageSmall = toml.StorageType(.{
    .line_count_max = null,
    .node_count_max = 64,
    .text_bytes_max = 1024,
});

const StorageSmallKept = toml.StorageType(.{
    .line_count_max = 64,
    .node_count_max = 64,
    .text_bytes_max = 1024,
});

const Parses = struct {
    default: *const toml.Document,
    kept: *const toml.Document,
};

const Paths = struct {
    digits: [model_node_count_max][index_digits_max]u8,
    indexed: [model_node_count_max]bool,
    positions: [model_node_count_max]u32,
    segments: [model_node_count_max][]const u8,
    text: fuzz_model.Text,
};

const State = struct {
    coverage: Coverage,
    document: toml.Document,
    document_kept: toml.Document,
    document_strict: toml.Document,
    model: fuzz_model.Model,
    paths: Paths,
    storage_model: StorageModel,
    storage_model_kept: StorageModelKept,
    storage_small: StorageSmall,
    storage_small_kept: StorageSmallKept,
    storage_strict: StorageSmall,

    fn storage_seeded(state: *State, storage: toml.Storage) toml.Storage {
        assert(state.storage_small.nodes.len < state.storage_model.nodes.len);
        assert(storage.nodes.len <= state.storage_model.nodes.len);

        var result = storage;

        result.hash_seed = state.model.prng.random().int(u64);

        return result;
    }
};

pub const Mode = enum {
    model,
    mutation,
};

pub fn main(gpa: std.mem.Allocator, options: fuzz_model.Options, mode: Mode) !void {
    assert(options.events_max > 0);
    assert(options.events_max <= fuzz_model.events_full);
    assert(@backingInt(mode) < std.enums.values(Mode).len);

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    state.coverage = .initFill(0);
    state.model.prng = .init(options.seed);
    state.model.text = .empty;

    for (0..options.events_max) |_| {
        switch (mode) {
            .model => try model_event(state),
            .mutation => try mutation_event(state),
        }
    }

    const report: fuzz_model.CoverageReport = .{
        .events_max = options.events_max,
        .fuzzer = @tagName(mode),
    };

    try fuzz_model.coverage_report(Counter, &state.coverage, report);
}

fn mutation_event(state: *State) !void {
    assert(state.model.text.count() <= fuzz_model.text_bytes_max);

    const random = state.model.prng.random();
    const text = &state.model.text;

    text.* = .empty;

    try text.push(fuzz_model.corpus[random.uintLessThan(u32, fuzz_model.corpus.len)]);

    const mutation_count = random.intRangeAtMost(u32, 1, mutation_count_max);

    for (0..mutation_count) |_| fuzz_model.text_mutate(&state.model.prng, text);

    const source = text.slice();
    const strict_storage = state.storage_seeded(state.storage_strict.storage());
    const relaxed_storage = state.storage_seeded(state.storage_small.storage());
    const relaxed_outcome = state.document.parse(relaxed_storage, source, .{ .version = .v1_1 });

    try kept_check(state, source, .{
        .hash_seed = relaxed_storage.hash_seed,
        .outcome = relaxed_outcome,
        .storage = state.storage_small_kept.storage(),
        .version = .v1_1,
    });

    const strict_accepted = accepted: {
        state.document_strict.parse(strict_storage, source, .{ .version = .v1_0 }) catch {
            try diagnostic_check(source, &state.document_strict.diagnostic);

            break :accepted false;
        };

        try fuzz_model.document_audit(&state.document_strict, source);

        break :accepted true;
    };

    relaxed_outcome catch |err| {
        try diagnostic_check(source, &state.document.diagnostic);

        if (strict_accepted) {
            std.debug.print("1.1 refused {t} what 1.0 accepted:\n{s}\n", .{ err, source });

            return error.TestUnexpectedResult;
        }

        return;
    };

    try fuzz_model.document_audit(&state.document, source);
    try paths_check(state, source);

    if (strict_accepted) try documents_compare(state);
}

fn diagnostic_check(source: []const u8, diagnostic: *const toml.Position) !void {
    assert(source.len <= fuzz_model.text_bytes_max);
    assert(diagnostic.line <= source.len + 1);

    const line_count: u32 = @intCast(std.mem.countScalar(u8, source, '\n') + 1);

    try std.testing.expect(diagnostic.line >= 1);
    try std.testing.expect(diagnostic.line <= line_count);
    try std.testing.expect(diagnostic.column >= 1);
    try std.testing.expect(diagnostic.column <= source.len + 1);
    try std.testing.expect(diagnostic.offset <= source.len);

    const before = source[0..diagnostic.offset];
    const line_start = if (std.mem.findScalarLast(u8, before, '\n')) |found| found + 1 else 0;

    try std.testing.expectEqual(std.mem.countScalar(u8, before, '\n') + 1, diagnostic.line);
    try std.testing.expect(diagnostic.column <= diagnostic.offset - line_start + 1);
}

fn documents_compare(state: *const State) !void {
    assert(state.document_strict.node_count > 0);
    assert(state.document.node_count > 0);

    const strict = &state.document_strict;
    const relaxed = &state.document;

    try std.testing.expectEqual(strict.node_count, relaxed.node_count);

    for (0..strict.node_count) |position| {
        const index: u32 = @intCast(position);
        const left = &strict.nodes[index];
        const right = &relaxed.nodes[index];

        try std.testing.expectEqual(left.kind, right.kind);
        try std.testing.expectEqual(left.parent, right.parent);
        try std.testing.expectEqual(left.count, right.count);
        try std.testing.expectEqual(left.section, right.section);
        try std.testing.expectEqual(left.flags, right.flags);
        try std.testing.expectEqualStrings(left.key, right.key);

        const node: toml.Node = @fromBackingInt(index);

        try std.testing.expectEqual(strict.position_of(node), relaxed.position_of(node));

        switch (strict.value_of(node)) {
            .array, .table => {},
            .string => |text| try std.testing.expectEqualStrings(text, relaxed.string_of(node).?),
            .float => |value| {
                const bits: u64 = @bitCast(value);

                try std.testing.expectEqual(bits, @as(u64, @bitCast(relaxed.float_of(node).?)));
            },
            else => |value| try std.testing.expectEqual(value, relaxed.value_of(node)),
        }
    }
}

fn model_event(state: *State) !void {
    assert(state.model.text.count() <= fuzz_model.text_bytes_max);

    const random = state.model.prng.random();
    const version: toml.Version = if (random.boolean()) .v1_0 else .v1_1;
    const source = try state.model.generate(version);

    assert(source.len == state.model.text.count());

    const storage = state.storage_seeded(state.storage_model.storage());
    const outcome = state.document.parse(storage, source, .{ .version = version });

    try kept_check(state, source, .{
        .hash_seed = storage.hash_seed,
        .outcome = outcome,
        .storage = state.storage_model_kept.storage(),
        .version = version,
    });

    outcome catch |err| {
        std.debug.print("model document refused at {t}: {t} at {d}:{d}\n{s}\n", .{
            version,
            err,
            state.document.diagnostic.line,
            state.document.diagnostic.column,
            source,
        });

        return err;
    };

    try state.model.verify(&state.document);
    try fuzz_model.document_audit(&state.document, source);
    try paths_check(state, source);
}

fn kept_check(state: *State, source: []const u8, kept: Kept) !void {
    assert(kept.storage.lines.len > 0);
    assert(source.len <= fuzz_model.text_bytes_max);

    const random = state.model.prng.random();
    var storage = kept.storage;

    storage.hash_seed = kept.hash_seed;

    if (random.uintLessThan(u32, 16) == 0) {
        storage.lines = storage.lines[0..random.intRangeAtMost(u32, 1, 8)];
    }

    const document = &state.document_kept;
    const outcome = document.parse(storage, source, .{ .version = kept.version });
    errdefer std.debug.print("the parse with lines kept differs at {t}\n{s}\n", .{
        kept.version,
        source,
    });

    if (outcome) |_| {
        try kept.outcome;
        try records_same(.{ .default = &state.document, .kept = document });

        state.coverage.getPtr(.kept_accepted).* += 1;
    } else |err| {
        if (err == error.LinesExhausted) {
            state.coverage.getPtr(.kept_lines_exhausted).* += 1;

            return;
        }

        try std.testing.expectError(err, kept.outcome);
        try std.testing.expectEqual(state.document.diagnostic, document.diagnostic);
    }
}

fn records_same(parses: Parses) !void {
    assert(parses.default.node_count > 0);
    assert(parses.kept.node_count > 0);

    const default = parses.default;
    const kept = parses.kept;

    try std.testing.expectEqual(default.node_count, kept.node_count);
    try std.testing.expectEqual(default.text_used, kept.text_used);
    try std.testing.expectEqual(default.indexed_count, kept.indexed_count);
    try std.testing.expectEqual(@as(u32, 0), default.line_count);

    for (default.nodes[0..default.node_count], kept.nodes[0..kept.node_count]) |*left, *right| {
        var flags = right.flags;

        try std.testing.expectEqual(storage_module.Owner.none, left.flags.owner);

        flags.owner = .none;

        try std.testing.expectEqual(left.flags, flags);
        try std.testing.expectEqual(left.kind, right.kind);
        try std.testing.expectEqual(left.parent, right.parent);
        try std.testing.expectEqual(left.child_first, right.child_first);
        try std.testing.expectEqual(left.child_last, right.child_last);
        try std.testing.expectEqual(left.sibling_next, right.sibling_next);
        try std.testing.expectEqual(left.indexed_next, right.indexed_next);
        try std.testing.expectEqual(left.count, right.count);
        try std.testing.expectEqual(left.section, right.section);
        try std.testing.expectEqualStrings(left.key, right.key);
    }

    for (0..default.node_count) |position| {
        const node: toml.Node = @fromBackingInt(@as(u32, @intCast(position)));

        try values_same(parses, node);
    }
}

fn values_same(parses: Parses, node: toml.Node) !void {
    assert(@backingInt(node) < parses.default.node_count);
    assert(parses.default.node_count == parses.kept.node_count);

    const default = parses.default;
    const kept = parses.kept;

    switch (default.value_of(node)) {
        .array, .table => {},
        .string => |text| try std.testing.expectEqualStrings(text, kept.string_of(node).?),
        .float => |value| {
            const bits: u64 = @bitCast(value);

            try std.testing.expectEqual(bits, @as(u64, @bitCast(kept.float_of(node).?)));
        },
        else => |value| try std.testing.expectEqual(value, kept.value_of(node)),
    }
}

fn paths_check(state: *State, source: []const u8) !void {
    assert(state.document.node_count <= model_node_count_max);
    assert(state.document.source.ptr == source.ptr);

    const document = &state.document;

    try positions_fill(&state.paths, document);

    for (0..document.node_count) |position| {
        const node: toml.Node = @fromBackingInt(@as(u32, @intCast(position)));
        errdefer std.debug.print("the path to node {d} failed in\n{s}\n", .{ position, source });

        try path_check(state, node);
    }
}

fn positions_fill(paths: *Paths, document: *const toml.Document) !void {
    assert(document.node_count > 0);
    assert(document.node_count <= paths.positions.len);

    for (0..document.node_count) |position| {
        const array: toml.Node = @fromBackingInt(@as(u32, @intCast(position)));
        var elements = document.items(array);

        for (0..elements.remaining) |index| {
            const element = elements.next() orelse return error.TestUnexpectedResult;

            paths.positions[@backingInt(element)] = @intCast(index);
        }
    }
}

fn path_check(state: *State, node: toml.Node) !void {
    assert(@backingInt(node) < state.document.node_count);
    assert(state.document.node_count <= model_node_count_max);

    const document = &state.document;
    const paths = &state.paths;
    const depth = try segments_fill(paths, document, node);
    const found = document.path_find(document.root(), paths.segments[0..depth]);

    try std.testing.expectEqual(@as(?toml.Node, node), found);

    if (depth == 0) return;

    switch (reach_of(paths, depth)) {
        .find_bare => {},
        .find_quoted => state.coverage.getPtr(.find_key_quoted).* += 1,
        .path_only => {
            state.coverage.getPtr(.path_only).* += 1;

            return;
        },
    }

    try find_text_build(paths, depth);

    const text = paths.text.slice();
    errdefer std.debug.print("find({s}) differs from path_find\n", .{text});

    const value = document.find(text) orelse return error.TestUnexpectedResult;

    try value_expect(document, node, value);

    indices_record(&state.coverage, paths, depth);
}

fn segments_fill(paths: *Paths, document: *const toml.Document, node: toml.Node) !u32 {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= paths.segments.len);

    var depth: u32 = 0;
    var ancestor = @backingInt(node);

    for (0..document.node_count) |_| {
        if (ancestor == 0) break;

        ancestor = document.nodes[ancestor].parent;
        depth += 1;
    }

    assert(ancestor == 0);

    var cursor = @backingInt(node);

    for (0..depth) |step| {
        const slot = depth - 1 - step;
        const parent = document.nodes[cursor].parent;
        const element = document.kind_of(@fromBackingInt(parent)) == .array;

        paths.indexed[slot] = element;

        paths.segments[slot] = if (element)
            try std.mem.print(&paths.digits[slot], "{d}", .{paths.positions[cursor]})
        else
            document.key_of(@fromBackingInt(cursor));

        cursor = parent;
    }

    assert(cursor == 0);

    return depth;
}

fn reach_of(paths: *const Paths, depth: u32) Reach {
    assert(depth > 0);
    assert(!paths.indexed[0]);

    var result: Reach = .find_bare;
    var key_empty_before = false;

    for (paths.segments[0..depth], paths.indexed[0..depth]) |segment, indexed| {
        if (indexed) {
            if (key_empty_before) return .path_only;

            continue;
        }

        if (std.mem.findAny(u8, segment, ".[") != null) return .path_only;

        if (!key_bare(segment)) result = .find_quoted;

        key_empty_before = segment.len == 0;
    }

    assert(result != .path_only);

    return result;
}

fn key_bare(key: []const u8) bool {
    assert(key.len <= toml.limits.source_bytes_max);

    if (key.len == 0) return false;

    for (key) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }

    return true;
}

fn find_text_build(paths: *Paths, depth: u32) !void {
    assert(depth > 0);
    assert(!paths.indexed[0]);

    paths.text = .empty;

    for (paths.segments[0..depth], paths.indexed[0..depth], 0..) |segment, indexed, slot| {
        if (indexed) {
            try paths.text.print("[{s}]", .{segment});

            continue;
        }

        if (slot > 0) try paths.text.push(".");

        try paths.text.push(segment);
    }

    assert(paths.text.count() + 1 >= depth);
}

fn value_expect(document: *const toml.Document, node: toml.Node, found: toml.Value) !void {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= model_node_count_max);

    const expected = document.value_of(node);

    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(found));

    switch (expected) {
        .float => |float| {
            const bits: u64 = @bitCast(float);

            try std.testing.expectEqual(bits, @as(u64, @bitCast(found.float)));
        },
        .array, .boolean, .datetime, .integer, .string, .table => {
            try std.testing.expectEqual(expected, found);
        },
    }
}

fn indices_record(coverage: *Coverage, paths: *const Paths, depth: u32) void {
    assert(depth > 0);
    assert(!paths.indexed[0]);

    const indexed = paths.indexed[0..depth];
    const index_any = std.mem.findScalar(bool, indexed, true) != null;
    const index_key = std.mem.find(bool, indexed, &.{ true, false }) != null;
    const index_nested = std.mem.find(bool, indexed, &.{ true, true }) != null;

    if (index_any) coverage.getPtr(.find_index).* += 1;
    if (index_key) coverage.getPtr(.find_index_key).* += 1;
    if (index_nested) coverage.getPtr(.find_index_nested).* += 1;
}
