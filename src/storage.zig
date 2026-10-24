const std = @import("std");

const datetime_module = @import("datetime.zig");
const document_module = @import("document.zig");
const scalar = @import("scalar.zig");

const assert = std.debug.assert;

const Datetime = datetime_module.Datetime;
const Kind = document_module.Kind;

pub const hash_seed_default: u64 = 0x6f6c_6d74_6c75_6f74;
pub const node_count_limit: u32 = 1 << 30;
pub const none: u32 = std.math.maxInt(u32);

comptime {
    assert(node_count_limit * 2 < none);
    assert(scalar.source_bytes_max < none);
    assert(@sizeOf(Flags) == 1);
    assert(@sizeOf(Line) == 12);
    assert(@sizeOf(Record) == if (std.debug.runtime_safety) 72 else 64);
}

pub const Capacity = struct {
    line_count_max: ?u32,
    node_count_max: u32,
    text_bytes_max: u32,
};

pub const Flags = packed struct(u8) {
    array_of_tables: bool,
    closed: bool,
    detached: bool,
    edited: bool,
    explicit: bool,
    indexed: bool,
    owner: Owner,
};

pub const Line = struct {
    end: u32,
    node: u32,
    start: u32,
};

pub const Owner = enum(u2) {
    header,
    none,
    pair,
};

pub const Payload = union {
    boolean: bool,
    datetime: Datetime,
    float: f64,
    integer: i64,
    none: void,
    string: []const u8,
};

pub const Record = struct {
    child_first: u32,
    child_last: u32,
    count: u32,
    flags: Flags,
    indexed_next: u32,
    key: []const u8,
    kind: Kind,
    parent: u32,
    payload: Payload,
    section: u32,
    sibling_next: u32,
};

pub const Storage = struct {
    buckets: []u32,
    hash_seed: u64,
    lines: []Line,
    nodes: []Record,
    text: []u8,

    pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Storage {
        assert(capacity.node_count_max > 0);
        assert(capacity.node_count_max <= node_count_limit);
        assert(capacity.text_bytes_max <= scalar.source_bytes_max);
        assert((capacity.line_count_max orelse 0) <= scalar.source_bytes_max);

        const buckets = try gpa.alloc(u32, bucket_count_of(capacity));
        errdefer gpa.free(buckets);

        const lines = try gpa.alloc(Line, capacity.line_count_max orelse 0);
        errdefer gpa.free(lines);

        const nodes = try gpa.alloc(Record, capacity.node_count_max);
        errdefer gpa.free(nodes);

        const text = try gpa.alloc(u8, capacity.text_bytes_max);

        return .{
            .buckets = buckets,
            .hash_seed = hash_seed_default,
            .lines = lines,
            .nodes = nodes,
            .text = text,
        };
    }

    pub fn deinit(storage: *Storage, gpa: std.mem.Allocator) void {
        assert(std.math.isPowerOfTwo(storage.buckets.len));
        assert(storage.buckets.len >= storage.nodes.len * 2);

        gpa.free(storage.text);
        gpa.free(storage.nodes);
        gpa.free(storage.lines);
        gpa.free(storage.buckets);

        storage.* = undefined;
    }
};

pub fn StorageType(comptime capacity: Capacity) type {
    comptime assert(capacity.node_count_max > 0);
    comptime assert(capacity.node_count_max <= node_count_limit);
    comptime assert(capacity.text_bytes_max <= scalar.source_bytes_max);
    comptime assert(bucket_count_of(capacity) >= capacity.node_count_max * 2);
    comptime assert(std.math.isPowerOfTwo(bucket_count_of(capacity)));
    comptime assert((capacity.line_count_max orelse 0) <= scalar.source_bytes_max);

    return struct {
        buckets: [bucket_count_of(capacity)]u32,
        lines: [capacity.line_count_max orelse 0]Line,
        nodes: [capacity.node_count_max]Record,
        text: [capacity.text_bytes_max]u8,

        pub fn storage(fixed: *@This()) Storage {
            return .{
                .buckets = &fixed.buckets,
                .hash_seed = hash_seed_default,
                .lines = &fixed.lines,
                .nodes = &fixed.nodes,
                .text = &fixed.text,
            };
        }
    };
}

fn bucket_count_of(capacity: Capacity) u32 {
    assert(capacity.node_count_max > 0);
    assert(capacity.node_count_max <= node_count_limit);

    const result = std.math.ceilPowerOfTwoAssert(u32, capacity.node_count_max * 2);

    assert(result >= capacity.node_count_max * 2);

    return result;
}

test StorageType {
    const Fixed = StorageType(.{
        .line_count_max = null,
        .node_count_max = 64,
        .text_bytes_max = 1024,
    });

    const fixed = try std.testing.allocator.create(Fixed);
    defer std.testing.allocator.destroy(fixed);

    var document: document_module.Document = undefined;

    try document.parse(fixed.storage(), "name = \"toml\"\n", .{});

    const name = document.member(document.root(), "name") orelse return error.NameMissing;

    try std.testing.expectEqualStrings("toml", document.string_of(name).?);
}
