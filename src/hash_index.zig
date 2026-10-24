const std = @import("std");

const document_module = @import("document.zig");
const storage_module = @import("storage.zig");

const assert = std.debug.assert;

const Document = document_module.Document;

const bucket_count_min: u32 = 64;
const hash_multiplier: u64 = 0x9e37_79b9_7f4a_7c15;
const none = storage_module.none;
pub const scan_member_count_max: u32 = 16;
const source_bytes_max = document_module.source_bytes_max;

comptime {
    assert(std.math.isPowerOfTwo(bucket_count_min));
    assert(bucket_count_min >= (scan_member_count_max + 1) * 2);
    assert(hash_multiplier % 2 == 1);
    assert(none == std.math.maxInt(u32));
    assert(scan_member_count_max > 0);
}

pub const Link = struct {
    child: u32,
    parent: u32,
};

pub fn member_find(document: *const Document, parent: u32, key: []const u8) ?u32 {
    assert(parent < document.node_count);
    assert(key.len <= source_bytes_max);
    assert(document.nodes[parent].kind == .table);

    if (document.nodes[parent].flags.indexed) return buckets_probe(document, parent, key);
    return children_scan(document, parent, key);
}

fn children_scan(document: *const Document, parent: u32, key: []const u8) ?u32 {
    assert(!document.nodes[parent].flags.indexed);
    assert(document.nodes[parent].count <= scan_member_count_max);
    assert(key.len <= source_bytes_max);

    var child = document.nodes[parent].child_first;

    for (0..scan_member_count_max) |_| {
        if (child == none) return null;

        const record = &document.nodes[child];

        assert(record.parent == parent);

        if (record.key.len == key.len) {
            if (std.mem.eql(u8, record.key, key)) return child;
        }

        child = record.sibling_next;
    }

    assert(child == none);

    return null;
}

fn buckets_probe(document: *const Document, parent: u32, key: []const u8) ?u32 {
    assert(document.nodes[parent].flags.indexed);
    assert(std.math.isPowerOfTwo(document.bucket_count));
    assert(key.len <= source_bytes_max);

    const mask = document.bucket_count - 1;
    var bucket = bucket_first(document, parent, key);

    for (0..document.bucket_count) |_| {
        const candidate = document.buckets[bucket];
        if (candidate == none) return null;

        const record = &document.nodes[candidate];

        if (record.parent == parent) {
            if (std.mem.eql(u8, record.key, key)) return candidate;
        }

        bucket = (bucket + 1) & mask;
    }

    return null;
}

pub fn insert(document: *Document, node: u32) void {
    assert(node < document.node_count);
    assert(document.node_count * 2 <= document.buckets.len);

    const parent = document.nodes[node].parent;
    const container = &document.nodes[parent];

    assert(container.kind == .table);
    assert(container.child_last == node);

    if (container.flags.indexed) {
        if ((document.indexed_count + 1) * 2 > document.bucket_count) {
            return buckets_rebuild(document, document.indexed_count + 1);
        }

        return bucket_insert(document, node);
    }

    if (container.count <= scan_member_count_max) return;

    const expected = document.indexed_count + container.count;

    container.flags.indexed = true;
    container.indexed_next = document.indexed_first;
    document.indexed_first = parent;

    if (expected * 2 > document.bucket_count) {
        buckets_rebuild(document, expected);
    } else {
        members_insert(document, parent);
    }

    assert(document.indexed_count == expected);
}

fn buckets_rebuild(document: *Document, expected: u32) void {
    assert(expected > scan_member_count_max);
    assert(expected * 2 <= document.buckets.len);

    const wanted = std.math.ceilPowerOfTwoAssert(u32, @max(bucket_count_min, expected * 2));
    const capacity: u32 = @intCast(document.buckets.len);
    const bucket_count = @min(wanted, capacity);

    @memset(document.buckets[0..bucket_count], none);

    document.bucket_count = bucket_count;
    document.indexed_count = 0;

    var table = document.indexed_first;

    for (0..document.node_count) |_| {
        if (table == none) break;

        members_insert(document, table);
        table = document.nodes[table].indexed_next;
    }

    assert(table == none);
    assert(document.indexed_count == expected);
}

fn members_insert(document: *Document, table: u32) void {
    assert(table < document.node_count);
    assert(document.nodes[table].flags.indexed);

    var child = document.nodes[table].child_first;

    for (0..document.nodes[table].count) |_| {
        bucket_insert(document, child);
        child = document.nodes[child].sibling_next;
    }

    assert(child == none);
}

fn bucket_insert(document: *Document, node: u32) void {
    assert(node < document.node_count);
    assert(document.nodes[document.nodes[node].parent].flags.indexed);
    assert((document.indexed_count + 1) * 2 <= document.bucket_count);

    const record = &document.nodes[node];
    const mask = document.bucket_count - 1;
    var bucket = bucket_first(document, record.parent, record.key);

    for (0..document.bucket_count) |_| {
        if (document.buckets[bucket] == none) {
            document.buckets[bucket] = node;
            document.indexed_count += 1;

            return;
        }

        bucket = (bucket + 1) & mask;
    }

    unreachable;
}

pub fn remove(document: *Document, node: u32) void {
    assert(node < document.node_count);
    assert(document.indexed_count > 0);
    assert(document.nodes[document.nodes[node].parent].flags.indexed);
    assert(std.math.isPowerOfTwo(document.bucket_count));

    const mask = document.bucket_count - 1;
    var hole = bucket_holding(document, node);
    var probe = hole;

    for (0..document.bucket_count) |_| {
        probe = (probe + 1) & mask;

        const candidate = document.buckets[probe];
        if (candidate == none) break;

        const entry = &document.nodes[candidate];
        const home = bucket_first(document, entry.parent, entry.key);

        if ((probe -% home) & mask >= (probe -% hole) & mask) {
            document.buckets[hole] = candidate;
            hole = probe;
        }
    }

    document.buckets[hole] = none;
    document.indexed_count -= 1;

    assert(document.buckets[hole] == none);
}

fn bucket_holding(document: *const Document, node: u32) u32 {
    assert(node < document.node_count);
    assert(std.math.isPowerOfTwo(document.bucket_count));

    const record = &document.nodes[node];
    const mask = document.bucket_count - 1;
    var bucket = bucket_first(document, record.parent, record.key);

    for (0..document.bucket_count) |_| {
        if (document.buckets[bucket] == node) return bucket;

        assert(document.buckets[bucket] != none);

        bucket = (bucket + 1) & mask;
    }

    unreachable;
}

pub fn rebuild(document: *Document) void {
    assert(document.node_count <= document.nodes.len);
    assert(std.math.isPowerOfTwo(document.buckets.len));

    const expected = indexed_list_filter(document);
    const wanted = std.math.ceilPowerOfTwoAssert(u32, @max(bucket_count_min, expected * 2));
    const capacity: u32 = @intCast(document.buckets.len);
    const bucket_count = @min(wanted, capacity);

    assert(expected * 2 <= bucket_count);

    @memset(document.buckets[0..bucket_count], none);

    document.bucket_count = bucket_count;
    document.indexed_count = 0;

    var table = document.indexed_first;

    for (0..document.node_count) |_| {
        if (table == none) break;

        members_insert(document, table);
        table = document.nodes[table].indexed_next;
    }

    assert(table == none);
    assert(document.indexed_count == expected);
}

fn indexed_list_filter(document: *Document) u32 {
    assert(document.node_count <= document.nodes.len);
    assert(document.indexed_count <= document.node_count);

    var expected: u32 = 0;
    var kept_last: u32 = none;
    var table = document.indexed_first;

    document.indexed_first = none;

    for (0..document.node_count) |_| {
        if (table == none) break;

        const record = &document.nodes[table];
        const next = record.indexed_next;

        if (indexed_kept(record)) {
            if (kept_last == none) {
                document.indexed_first = table;
            } else {
                document.nodes[kept_last].indexed_next = table;
            }

            kept_last = table;
            expected += record.count;
        }

        table = next;
    }

    assert(table == none);

    if (kept_last != none) document.nodes[kept_last].indexed_next = none;

    return expected;
}

fn indexed_kept(record: *const storage_module.Record) bool {
    assert(record.kind == .table or !record.flags.indexed);

    if (!record.flags.indexed) return false;
    return !record.flags.detached;
}

pub fn child_link(document: *Document, link: Link) void {
    assert(link.parent < link.child);
    assert(link.child < document.node_count);

    const container = &document.nodes[link.parent];

    if (container.child_last == none) {
        container.child_first = link.child;
    } else {
        document.nodes[container.child_last].sibling_next = link.child;
    }

    container.child_last = link.child;
    container.count += 1;

    assert(container.count > 0);
}

fn bucket_first(document: *const Document, parent: u32, key: []const u8) u32 {
    assert(parent < document.node_count);
    assert(key.len <= source_bytes_max);

    const seed = document.hash_seed +% @as(u64, parent) *% hash_multiplier;
    const hash = std.hash.Wyhash.hash(seed, key);
    const result: u32 = @intCast(hash & (document.bucket_count - 1));

    assert(result < document.bucket_count);

    return result;
}

const testing = std.testing;

const TestStorage = storage_module.StorageType(.{
    .line_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const TestKey = struct {
    buffer: [8]u8,
    length: u32,

    fn text(test_key: *const TestKey) []const u8 {
        assert(test_key.length <= test_key.buffer.len);
        assert(test_key.length > 0);

        return test_key.buffer[0..test_key.length];
    }
};

fn test_key_of(prefix: u8, number: u32) !TestKey {
    assert(prefix >= 'a');
    assert(number < 10_000);

    var result: TestKey = .{ .buffer = undefined, .length = 0 };
    const written = try std.mem.print(&result.buffer, "{c}{d}", .{ prefix, number });

    result.length = @intCast(written.len);

    return result;
}

fn test_chains_check(document: *const Document) !void {
    assert(std.math.isPowerOfTwo(document.bucket_count));
    assert(document.bucket_count <= document.buckets.len);

    const mask = document.bucket_count - 1;
    var occupied: u32 = 0;

    for (document.buckets[0..document.bucket_count], 0..) |entry, position| {
        if (entry == none) continue;

        occupied += 1;

        const record = &document.nodes[entry];
        var bucket = bucket_first(document, record.parent, record.key);

        for (0..document.bucket_count) |_| {
            if (bucket == position) break;

            try testing.expect(document.buckets[bucket] != none);

            bucket = (bucket + 1) & mask;
        }
    }

    try testing.expectEqual(document.indexed_count, occupied);
}

fn test_lookups_check(document: *const Document, table: u32) !void {
    assert(table < document.node_count);
    assert(document.nodes[table].kind == .table);

    var child = document.nodes[table].child_first;

    for (0..document.nodes[table].count) |_| {
        const found = member_find(document, table, document.nodes[child].key);

        try testing.expectEqual(@as(?u32, child), found);

        child = document.nodes[child].sibling_next;
    }

    try testing.expectEqual(none, child);
}

test "backward-shift deletion across the wraparound keeps every other key reachable" {
    const storage = try testing.allocator.create(TestStorage);
    defer testing.allocator.destroy(storage);

    var document: Document = undefined;

    document.init(storage.storage());

    const root = document.root();

    for (0..scan_member_count_max + 1) |number| {
        const key = try test_key_of('b', @intCast(number));

        _ = try document.set(root, key.text(), .{ .integer = @intCast(number) });
    }

    try testing.expect(document.nodes[0].flags.indexed);

    var colliding: [6]document_module.Node = undefined;
    var colliding_count: u32 = 0;

    for (0..10_000) |number| {
        if (colliding_count == colliding.len) break;

        const key = try test_key_of('w', @intCast(number));
        if (bucket_first(&document, 0, key.text()) != document.bucket_count - 1) continue;

        colliding[colliding_count] = try document.set(root, key.text(), .{ .boolean = true });
        colliding_count += 1;
    }

    try testing.expectEqual(@as(u32, colliding.len), colliding_count);
    try testing.expectEqual(@as(u32, 64), document.bucket_count);

    const half = @divExact(document.bucket_count, 2);

    for (colliding[1..]) |node| {
        const bucket = bucket_holding(&document, @backingInt(node));

        try testing.expect(bucket < half);
    }

    try test_chains_check(&document);

    for ([_]u32{ 1, 0, 4, 2, 5, 3 }) |order| {
        const node = colliding[order];
        const key = document.key_of(node);

        document.remove(node);

        try testing.expectEqual(@as(?u32, null), member_find(&document, 0, key));
        try test_chains_check(&document);
        try test_lookups_check(&document, 0);
    }

    try testing.expectEqual(@as(u32, scan_member_count_max + 1), document.indexed_count);
}

test "a rebuild after a detach keeps only the indexed tables still attached" {
    const storage = try testing.allocator.create(TestStorage);
    defer testing.allocator.destroy(storage);

    var document: Document = undefined;
    var source: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&source);

    for ([_][]const u8{ "", "t", "t.u" }) |header| {
        if (header.len > 0) try writer.print("[{s}]\n", .{header});

        for (0..20) |number| try writer.print("k{d} = {d}\n", .{ number, number });
    }

    try writer.writeAll("[v]\nx = 1\n");
    try document.parse(storage.storage(), writer.buffered(), .{ .version = .v1_1 });

    const root = document.root();
    const outer = document.member(root, "t").?;
    const inner = document.member(outer, "u").?;

    try testing.expect(document.nodes[@backingInt(outer)].flags.indexed);
    try testing.expect(document.nodes[@backingInt(inner)].flags.indexed);
    try testing.expectEqual(@as(u32, 22 + 21 + 20), document.indexed_count);

    document.remove(outer);

    try testing.expectEqual(@as(u32, 21), document.indexed_count);
    try testing.expectEqual(@as(u32, 0), document.indexed_first);
    try testing.expectEqual(none, document.nodes[0].indexed_next);
    try test_chains_check(&document);
    try test_lookups_check(&document, 0);
    try testing.expectEqual(@as(?document_module.Node, null), document.member(root, "t"));

    _ = try document.set(root, "v", .{ .string = "replaced" });

    try testing.expectEqual(@as(u32, 21), document.indexed_count);
    try testing.expectEqualStrings("replaced", document.string_of(document.member(root, "v").?).?);
    try test_lookups_check(&document, 0);
}
