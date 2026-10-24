const std = @import("std");

const bounded = @import("bounded.zig");
const fuzz_model = @import("fuzz_model.zig");
const storage_module = @import("storage.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;

const Content = toml.Document.Content;
const element_append = toml.Document.append;
const Prng = std.Random.DefaultPrng;

const Counter = enum {
    append,
    error_datetime,
    error_depth,
    error_nodes,
    error_text,
    error_utf8,
    index_crossed,
    init,
    merge_join,
    merge_partial,
    merge_replace,
    remove_indexed,
    remove_plain,
    remove_rebuild,
    round_trip,
    set_new,
    set_replace,
    set_replace_rebuild,
    written_aot_fallback,
    written_dotted_empty,
    written_implicit_header,
    written_inline_forced,
};

const Coverage = std.EnumArray(Counter, u64);

const Form = enum {
    array_of_tables,
    dotted,
    header,
    implicit,
    inline_array,
    inline_table,
    scalar,
};

pub const Key = bounded.BoundedArrayType(u8, key_bytes_max);
pub const Text = bounded.BoundedArrayType(u8, string_bytes_max);

const Scalar = union(enum) {
    boolean: bool,
    datetime: toml.Datetime,
    float: f64,
    integer: i64,
    none: void,
    string: Text,
};

const Shade = struct {
    alive: bool,
    child_count: u32,
    children: [node_count_limit]u32,
    form: Form,
    indexed: bool,
    key: Key,
    kind: toml.Kind,
    parent: u32,
    scalar: Scalar,
};

const Shadow = struct {
    capacity: toml.Capacity,
    node_count: u32,
    nodes: [node_count_limit]Shade,
    text_used: u32,
};

const Frame = struct {
    position: u32,
    source: u32,
    target: u32,
};

const Frames = bounded.BoundedArrayType(Frame, node_count_limit);
const StorageLarge = toml.StorageType(capacity_large);
const StorageSmall = toml.StorageType(capacity_small);

const StorageWritten = toml.StorageType(.{
    .line_count_max = null,
    .node_count_max = 4096,
    .text_bytes_max = 1 << 16,
});

const Pair = struct {
    document: *toml.Document,
    shadow: *Shadow,
};

const State = struct {
    coverage: Coverage,
    document: toml.Document,
    document_source: toml.Document,
    document_written: toml.Document,
    frames: Frames,
    output: [output_bytes_max]u8,
    pairs: fuzz_model.Pairs,
    prng: Prng,
    shadow: Shadow,
    shadow_source: Shadow,
    storage_large: StorageLarge,
    storage_small: StorageSmall,
    storage_source: StorageSmall,
    storage_written: StorageWritten,
};

const capacity_large: toml.Capacity = .{
    .line_count_max = null,
    .node_count_max = 320,
    .text_bytes_max = 4096,
};

const capacity_small: toml.Capacity = .{
    .line_count_max = null,
    .node_count_max = 48,
    .text_bytes_max = 128,
};

const dive_count_max: u32 = 140;
const fill_count: u32 = 20;
const key_bytes_max: u32 = 8;
const key_count: u32 = 40;
const node_count_limit: u32 = capacity_large.node_count_max;
const none = storage_module.none;
const output_bytes_max: u32 = 1 << 16;
const round_trip_period: u32 = 32;
const scan_member_count_max: u32 = 16;
const source_operation_count_max: u32 = 8;
const string_bytes_max: u32 = 24;

comptime {
    assert(capacity_small.node_count_max < capacity_large.node_count_max);
    assert(key_count > scan_member_count_max);
    assert(dive_count_max > toml.limits.depth_max);
}

const table_forms = std.enums.values(toml.Document.TableForm);
const keys_special = [_][]const u8{ "", "a.b", "x y", "\u{e9}", "\x01", "\"q\"" };

pub fn main(gpa: std.mem.Allocator, options: fuzz_model.Options) !void {
    assert(options.events_max > 0);
    assert(options.events_max <= fuzz_model.events_full);

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    state.coverage = .initFill(0);
    state.prng = .init(options.seed);

    reset(state, .{ .document = &state.document, .shadow = &state.shadow });

    for (0..options.events_max) |event_index| {
        try operation_run(state);
        try shadow_compare(&state.shadow, &state.document);
        try fuzz_model.invariants_check(&state.document);

        if (event_index % round_trip_period == round_trip_period - 1) try round_trip(state);
    }

    const report: fuzz_model.CoverageReport = .{
        .events_max = options.events_max,
        .fuzzer = "document",
    };

    try fuzz_model.coverage_report(Counter, &state.coverage, report);
}

fn reset(state: *State, pair: Pair) void {
    assert(pair.shadow.nodes.len == node_count_limit);
    assert(state.storage_small.nodes.len == capacity_small.node_count_max);

    const large = state.prng.random().boolean();
    const storage = if (large) state.storage_large.storage() else state.storage_small.storage();

    pair.document.init(storage);
    shadow_reset(pair.shadow, if (large) capacity_large else capacity_small);
}

fn operation_run(state: *State) !void {
    assert(state.shadow.node_count == state.document.node_count);
    assert(state.shadow.node_count > 0);

    const random = state.prng.random();
    const pair: Pair = .{ .document = &state.document, .shadow = &state.shadow };

    switch (random.uintLessThan(u32, 100)) {
        0...44 => try set_random(state, pair),
        45...62 => try append_random(state, pair),
        63...82 => remove_random(state),
        83...92 => try merge_random(state),
        93...94 => {
            reset(state, pair);
            state.coverage.getPtr(.init).* += 1;
        },
        95...96 => try dive(state),
        else => try fill(state, pair),
    }
}

fn node_pick(shadow: *const Shadow, prng: *Prng, kind: toml.Kind) u32 {
    assert(shadow.node_count > 0);
    assert(@backingInt(kind) < std.enums.values(toml.Kind).len);

    const random = prng.random();
    const start = random.uintLessThan(u32, shadow.node_count);

    for (0..shadow.node_count) |offset| {
        const index: u32 = @intCast((start + offset) % shadow.node_count);
        const shade = &shadow.nodes[index];
        if (!shade.alive) continue;
        if (shade.kind != kind) continue;

        assert(index < shadow.node_count);

        return index;
    }

    return none;
}

pub fn key_pick(prng: *Prng, key: *Key) !void {
    const random = prng.random();

    key.* = .empty;

    switch (random.uintLessThan(u32, 40)) {
        0 => try key.push_slice(keys_special[random.uintLessThan(u32, keys_special.len)]),
        1 => try key.push_slice("\xff"),
        else => try key.print("k{d}", .{random.uintLessThan(u32, key_count)}),
    }

    assert(key.count <= key_bytes_max);
}

pub fn content_pick(prng: *Prng, text: *Text) !Content {
    const random = prng.random();

    return switch (random.uintLessThan(u32, 16)) {
        0, 1 => .{ .boolean = random.boolean() },
        2, 3 => .{ .integer = random.int(i64) >> random.uintLessThan(u6, 63) },
        4, 5 => .{ .float = float_pick(prng) },
        6, 7, 8 => .{ .string = try string_pick(prng, text) },
        9 => .{ .datetime = datetime_pick(prng) },
        10, 11 => .{ .array = if (random.boolean()) .array_of_tables else .inline_array },
        else => .{ .table = table_forms[random.uintLessThan(u32, table_forms.len)] },
    };
}

fn float_pick(prng: *Prng) f64 {
    const random = prng.random();

    const result: f64 = switch (random.uintLessThan(u32, 8)) {
        0 => std.math.nan(f64),
        1 => -std.math.nan(f64),
        2 => -std.math.inf(f64),
        3 => -0.0,
        4 => random.float(f64) * 1e-7,
        5 => @bitCast(random.int(u64) & 0x7fef_ffff_ffff_ffff),
        else => random.float(f64) * 1000 - 500,
    };

    assert(std.math.isNan(result) or std.math.isFinite(result) or result < 0);

    return result;
}

fn string_pick(prng: *Prng, text: *Text) ![]const u8 {
    const random = prng.random();
    const pieces = [_][]const u8{ "a", "\"", "'", "\\", "\n", "\t", "\r", "\x01", "\u{e9}", "''" };
    const count = random.uintAtMost(u32, 6);

    text.* = .empty;

    if (random.uintLessThan(u32, 40) == 0) {
        try text.push_slice("x\xc3");

        return text.slice();
    }

    for (0..count) |_| try text.push_slice(pieces[random.uintLessThan(u32, pieces.len)]);

    assert(text.count <= 2 * count);

    return text.slice();
}

fn datetime_pick(prng: *Prng) toml.Datetime {
    const random = prng.random();
    const kind = std.enums.values(toml.Datetime.Kind)[random.uintLessThan(u32, 4)];
    const dated = kind != .time_local;
    const timed = kind != .date_local;
    const offset = random.intRangeAtMost(i16, -600, 600);

    var result: toml.Datetime = .{
        .day = if (dated) random.intRangeAtMost(u8, 1, 28) else 0,
        .hour = if (timed) random.intRangeAtMost(u8, 0, 23) else 0,
        .kind = kind,
        .minute = if (timed) random.intRangeAtMost(u8, 0, 59) else 0,
        .month = if (dated) random.intRangeAtMost(u8, 1, 12) else 0,
        .nanosecond = if (timed) random.uintLessThan(u32, 1000) * 1000 else 0,
        .offset_minutes = if (kind == .datetime_offset) offset else 0,
        .second = if (timed) random.intRangeAtMost(u8, 0, 59) else 0,
        .spelling = .canonical,
        .year = if (dated) random.intRangeAtMost(u16, 1, 9999) else 0,
    };

    if (timed) {
        if (random.boolean()) {
            result.second = 0;
            result.nanosecond = 0;
            result.spelling.second_present = false;
        }
    }

    if (result.nanosecond > 0) result.spelling.fraction_present = true;
    if (random.uintLessThan(u32, 16) == 0) result.month = 13;

    assert(result.month <= 13);

    return result;
}

fn set_random(state: *State, pair: Pair) !void {
    assert(pair.shadow.node_count == pair.document.node_count);
    assert(pair.shadow.node_count > 0);

    const table = node_pick(pair.shadow, &state.prng, .table);

    var key: Key = undefined;
    var text: Text = undefined;

    try key_pick(&state.prng, &key);

    const content = try content_pick(&state.prng, &text);

    _ = try set_apply(state, pair, .{ .content = content, .key = key.slice(), .table = table });
}

const Set = struct {
    content: Content,
    key: []const u8,
    table: u32,
};

fn set_apply(state: *State, pair: Pair, operation: Set) !u32 {
    assert(operation.table < pair.shadow.node_count);
    assert(pair.shadow.nodes[operation.table].kind == .table);

    const shadow = pair.shadow;
    const existing = shadow_member(shadow, operation.table, operation.key);
    const predicted = shadow_set_check(shadow, operation, existing);
    const table: toml.Node = @fromBackingInt(operation.table);
    const result = pair.document.set(table, operation.key, operation.content);

    if (predicted) |expected| {
        try std.testing.expectError(expected, result);

        error_record(state, expected);

        return none;
    }

    const node = @backingInt(try result);

    if (existing == none) {
        try std.testing.expectEqual(shadow.node_count, node);

        try shadow_member_add(state, shadow, operation);
        state.coverage.getPtr(.set_new).* += 1;
    } else {
        try std.testing.expectEqual(existing, node);

        const rebuild = shadow_indexed_within(shadow, existing);

        try shadow_reset_in_place(shadow, existing, &operation.content);
        state.coverage.getPtr(if (rebuild) .set_replace_rebuild else .set_replace).* += 1;
    }

    return node;
}

fn error_record(state: *State, err: anyerror) void {
    assert(state.coverage.values.len == std.enums.values(Counter).len);
    assert(@errorName(err).len > 0);

    const counter: Counter = switch (err) {
        error.DatetimeInvalid => .error_datetime,
        error.DepthExceeded => .error_depth,
        error.NodesExhausted => .error_nodes,
        error.TextExhausted => .error_text,
        error.Utf8Invalid => .error_utf8,
        else => unreachable,
    };

    state.coverage.getPtr(counter).* += 1;
}

fn content_error(content: *const Content) ?anyerror {
    switch (content.*) {
        .datetime => |datetime| {
            if (datetime.month > 12) return error.DatetimeInvalid;
        },
        .string => |text| {
            if (!std.unicode.utf8ValidateSlice(text)) return error.Utf8Invalid;
        },
        .array, .boolean, .float, .integer, .table => {},
    }

    return null;
}

fn shadow_set_check(shadow: *const Shadow, operation: Set, existing: u32) ?anyerror {
    assert(operation.table < shadow.node_count);
    assert(existing == none or existing < shadow.node_count);

    if (content_error(&operation.content)) |err| return err;
    if (!std.unicode.utf8ValidateSlice(operation.key)) return error.Utf8Invalid;

    const string_bytes = string_bytes_of(&operation.content);
    const depth = shadow_depth(shadow, operation.table) + 1;
    const reused: Need = .{ .depth = depth, .nodes = 0, .text = string_bytes };
    if (existing != none) return capacity_error(shadow, reused);

    const need: Need = .{ .depth = depth, .nodes = 1, .text = string_bytes + operation.key.len };
    return capacity_error(shadow, need);
}

const Need = struct {
    depth: u32,
    nodes: u32,
    text: u64,
};

fn capacity_error(shadow: *const Shadow, need: Need) ?anyerror {
    assert(need.nodes <= 1);
    assert(shadow.text_used <= shadow.capacity.text_bytes_max);

    const nodes_free = shadow.capacity.node_count_max - shadow.node_count;
    const text_free = shadow.capacity.text_bytes_max - shadow.text_used;

    if (need.nodes > nodes_free) return error.NodesExhausted;
    if (need.text > text_free) return error.TextExhausted;
    if (need.depth > toml.limits.depth_max) return error.DepthExceeded;
    return null;
}

fn string_bytes_of(content: *const Content) u64 {
    const result: u64 = switch (content.*) {
        .string => |text| text.len,
        .array, .boolean, .datetime, .float, .integer, .table => 0,
    };

    assert(result <= string_bytes_max);

    return result;
}

fn append_random(state: *State, pair: Pair) !void {
    assert(pair.shadow.node_count == pair.document.node_count);
    assert(pair.shadow.node_count > 0);

    const array = node_pick(pair.shadow, &state.prng, .array);
    if (array == none) return;

    var text: Text = undefined;
    const content = try content_pick(&state.prng, &text);

    try append_apply(state, pair, .{ .array = array, .content = content });
}

const Append = struct {
    array: u32,
    content: Content,
};

fn append_apply(state: *State, pair: Pair, operation: Append) !void {
    assert(operation.array < pair.shadow.node_count);
    assert(pair.shadow.nodes[operation.array].kind == .array);

    const shadow = pair.shadow;
    const string_bytes = string_bytes_of(&operation.content);
    const depth = shadow_depth(shadow, operation.array) + 1;
    const capacity = capacity_error(shadow, .{ .depth = depth, .nodes = 1, .text = string_bytes });
    const predicted: ?anyerror = content_error(&operation.content) orelse capacity;
    const array: toml.Node = @fromBackingInt(operation.array);
    const result = element_append(pair.document, array, operation.content);

    if (predicted) |expected| {
        try std.testing.expectError(expected, result);

        return error_record(state, expected);
    }

    try std.testing.expectEqual(shadow.node_count, @backingInt(try result));

    const created = try shadow_node_add(shadow, .{ .key = "", .parent = operation.array });

    try shade_content_store(shadow, created, &operation.content);
    state.coverage.getPtr(.append).* += 1;
}

fn remove_random(state: *State) void {
    assert(state.shadow.node_count == state.document.node_count);
    assert(state.shadow.node_count > 0);

    const random = state.prng.random();
    const kind = std.enums.values(toml.Kind)[random.uintLessThan(u32, 7)];
    const node = node_pick(&state.shadow, &state.prng, kind);
    if (node == none) return;
    if (node == 0) return;

    const shadow = &state.shadow;
    const parent = shadow.nodes[node].parent;
    const rebuild = shadow_indexed_within(shadow, node);
    const indexed = shadow.nodes[parent].indexed;

    state.document.remove(@fromBackingInt(node));
    shadow_unlink(shadow, node);
    shadow_kill(shadow, node);

    const plain: Counter = if (indexed) .remove_indexed else .remove_plain;
    const counter: Counter = if (rebuild) .remove_rebuild else plain;

    state.coverage.getPtr(counter).* += 1;
}

fn dive(state: *State) !void {
    assert(state.shadow.node_count == state.document.node_count);
    assert(dive_count_max > toml.limits.depth_max);

    const free = state.shadow.capacity.node_count_max - state.shadow.node_count;
    if (free <= toml.limits.depth_max + 1) return;

    const pair: Pair = .{ .document = &state.document, .shadow = &state.shadow };
    var table: u32 = 0;

    for (0..dive_count_max) |_| {
        const operation: Set = .{ .content = .{ .table = .implicit }, .key = "d", .table = table };
        const created = try set_apply(state, pair, operation);
        if (created == none) return;

        table = created;
    }
}

fn fill(state: *State, pair: Pair) !void {
    assert(pair.shadow.node_count == pair.document.node_count);
    assert(fill_count > scan_member_count_max);

    const table = node_pick(pair.shadow, &state.prng, .table);

    var key: Key = undefined;

    for (0..fill_count) |number| {
        key = .empty;

        try key.print("k{d}", .{number});

        const content: Content = .{ .integer = 1 };
        const operation: Set = .{ .content = content, .key = key.slice(), .table = table };
        if (try set_apply(state, pair, operation) == none) return;
    }
}

fn merge_random(state: *State) !void {
    assert(state.shadow.node_count == state.document.node_count);
    assert(state.storage_source.nodes.len == capacity_small.node_count_max);

    const random = state.prng.random();
    const source: Pair = .{ .document = &state.document_source, .shadow = &state.shadow_source };

    state.document_source.init(state.storage_source.storage());
    shadow_reset(&state.shadow_source, capacity_small);

    for (0..random.uintAtMost(u32, source_operation_count_max)) |_| {
        if (random.uintLessThan(u32, 3) == 0) {
            try append_random(state, source);
        } else {
            try set_random(state, source);
        }
    }

    const arrays: toml.Document.Merge.Arrays = if (random.boolean()) .join else .replace;
    const options: toml.Document.Merge = .{ .arrays = arrays };
    const predicted = shadow_merge(state, options);
    const result = state.document.merge(&state.document_source, options);

    if (predicted) |expected| {
        try std.testing.expectError(expected, result);

        state.coverage.getPtr(.merge_partial).* += 1;

        return;
    }

    try result;

    state.coverage.getPtr(if (arrays == .join) .merge_join else .merge_replace).* += 1;
}

fn shadow_merge(state: *State, options: toml.Document.Merge) ?anyerror {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(state.shadow_source.node_count > 0);
    assert(state.shadow.node_count > 0);

    const target = &state.shadow;
    const source = &state.shadow_source;
    const frames = &state.frames;

    frames.* = .empty;

    frames.push_slot_assume_capacity().* = .{ .position = 0, .source = 0, .target = 0 };

    for (0..2 * source.node_count + 2) |_| {
        if (frames.count == 0) return null;

        const frame = frames.get_mutable(frames.count - 1);
        const table = &source.nodes[frame.source];

        if (frame.position == table.child_count) {
            frames.truncate(frames.count - 1);

            continue;
        }

        const entry = table.children[frame.position];

        frame.position += 1;

        const existing = shadow_member(target, frame.target, source.nodes[entry].key.slice());

        if (existing != none) {
            if (target.nodes[existing].kind == .table) {
                if (source.nodes[entry].kind == .table) {
                    frames.push_slot_assume_capacity().* = .{
                        .position = 0,
                        .source = entry,
                        .target = existing,
                    };

                    continue;
                }
            }
        }

        const step: Step = .{ .entry = entry, .existing = existing, .table = frame.target };
        if (shadow_merge_entry(state, step, options)) |err| return err;
    }

    unreachable;
}

const Step = struct {
    entry: u32,
    existing: u32,
    table: u32,
};

fn shadow_merge_entry(state: *State, step: Step, options: toml.Document.Merge) ?anyerror {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(step.entry < state.shadow_source.node_count);
    assert(step.table < state.shadow.node_count);

    const target = &state.shadow;
    const source = &state.shadow_source;
    const placement: Placement = .{ .entry = step.entry, .parent = step.table };
    if (step.existing == none) return shadow_copy(state, placement);

    const target_array = target.nodes[step.existing].kind == .array;
    const arrays = target_array and source.nodes[step.entry].kind == .array;
    const joined = arrays and options.arrays == .join;

    if (joined) {
        const entry = &source.nodes[step.entry];

        for (entry.children[0..entry.child_count]) |element| {
            const element_placement: Placement = .{ .entry = element, .parent = step.existing };
            if (shadow_copy(state, element_placement)) |err| return err;
        }

        return null;
    }

    const string_bytes = shade_string_bytes(&source.nodes[step.entry]);
    const depth = shadow_depth(target, step.existing);
    const need: Need = .{ .depth = depth, .nodes = 0, .text = string_bytes };
    if (capacity_error(target, need)) |err| return err;

    shadow_children_kill(target, step.existing);
    shade_copy(target, .{ .destination = step.existing, .origin = &source.nodes[step.entry] });

    return shadow_children_copy(state, .{ .entry = step.entry, .parent = step.existing });
}

const Placement = struct {
    entry: u32,
    parent: u32,
};

fn shadow_copy(state: *State, placement: Placement) ?anyerror {
    assert(placement.entry < state.shadow_source.node_count);
    assert(placement.parent < state.shadow.node_count);

    const target = &state.shadow;
    const entry = &state.shadow_source.nodes[placement.entry];
    const depth = shadow_depth(target, placement.parent) + 1;
    const text = shade_string_bytes(entry) + entry.key.count;
    const need: Need = .{ .depth = depth, .nodes = 1, .text = text };
    if (capacity_error(target, need)) |err| return err;

    const added: Added = .{ .key = entry.key.slice(), .parent = placement.parent };
    const created = shadow_node_add(target, added) catch |err| return err;

    shade_copy(target, .{ .destination = created, .origin = entry });

    return shadow_children_copy(state, .{ .entry = placement.entry, .parent = created });
}

fn shadow_children_copy(state: *State, placement: Placement) ?anyerror {
    assert(placement.entry < state.shadow_source.node_count);
    assert(placement.parent < state.shadow.node_count);

    const source = &state.shadow_source;
    const target = &state.shadow;
    const frames = &state.frames;
    const base = frames.count;

    frames.push_slot_assume_capacity().* = .{
        .position = 0,
        .source = placement.entry,
        .target = placement.parent,
    };

    for (0..2 * source.node_count + 2) |_| {
        if (frames.count == base) return null;

        const frame = frames.get_mutable(frames.count - 1);
        const origin = &source.nodes[frame.source];

        if (frame.position == origin.child_count) {
            frames.truncate(frames.count - 1);

            continue;
        }

        const child = origin.children[frame.position];
        const entry = &source.nodes[child];
        const depth = shadow_depth(target, frame.target) + 1;
        const text = shade_string_bytes(entry) + entry.key.count;
        const need: Need = .{ .depth = depth, .nodes = 1, .text = text };

        frame.position += 1;

        if (capacity_error(target, need)) |err| return err;

        const added: Added = .{ .key = entry.key.slice(), .parent = frame.target };
        const created = shadow_node_add(target, added) catch |err| return err;

        shade_copy(target, .{ .destination = created, .origin = entry });
        const pushed: Frame = .{ .position = 0, .source = child, .target = created };

        frames.push_slot_assume_capacity().* = pushed;
    }

    unreachable;
}

const ShadeCopy = struct {
    destination: u32,
    origin: *const Shade,
};

fn shade_copy(shadow: *Shadow, copy: ShadeCopy) void {
    assert(copy.destination < shadow.node_count);
    assert(shadow.nodes[copy.destination].child_count == 0);

    const shade = &shadow.nodes[copy.destination];

    shade.kind = copy.origin.kind;
    shade.form = copy.origin.form;
    shade.scalar = copy.origin.scalar;
    shade.indexed = false;

    shadow.text_used += @intCast(shade_string_bytes(copy.origin));
}

fn shade_string_bytes(shade: *const Shade) u64 {
    if (shade.kind == .string) assert(shade.scalar == .string);

    const result: u64 = switch (shade.scalar) {
        .string => |text| text.count,
        .boolean, .datetime, .float, .integer, .none => 0,
    };

    assert(result <= string_bytes_max);

    return result;
}

fn shadow_reset(shadow: *Shadow, capacity: toml.Capacity) void {
    assert(capacity.node_count_max <= node_count_limit);
    assert(capacity.node_count_max > 0);

    shadow.capacity = capacity;
    shadow.node_count = 1;
    shadow.text_used = 0;

    shadow.nodes[0] = .{
        .alive = true,
        .child_count = 0,
        .children = undefined,
        .form = .header,
        .indexed = false,
        .key = .empty,
        .kind = .table,
        .parent = none,
        .scalar = .none,
    };
}

const Added = struct {
    key: []const u8,
    parent: u32,
};

fn shadow_node_add(shadow: *Shadow, added: Added) !u32 {
    assert(shadow.node_count < shadow.capacity.node_count_max);
    assert(added.parent < shadow.node_count);

    const created = shadow.node_count;
    const parent = &shadow.nodes[added.parent];

    shadow.nodes[created] = .{
        .alive = true,
        .child_count = 0,
        .children = undefined,
        .form = .scalar,
        .indexed = false,
        .key = .empty,
        .kind = .boolean,
        .parent = added.parent,
        .scalar = .none,
    };

    try shadow.nodes[created].key.push_slice(added.key);

    shadow.node_count += 1;
    shadow.text_used += @intCast(added.key.len);

    parent.children[parent.child_count] = created;
    parent.child_count += 1;

    if (parent.kind == .table) {
        if (parent.child_count > scan_member_count_max) parent.indexed = true;
    }

    return created;
}

fn shadow_member_add(state: *State, shadow: *Shadow, operation: Set) !void {
    assert(operation.table < shadow.node_count);
    assert(shadow.nodes[operation.table].kind == .table);

    const indexed_before = shadow.nodes[operation.table].indexed;
    const added: Added = .{ .key = operation.key, .parent = operation.table };
    const created = try shadow_node_add(shadow, added);

    try shade_content_store(shadow, created, &operation.content);

    if (!indexed_before) {
        if (shadow.nodes[operation.table].indexed) state.coverage.getPtr(.index_crossed).* += 1;
    }
}

fn shade_content_store(shadow: *Shadow, node: u32, content: *const Content) !void {
    assert(node < shadow.node_count);
    assert(shadow.nodes[node].child_count == 0);

    const shade = &shadow.nodes[node];

    shade.kind = std.meta.activeTag(content.*);
    shade.indexed = false;
    shade.scalar = .none;
    shade.form = .scalar;

    switch (content.*) {
        .array => |form| shade.form = switch (form) {
            .array_of_tables => .array_of_tables,
            .inline_array => .inline_array,
        },
        .boolean => |value| shade.scalar = .{ .boolean = value },
        .datetime => |value| shade.scalar = .{ .datetime = value },
        .float => |value| shade.scalar = .{ .float = value },
        .integer => |value| shade.scalar = .{ .integer = value },
        .string => |text| {
            shade.scalar = .{ .string = .empty };
            shadow.text_used += @intCast(text.len);

            try shade.scalar.string.push_slice(text);
        },
        .table => |form| shade.form = switch (form) {
            .dotted => .dotted,
            .header => .header,
            .implicit => .implicit,
            .inline_table => .inline_table,
        },
    }
}

fn shadow_reset_in_place(shadow: *Shadow, node: u32, content: *const Content) !void {
    assert(node > 0);
    assert(node < shadow.node_count);

    shadow_children_kill(shadow, node);

    try shade_content_store(shadow, node, content);
}

fn shadow_children_kill(shadow: *Shadow, node: u32) void {
    assert(node < shadow.node_count);
    assert(shadow.nodes[node].alive);

    const shade = &shadow.nodes[node];

    for (shade.children[0..shade.child_count]) |child| shadow_kill(shadow, child);

    shade.child_count = 0;
}

fn shadow_kill(shadow: *Shadow, node: u32) void {
    assert(node > 0);
    assert(node < shadow.node_count);

    const subtree = shadow_subtree_of(shadow, node);

    for (node..shadow.node_count) |position| {
        if (subtree.isSet(position)) shadow.nodes[position].alive = false;
    }

    assert(!shadow.nodes[node].alive);
}

const Subtree = std.StaticBitSet(node_count_limit);

fn shadow_subtree_of(shadow: *const Shadow, node: u32) Subtree {
    assert(node < shadow.node_count);
    assert(shadow.nodes[node].alive);

    var result: Subtree = .empty;

    result.set(node);

    for (node + 1..shadow.node_count) |position| {
        const shade = &shadow.nodes[position];
        if (!shade.alive) continue;
        if (shade.parent < node) continue;

        if (result.isSet(shade.parent)) result.set(position);
    }

    return result;
}

fn shadow_unlink(shadow: *Shadow, node: u32) void {
    assert(node > 0);
    assert(node < shadow.node_count);

    const parent = &shadow.nodes[shadow.nodes[node].parent];
    const children = parent.children[0..parent.child_count];
    const position = std.mem.findScalar(u32, children, node) orelse unreachable;

    std.mem.copyForwards(u32, children[position .. children.len - 1], children[position + 1 ..]);

    parent.child_count -= 1;
}

fn shadow_indexed_within(shadow: *const Shadow, node: u32) bool {
    assert(node < shadow.node_count);
    assert(shadow.nodes[node].alive);

    const subtree = shadow_subtree_of(shadow, node);

    for (node..shadow.node_count) |position| {
        if (!subtree.isSet(position)) continue;
        if (shadow.nodes[position].indexed) return true;
    }

    return false;
}

fn shadow_member(shadow: *const Shadow, table: u32, key: []const u8) u32 {
    assert(key.len <= key_bytes_max);
    assert(shadow.nodes[table].kind == .table);

    const shade = &shadow.nodes[table];

    for (shade.children[0..shade.child_count]) |child| {
        if (std.mem.eql(u8, shadow.nodes[child].key.slice(), key)) return child;
    }

    return none;
}

fn shadow_depth(shadow: *const Shadow, node: u32) u32 {
    assert(node < shadow.node_count);
    assert(shadow.nodes[node].alive);

    var depth: u32 = 0;
    var current = node;

    for (0..shadow.node_count) |_| {
        if (current == 0) return depth;

        current = shadow.nodes[current].parent;
        depth += 1;
    }

    unreachable;
}

fn form_of(record: *const storage_module.Record) Form {
    assert(!record.flags.detached);

    switch (record.kind) {
        .array => return if (record.flags.array_of_tables) .array_of_tables else .inline_array,
        .table => {
            if (record.flags.closed) return .inline_table;
            if (record.flags.explicit) return .header;
            if (record.section != none) return .dotted;
            return .implicit;
        },
        .boolean, .datetime, .float, .integer, .string => return .scalar,
    }
}

fn shadow_compare(shadow: *const Shadow, document: *const toml.Document) !void {
    assert(shadow.node_count > 0);
    assert(document.node_count > 0);

    try std.testing.expectEqual(shadow.node_count, document.node_count);
    try std.testing.expectEqual(shadow.text_used, document.text_used);

    for (shadow.nodes[0..shadow.node_count], 0..) |*shade, position| {
        const record = &document.nodes[position];

        try std.testing.expectEqual(!shade.alive, record.flags.detached);

        if (!shade.alive) continue;

        try shade_compare(shade, document, @intCast(position));
    }
}

fn shade_compare(shade: *const Shade, document: *const toml.Document, index: u32) !void {
    assert(index < document.node_count);
    assert(shade.alive);

    const node: toml.Node = @fromBackingInt(index);
    const record = &document.nodes[index];

    try std.testing.expectEqual(shade.kind, document.kind_of(node));
    try std.testing.expectEqual(shade.form, form_of(record));
    try std.testing.expectEqualStrings(shade.key.slice(), document.key_of(node));
    try std.testing.expectEqual(shade.parent, record.parent);
    try std.testing.expectEqual(@as(?toml.Position, null), document.position_of(node));
    try typed_reads_check(document, node);

    switch (shade.kind) {
        .array => try children_compare(shade, document.items(node)),
        .table => {
            try children_compare(shade, document.entries(node));
            try lookups_compare(shade, document, node);
        },
        .boolean => try std.testing.expectEqual(shade.scalar.boolean, document.boolean_of(node).?),
        .datetime => {
            try std.testing.expectEqual(shade.scalar.datetime, document.datetime_of(node).?);
        },
        .float => {
            const expected: u64 = @bitCast(shade.scalar.float);

            try std.testing.expectEqual(expected, @as(u64, @bitCast(document.float_of(node).?)));
        },
        .integer => try std.testing.expectEqual(shade.scalar.integer, document.integer_of(node).?),
        .string => {
            const expected = shade.scalar.string.slice();

            try std.testing.expectEqualStrings(expected, document.string_of(node).?);
        },
    }
}

fn typed_reads_check(document: *const toml.Document, node: toml.Node) !void {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= document.nodes.len);

    const kind = document.kind_of(node);

    try std.testing.expectEqual(kind == .boolean, document.boolean_of(node) != null);
    try std.testing.expectEqual(kind == .datetime, document.datetime_of(node) != null);
    try std.testing.expectEqual(kind == .float, document.float_of(node) != null);
    try std.testing.expectEqual(kind == .integer, document.integer_of(node) != null);
    try std.testing.expectEqual(kind == .string, document.string_of(node) != null);
}

fn children_compare(shade: *const Shade, iterator: anytype) !void {
    comptime assert(@hasField(@TypeOf(iterator), "remaining"));
    assert(shade.child_count <= node_count_limit);

    var children = iterator;

    try std.testing.expectEqual(shade.child_count, children.remaining);

    for (shade.children[0..shade.child_count]) |child| {
        const next = children.next() orelse return error.TestUnexpectedResult;

        try std.testing.expectEqual(child, @backingInt(next));
    }

    const after = children.next();

    try std.testing.expectEqual(@as(?toml.Node, null), after);
}

fn lookups_compare(shade: *const Shade, document: *const toml.Document, table: toml.Node) !void {
    assert(shade.kind == .table);
    assert(document.kind_of(table) == .table);

    var key: Key = undefined;

    for (0..key_count) |number| {
        key = .empty;

        try key.print("k{d}", .{number});

        const expected = shade_member_of(shade, document, key.slice());

        try std.testing.expectEqual(expected, document.member(table, key.slice()));
    }

    for (keys_special) |special| {
        const expected = shade_member_of(shade, document, special);

        try std.testing.expectEqual(expected, document.member(table, special));
    }
}

fn shade_member_of(
    shade: *const Shade,
    document: *const toml.Document,
    key: []const u8,
) ?toml.Node {
    assert(shade.kind == .table);
    assert(key.len <= key_bytes_max);

    for (shade.children[0..shade.child_count]) |child| {
        const node: toml.Node = @fromBackingInt(child);
        if (std.mem.eql(u8, document.key_of(node), key)) return node;
    }

    return null;
}

fn round_trip(state: *State) !void {
    assert(state.document.node_count > 0);

    const random = state.prng.random();

    const options: toml.Writer.Options = .{
        .layout = if (random.boolean()) .compact else .vertical,
        .strings = std.enums.values(toml.Writer.Strings)[random.uintLessThan(u32, 3)],
        .version = if (random.boolean()) .v1_0 else .v1_1,
    };

    var sink: std.Io.Writer = .fixed(&state.output);

    try state.document.write(&sink, options);

    const written = sink.buffered();
    const storage = state.storage_written.storage();

    state.document_written.parse(storage, written, .{ .version = options.version }) catch |err| {
        std.debug.print("document: the written text was refused with {t}\n{s}\n", .{
            err,
            written,
        });

        return err;
    };

    const documents: fuzz_model.Documents = .{
        .left = &state.document,
        .right = &state.document_written,
    };

    const compare: fuzz_model.Compare = .{ .forms = false, .seconds = options.version == .v1_0 };

    fuzz_model.trees_compare(documents, &state.pairs, compare) catch |err| {
        std.debug.print("document: the written tree differs\n{s}\n", .{written});

        return err;
    };

    state.coverage.getPtr(.round_trip).* += 1;
    written_record(state);
}

fn written_record(state: *State) void {
    assert(state.document.node_count > 0);
    assert(state.coverage.values.len == std.enums.values(Counter).len);

    const document = &state.document;

    for (1..document.node_count) |position| {
        const record = &document.nodes[position];
        if (record.flags.detached) continue;

        const parent = &document.nodes[record.parent];
        const inside = parent.flags.closed;
        const form = form_of(record);

        if (form == .array_of_tables) {
            const fallback = !inside and fallback_is(document, record);

            if (fallback) state.coverage.getPtr(.written_aot_fallback).* += 1;
        }

        if (form == .dotted) {
            if (record.count == 0) state.coverage.getPtr(.written_dotted_empty).* += 1;
        }

        if (form == .implicit) {
            if (inside) state.coverage.getPtr(.written_inline_forced).* += 1;
            if (record.count == 0) state.coverage.getPtr(.written_implicit_header).* += 1;
        }

        if (form == .header) {
            if (inside) state.coverage.getPtr(.written_inline_forced).* += 1;
        }
    }
}

fn fallback_is(document: *const toml.Document, record: *const storage_module.Record) bool {
    assert(record.kind == .array);
    assert(record.flags.array_of_tables);

    if (record.count == 0) return true;

    var element = record.child_first;

    for (0..record.count) |_| {
        if (document.nodes[element].kind != .table) return true;

        element = document.nodes[element].sibling_next;
    }

    return false;
}
