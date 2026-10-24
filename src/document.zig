const std = @import("std");

const datetime_module = @import("datetime.zig");
const edit = @import("edit.zig");
const hash_index = @import("hash_index.zig");
const parser = @import("parser.zig");
const scalar = @import("scalar.zig");
const serializer = @import("serializer.zig");
const splicer = @import("splicer.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Capacity = storage_module.Capacity;
const Datetime = datetime_module.Datetime;
const Line = storage_module.Line;
const Record = storage_module.Record;
const Storage = storage_module.Storage;
const StorageType = storage_module.StorageType;

pub const depth_max: u32 = 128;
pub const key_segment_count_max: u32 = 128;
pub const source_bytes_max: u32 = scalar.source_bytes_max;

const index_digits_max: u32 = 10;
const none = storage_module.none;
const node_count_limit = storage_module.node_count_limit;

comptime {
    assert(depth_max >= 16);
    assert(key_segment_count_max >= 16);
    assert(source_bytes_max < none);
    assert(std.math.log10_int(@as(u64, std.math.maxInt(u32))) + 1 == index_digits_max);
}

pub const CapacityError = error{
    DepthExceeded,
    LinesExhausted,
    NodesExhausted,
    TextExhausted,
};

pub const SyntaxError = error{
    ArrayInvalid,
    ArrayUnterminated,
    CharacterInvalid,
    CommentInvalid,
    DatetimeInvalid,
    EqualsMissing,
    EscapeInvalid,
    ExpressionInvalid,
    InlineTableInvalid,
    InlineTableUnterminated,
    KeyDuplicate,
    KeyInvalid,
    NewlineInvalid,
    NumberInvalid,
    StringInvalid,
    StringUnterminated,
    TableInvalid,
    TableRedefined,
    TableUnterminated,
    Utf8Invalid,
    ValueInvalid,
    ValueMissing,
};

pub const Node = enum(u32) { _ };

pub const Kind = enum {
    array,
    boolean,
    datetime,
    float,
    integer,
    string,
    table,
};

pub const Value = union(enum) {
    array: Node,
    boolean: bool,
    datetime: Datetime,
    float: f64,
    integer: i64,
    string: []const u8,
    table: Node,
};

pub const Version = enum {
    v1_0,
    v1_1,
};

pub const Position = struct {
    column: u32,
    line: u32,
    offset: u32,
};

pub const position_none: Position = .{ .column = 0, .line = 0, .offset = 0 };

pub const Entries = struct {
    cursor: u32,
    document: *const Document,
    remaining: u32,

    pub fn next(entries: *Entries) ?Node {
        assert(entries.remaining <= entries.document.node_count);
        assert((entries.remaining == 0) == (entries.cursor == none));

        if (entries.remaining == 0) return null;

        const result = entries.cursor;

        assert(result < entries.document.node_count);

        entries.cursor = entries.document.nodes[result].sibling_next;
        entries.remaining -= 1;

        return @fromBackingInt(result);
    }
};

pub const Items = struct {
    cursor: u32,
    document: *const Document,
    remaining: u32,

    pub fn next(items: *Items) ?Node {
        assert(items.remaining <= items.document.node_count);
        assert((items.remaining == 0) == (items.cursor == none));

        if (items.remaining == 0) return null;

        const result = items.cursor;

        assert(result < items.document.node_count);

        items.cursor = items.document.nodes[result].sibling_next;
        items.remaining -= 1;

        return @fromBackingInt(result);
    }
};

const Step = struct {
    cursor: u32,
    node: Node,
};

pub const Document = struct {
    bucket_count: u32,
    buckets: []u32,
    diagnostic: Position,
    hash_seed: u64,
    indexed_count: u32,
    indexed_first: u32,
    line_count: u32,
    lines: []Line,
    node_count: u32,
    node_count_parsed: u32,
    nodes: []Record,
    source: []const u8,
    text: []u8,
    text_used: u32,

    pub const ArrayForm = edit.ArrayForm;
    pub const Content = edit.Content;
    pub const EditError = edit.EditError;
    pub const Error = CapacityError || SyntaxError;
    pub const Merge = edit.Merge;

    pub const Options = struct {
        version: Version = .v1_1,
    };

    pub const TableForm = edit.TableForm;

    pub const append = edit.append;
    pub const init = edit.init;
    pub const merge = edit.merge;
    pub const remove = edit.remove;
    pub const set = edit.set;

    pub fn write(
        document: *const Document,
        sink: *std.Io.Writer,
        options: writer_module.Writer.Options,
    ) std.Io.Writer.Error!void {
        assert(document.node_count > 0);
        assert(document.line_count <= document.lines.len);
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);

        if (document.lines.len > 0) return splicer.write(document, sink, options);
        return serializer.write(document, sink, options);
    }

    pub fn parse(
        document: *Document,
        storage: Storage,
        source: []const u8,
        options: Options,
    ) Document.Error!void {
        assert(source.len <= source_bytes_max);
        assert(storage.nodes.len <= node_count_limit);
        assert(disjoint(&storage, source));
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);

        try parser.parse(document, storage, source, options);

        assert(document.node_count > 0);
        assert(document.diagnostic.line == 0);
    }

    pub fn root(document: *const Document) Node {
        assert(document.node_count > 0);
        assert(document.nodes[0].kind == .table);

        return @fromBackingInt(0);
    }

    pub fn kind_of(document: *const Document, node: Node) Kind {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        return record.kind;
    }

    pub fn key_of(document: *const Document, node: Node) []const u8 {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        return record.key;
    }

    pub fn position_of(document: *const Document, node: Node) ?Position {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        if (@backingInt(node) >= document.node_count_parsed) return null;

        const offset = key_offset_of(document, record) orelse return null;
        const position = scalar.position_of(document.source, offset);

        assert(position.line >= 1);
        assert(position.column >= 1);

        return position;
    }

    pub fn count_of(document: *const Document, collection: Node) u32 {
        assert(@backingInt(collection) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(collection)];

        assert(!record.flags.detached);

        const result = switch (record.kind) {
            .array, .table => record.count,
            .boolean, .datetime, .float, .integer, .string => 0,
        };

        assert(result < document.node_count);

        return result;
    }

    pub fn value_of(document: *const Document, node: Node) Value {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        return switch (record.kind) {
            .array => .{ .array = node },
            .boolean => .{ .boolean = record.payload.boolean },
            .datetime => .{ .datetime = record.payload.datetime },
            .float => .{ .float = record.payload.float },
            .integer => .{ .integer = record.payload.integer },
            .string => .{ .string = record.payload.string },
            .table => .{ .table = node },
        };
    }

    pub fn boolean_of(document: *const Document, node: Node) ?bool {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        if (record.kind != .boolean) return null;
        return record.payload.boolean;
    }

    pub fn datetime_of(document: *const Document, node: Node) ?Datetime {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        if (record.kind != .datetime) return null;
        return record.payload.datetime;
    }

    pub fn float_of(document: *const Document, node: Node) ?f64 {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        if (record.kind != .float) return null;
        return record.payload.float;
    }

    pub fn integer_of(document: *const Document, node: Node) ?i64 {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        if (record.kind != .integer) return null;
        return record.payload.integer;
    }

    pub fn string_of(document: *const Document, node: Node) ?[]const u8 {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(node)];

        assert(!record.flags.detached);

        if (record.kind != .string) return null;
        return record.payload.string;
    }

    pub fn entries(document: *const Document, table: Node) Entries {
        assert(@backingInt(table) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(table)];

        assert(!record.flags.detached);

        const count = if (record.kind == .table) record.count else 0;
        const cursor = if (count == 0) none else record.child_first;

        return .{ .cursor = cursor, .document = document, .remaining = count };
    }

    pub fn items(document: *const Document, array: Node) Items {
        assert(@backingInt(array) < document.node_count);
        assert(document.node_count <= document.nodes.len);

        const record = &document.nodes[@backingInt(array)];

        assert(!record.flags.detached);

        const count = if (record.kind == .array) record.count else 0;
        const cursor = if (count == 0) none else record.child_first;

        return .{ .cursor = cursor, .document = document, .remaining = count };
    }

    pub fn member(document: *const Document, table: Node, key: []const u8) ?Node {
        assert(@backingInt(table) < document.node_count);
        assert(key.len <= source_bytes_max);

        const record = &document.nodes[@backingInt(table)];

        assert(!record.flags.detached);

        if (record.kind != .table) return null;

        const found = hash_index.member_find(document, @backingInt(table), key) orelse return null;
        return @fromBackingInt(found);
    }

    pub fn item(document: *const Document, array: Node, index: u32) ?Node {
        assert(@backingInt(array) < document.node_count);
        assert(@min(index, document.count_of(array)) < document.node_count);

        const record = &document.nodes[@backingInt(array)];

        assert(!record.flags.detached);

        if (record.kind != .array) return null;
        if (index >= record.count) return null;

        var cursor = record.child_first;

        for (0..index) |_| cursor = document.nodes[cursor].sibling_next;

        assert(cursor < document.node_count);
        assert(document.nodes[cursor].parent == @backingInt(array));

        return @fromBackingInt(cursor);
    }

    pub fn path_find(document: *const Document, start: Node, segments: []const []const u8) ?Node {
        assert(@backingInt(start) < document.node_count);
        assert(segments.len <= source_bytes_max);
        assert(!document.nodes[@backingInt(start)].flags.detached);

        var node = start;

        for (segments) |segment| {
            node = document.segment_step(node, segment) orelse return null;
        }

        return node;
    }

    fn segment_step(document: *const Document, node: Node, segment: []const u8) ?Node {
        assert(@backingInt(node) < document.node_count);
        assert(segment.len <= source_bytes_max);

        return switch (document.kind_of(node)) {
            .array => document.item(node, index_of(segment) orelse return null),
            .table => document.member(node, segment),
            .boolean, .datetime, .float, .integer, .string => null,
        };
    }

    pub fn find(document: *const Document, path: []const u8) ?Value {
        assert(document.node_count > 0);
        assert(path.len <= source_bytes_max);

        var step: Step = .{ .cursor = 0, .node = document.root() };

        for (0..path.len + 1) |_| {
            const key_end = std.mem.findAnyPos(u8, path, step.cursor, ".[") orelse path.len;
            const key = path[step.cursor..key_end];

            if (key.len == 0) {
                if (std.mem.startsWith(u8, path[key_end..], "[")) return null;
            }

            step.node = document.member(step.node, key) orelse return null;
            step.cursor = @intCast(key_end);
            step = document.find_indices(step, path) orelse return null;

            if (step.cursor == path.len) return document.value_of(step.node);
            if (path[step.cursor] != '.') return null;

            step.cursor += 1;
        }

        unreachable;
    }

    fn find_indices(document: *const Document, start: Step, path: []const u8) ?Step {
        assert(start.cursor <= path.len);
        assert(path.len <= source_bytes_max);

        var step = start;

        for (start.cursor..path.len) |_| {
            if (step.cursor == path.len) break;
            if (path[step.cursor] != '[') break;

            const close = std.mem.findScalarPos(u8, path, step.cursor, ']') orelse return null;
            const index = index_of(path[step.cursor + 1 .. close]) orelse return null;

            step.node = document.item(step.node, index) orelse return null;
            step.cursor = @intCast(close + 1);
        }

        assert(step.cursor <= path.len);

        return step;
    }
};

pub fn DocumentType(comptime capacity: Capacity) type {
    comptime assert(capacity.node_count_max > 0);
    comptime assert(capacity.text_bytes_max > 0);

    return struct {
        document: Document,
        storage: StorageType(capacity),

        const Fixed = @This();

        pub fn parse(
            fixed: *Fixed,
            source: []const u8,
            options: Document.Options,
        ) Document.Error!void {
            assert(source.len <= source_bytes_max);
            assert(disjoint(&fixed.storage.storage(), source));
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);

            return fixed.document.parse(fixed.storage.storage(), source, options);
        }

        pub fn write(
            fixed: *const Fixed,
            sink: *std.Io.Writer,
            options: writer_module.Writer.Options,
        ) std.Io.Writer.Error!void {
            assert(fixed.document.node_count > 0);
            assert(sink.end <= sink.buffer.len);
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);

            return fixed.document.write(sink, options);
        }

        pub fn diagnostic(fixed: *const Fixed) Position {
            return fixed.document.diagnostic;
        }

        pub fn root(fixed: *const Fixed) Node {
            assert(fixed.document.node_count > 0);

            return fixed.document.root();
        }

        pub fn kind_of(fixed: *const Fixed, node: Node) Kind {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.kind_of(node);
        }

        pub fn key_of(fixed: *const Fixed, node: Node) []const u8 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.key_of(node);
        }

        pub fn position_of(fixed: *const Fixed, node: Node) ?Position {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.position_of(node);
        }

        pub fn count_of(fixed: *const Fixed, collection: Node) u32 {
            assert(@backingInt(collection) < fixed.document.node_count);

            return fixed.document.count_of(collection);
        }

        pub fn value_of(fixed: *const Fixed, node: Node) Value {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.value_of(node);
        }

        pub fn boolean_of(fixed: *const Fixed, node: Node) ?bool {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.boolean_of(node);
        }

        pub fn datetime_of(fixed: *const Fixed, node: Node) ?Datetime {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.datetime_of(node);
        }

        pub fn float_of(fixed: *const Fixed, node: Node) ?f64 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.float_of(node);
        }

        pub fn integer_of(fixed: *const Fixed, node: Node) ?i64 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.integer_of(node);
        }

        pub fn string_of(fixed: *const Fixed, node: Node) ?[]const u8 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.string_of(node);
        }

        pub fn entries(fixed: *const Fixed, table: Node) Entries {
            assert(@backingInt(table) < fixed.document.node_count);

            return fixed.document.entries(table);
        }

        pub fn items(fixed: *const Fixed, array: Node) Items {
            assert(@backingInt(array) < fixed.document.node_count);

            return fixed.document.items(array);
        }

        pub fn member(fixed: *const Fixed, table: Node, key: []const u8) ?Node {
            assert(@backingInt(table) < fixed.document.node_count);
            assert(key.len <= source_bytes_max);

            return fixed.document.member(table, key);
        }

        pub fn item(fixed: *const Fixed, array: Node, index: u32) ?Node {
            assert(@backingInt(array) < fixed.document.node_count);
            assert(@min(index, fixed.document.count_of(array)) < fixed.document.node_count);

            return fixed.document.item(array, index);
        }

        pub fn path_find(fixed: *const Fixed, start: Node, segments: []const []const u8) ?Node {
            assert(@backingInt(start) < fixed.document.node_count);
            assert(segments.len <= source_bytes_max);

            return fixed.document.path_find(start, segments);
        }

        pub fn find(fixed: *const Fixed, path: []const u8) ?Value {
            assert(fixed.document.node_count > 0);
            assert(path.len <= source_bytes_max);

            return fixed.document.find(path);
        }
    };
}

pub fn key_offset_of(document: *const Document, record: *const Record) ?u32 {
    assert(record.key.len <= source_bytes_max);
    assert(document.source.len <= source_bytes_max);

    const source_start = @intFromPtr(document.source.ptr);
    const key_start = @intFromPtr(record.key.ptr);
    if (key_start < source_start) return null;
    if (key_start + record.key.len > source_start + document.source.len) return null;

    const offset: u32 = @intCast(key_start - source_start);
    const result = offset - quote_count_before(document, record, offset);

    assert(result <= offset);
    assert(result <= document.source.len);

    return result;
}

fn quote_count_before(document: *const Document, record: *const Record, offset: u32) u32 {
    assert(offset <= document.source.len);
    assert(record.key.len <= document.source.len - offset);

    if (offset == 0) return 0;
    if (record.parent == none) return 0;
    if (document.nodes[record.parent].kind != .table) return 0;

    const result: u32 = switch (document.source[offset - 1]) {
        '"', '\'' => 1,
        else => 0,
    };

    assert(result <= 1);

    return result;
}

fn disjoint(storage: *const Storage, source: []const u8) bool {
    assert(source.len <= source_bytes_max);
    assert(storage.text.len <= source_bytes_max);

    const source_start = @intFromPtr(source.ptr);
    const text_start = @intFromPtr(storage.text.ptr);

    if (source.len == 0) return true;
    if (storage.text.len == 0) return true;
    if (source_start + source.len <= text_start) return true;
    return text_start + storage.text.len <= source_start;
}

fn index_of(text: []const u8) ?u32 {
    assert(text.len <= source_bytes_max);

    if (text.len == 0) return null;
    if (text.len > index_digits_max) return null;
    if (text[0] == '0') return if (text.len == 1) 0 else null;

    var result: u64 = 0;

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;

        result = result * 10 + (byte - '0');
    }

    if (result > std.math.maxInt(u32)) return null;

    assert(result > 0);

    return @intCast(result);
}

const testing = std.testing;

test DocumentType {
    const Config = DocumentType(.{
        .line_count_max = null,
        .node_count_max = 64,
        .text_bytes_max = 1024,
    });

    const config = try testing.allocator.create(Config);
    defer testing.allocator.destroy(config);

    try config.parse("[server]\nhost = \"localhost\"\nports = [8080, 8443]\n", .{});

    const host = config.find("server.host") orelse return error.HostMissing;
    const port = config.find("server.ports[1]") orelse return error.PortMissing;

    try testing.expectEqualStrings("localhost", host.string);
    try testing.expectEqual(@as(i64, 8443), port.integer);

    const server = config.path_find(config.root(), &.{"server"}) orelse return error.ServerMissing;
    const first = config.path_find(server, &.{ "ports", "0" }) orelse return error.PortMissing;
    const ports = config.member(server, "ports") orelse return error.PortsMissing;
    const position = config.position_of(server) orelse return error.PositionMissing;

    try testing.expectEqual(@as(i64, 8080), config.integer_of(first).?);
    try testing.expectEqual(@as(?Node, first), config.item(ports, 0));
    try testing.expectEqual(@as(?Node, null), config.item(ports, 2));
    try testing.expectEqual(@as(?i64, null), config.integer_of(ports));
    try testing.expectEqual(Position{ .column = 2, .line = 1, .offset = 1 }, position);

    try testing.expectError(error.KeyDuplicate, config.parse("a = 1\na = 2\n", .{}));
    try testing.expectEqual(@as(u32, 2), config.diagnostic().line);

    const strict = config.parse("t = { a = 1, }\n", .{ .version = .v1_0 });

    try testing.expectError(error.InlineTableInvalid, strict);
    try config.parse("t = { a = 1, }\n", .{ .version = .v1_1 });
}

test "a document type that keeps lines writes its source back and edits it in place" {
    const Kept = DocumentType(.{
        .line_count_max = 16,
        .node_count_max = 64,
        .text_bytes_max = 1024,
    });

    const kept = try testing.allocator.create(Kept);
    defer testing.allocator.destroy(kept);

    const source = "# server\r\n[server]\r\nport = 0x1F90 # hex\r\ntags = [ 'a' ]\r\n";

    try kept.parse(source, .{ .version = .v1_1 });

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try kept.write(&sink, .{ .version = .v1_1 });
    try testing.expectEqualStrings(source, sink.buffered());

    const kept_server = kept.member(kept.root(), "server") orelse return error.ServerMissing;
    const tags = kept.member(kept_server, "tags") orelse return error.TagsMissing;

    _ = try kept.document.set(kept_server, "port", .{ .integer = 9090 });
    _ = try kept.document.append(tags, .{ .string = "b" });

    sink = .fixed(&buffer);

    try kept.write(&sink, .{ .version = .v1_1 });

    const edited = "# server\r\n[server]\r\nport = 9090 # hex\r\ntags = [ 'a', \"b\" ]\r\n";

    try testing.expectEqualStrings(edited, sink.buffered());

    var lines: [17 * "[[t]]\n".len]u8 = undefined;

    for (0..17) |index| @memcpy(lines[index * 6 ..][0..6], "[[t]]\n");

    try testing.expectError(error.LinesExhausted, kept.parse(&lines, .{ .version = .v1_1 }));
}

test Document {
    var storage: Storage = try .init(testing.allocator, .{
        .line_count_max = null,
        .node_count_max = 64,
        .text_bytes_max = 1024,
    });

    defer storage.deinit(testing.allocator);

    var document: Document = undefined;

    try document.parse(storage, "ports = [8000, 8001, 8002]\n", .{});

    const root = document.root();
    const ports = document.member(root, "ports") orelse return error.PortsMissing;

    var items = document.items(ports);
    var total: i64 = 0;

    for (0..document.count_of(ports)) |_| {
        const item = items.next() orelse break;

        total += document.integer_of(item).?;
    }

    const after = items.next();
    const last = document.item(ports, 2) orelse return error.PortMissing;
    const middle = document.path_find(root, &.{ "ports", "1" }) orelse return error.PortMissing;

    try testing.expectEqual(@as(i64, 24003), total);
    try testing.expectEqual(@as(?Node, null), after);
    try testing.expectEqual(@as(i64, 8002), document.integer_of(last).?);
    try testing.expectEqual(@as(i64, 8001), document.integer_of(middle).?);
    try testing.expectEqual(@as(?Node, null), document.item(ports, 3));
}
