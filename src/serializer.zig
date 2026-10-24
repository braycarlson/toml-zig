const std = @import("std");

const document_module = @import("document.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const Record = storage_module.Record;
const Writer = writer_module.Writer;

pub const Serializer = struct {
    document: *const Document,
    header_array: u32,
    header_cache: [header_cache_bytes_max]u8,
    header_length: u32,
    path: [depth_max][]const u8,
    writer: Writer,

    fn sections_write(serializer: *Serializer) align(64) std.Io.Writer.Error!void {
        assert(serializer.document.node_count > 0);
        assert(serializer.writer.depth == 0);

        const document = serializer.document;
        var node: u32 = root_index;
        var entering = true;

        for (0..2 * document.node_count + 2) |_| {
            if (entering) {
                try serializer.section_enter(node);

                const child = section_child_first(document, node);

                if (child != none) {
                    node = child;

                    continue;
                }

                entering = false;
            }

            if (node == root_index) return;

            const sibling = section_sibling_next(document, node);

            if (sibling == none) {
                node = document.nodes[node].parent;
            } else {
                node = sibling;
                entering = true;
            }
        }

        unreachable;
    }

    pub fn subtree_sections_write(serializer: *Serializer, top: u32) std.Io.Writer.Error!void {
        assert(top > root_index);
        assert(top < serializer.document.node_count);

        const document = serializer.document;
        var node = top;
        var entering = true;

        for (0..2 * document.node_count + 2) |_| {
            if (entering) {
                try serializer.section_enter(node);

                const child = section_child_first(document, node);

                if (child != none) {
                    node = child;

                    continue;
                }

                entering = false;
            }

            if (node == top) return;

            const sibling = section_sibling_next(document, node);

            if (sibling == none) {
                node = document.nodes[node].parent;
            } else {
                node = sibling;
                entering = true;
            }
        }

        unreachable;
    }

    pub inline fn section_enter(serializer: *Serializer, node: u32) std.Io.Writer.Error!void {
        assert(node < serializer.document.node_count);
        assert(serializer.writer.depth == 0);

        const document = serializer.document;
        const record = &document.nodes[node];

        if (node == root_index) {
            return serializer.lines_write(.{ .header_pending = false, .section = node });
        }

        if (record.kind == .array) return;

        if (document.nodes[record.parent].kind == .array) {
            try serializer.array_header_write(record.parent);

            return serializer.lines_write(.{ .header_pending = false, .section = node });
        }

        if (record.flags.explicit) {
            try serializer.table_header_write(node);

            return serializer.lines_write(.{ .header_pending = false, .section = node });
        }

        if (record.section != none) return;
        if (record.count == 0) return serializer.table_header_write(node);

        try serializer.lines_write(.{ .header_pending = true, .section = node });
    }

    fn lines_write(serializer: *Serializer, lines: Lines) align(64) std.Io.Writer.Error!void {
        assert(lines.section < serializer.document.node_count);
        assert(serializer.document.nodes[lines.section].kind == .table);

        const document = serializer.document;
        var pending = lines.header_pending;
        var table = lines.section;
        var cursor = document.nodes[lines.section].child_first;

        for (0..2 * document.node_count + 1) |_| {
            if (cursor == none) {
                if (table == lines.section) return;

                cursor = document.nodes[table].sibling_next;
                table = document.nodes[table].parent;

                continue;
            }

            const record = &document.nodes[cursor];

            switch (line_kind_of(document, cursor)) {
                .dotted => {
                    table = cursor;
                    cursor = record.child_first;

                    continue;
                },
                .line => {
                    if (pending) {
                        try serializer.table_header_write(lines.section);

                        pending = false;
                    }

                    try serializer.line_write(.{ .node = cursor, .top = lines.section });
                },
                .section => {},
            }

            cursor = record.sibling_next;
        }

        unreachable;
    }

    pub fn line_write(serializer: *Serializer, chain: Chain) std.Io.Writer.Error!void {
        assert(chain.node < serializer.document.node_count);
        assert(chain.top < chain.node);

        const record = &serializer.document.nodes[chain.node];

        try writer_module.key_trusted_write(&serializer.writer, serializer.chain_collect(chain));

        switch (record.kind) {
            .array, .table => try serializer.inline_write(chain.node),
            .boolean, .datetime, .float, .integer, .string => try serializer.scalar_write(record),
        }
    }

    pub fn inline_write(serializer: *Serializer, top: u32) align(64) std.Io.Writer.Error!void {
        assert(top < serializer.document.node_count);
        assert(!flattened(serializer.document, top));

        const document = serializer.document;
        var container = top;
        var cursor = document.nodes[top].child_first;

        try serializer.container_begin(top);

        for (0..2 * document.node_count + 1) |_| {
            if (cursor == none) {
                const finished = &document.nodes[container];

                if (!flattened(document, container)) {
                    try writer_module.container_close(&serializer.writer);

                    if (container == top) return;
                }

                cursor = finished.sibling_next;
                container = finished.parent;

                continue;
            }

            const record = &document.nodes[cursor];

            if (document.nodes[record.parent].kind == .table) {
                if (flattened(document, cursor)) {
                    container = cursor;
                    cursor = record.child_first;

                    continue;
                }

                try serializer.inline_key_write(cursor);
            }

            switch (record.kind) {
                .array, .table => {
                    try serializer.container_begin(cursor);

                    container = cursor;
                    cursor = record.child_first;

                    continue;
                },
                .boolean, .datetime, .float, .integer, .string => {
                    try serializer.scalar_write(record);
                },
            }

            cursor = record.sibling_next;
        }

        unreachable;
    }

    fn container_begin(serializer: *Serializer, node: u32) std.Io.Writer.Error!void {
        assert(node < serializer.document.node_count);
        assert(serializer.writer.depth < depth_max);

        const document = serializer.document;
        const record = &document.nodes[node];

        const opening: writer_module.Opening = switch (record.kind) {
            .array => .{ .count = record.count, .inline_table = false },
            .table => .{ .count = pair_count(document, node), .inline_table = true },
            .boolean, .datetime, .float, .integer, .string => unreachable,
        };

        try writer_module.container_open(&serializer.writer, opening);
    }

    fn inline_key_write(serializer: *Serializer, node: u32) std.Io.Writer.Error!void {
        assert(node < serializer.document.node_count);
        assert(serializer.writer.depth > 0);

        const document = serializer.document;
        var top = document.nodes[node].parent;

        for (0..depth_max) |_| {
            if (!flattened(document, top)) break;

            top = document.nodes[top].parent;
        }

        const path = serializer.chain_collect(.{ .node = node, .top = top });

        try writer_module.key_trusted_write(&serializer.writer, path);
    }

    pub fn scalar_write(serializer: *Serializer, record: *const Record) std.Io.Writer.Error!void {
        assert(record.count == 0);
        assert(!record.flags.detached);

        const writer = &serializer.writer;

        switch (record.kind) {
            .boolean => try writer_module.boolean_write(writer, record.payload.boolean),
            .datetime => try writer_module.datetime_trusted_write(writer, &record.payload.datetime),
            .float => try writer_module.float_write(writer, f64, record.payload.float),
            .integer => try writer_module.integer_write(writer, record.payload.integer),
            .string => try writer_module.string_trusted_write(writer, record.payload.string),
            .array, .table => unreachable,
        }
    }

    pub fn table_header_write(serializer: *Serializer, node: u32) std.Io.Writer.Error!void {
        assert(node > root_index);
        assert(node < serializer.document.node_count);

        const path = serializer.header_path_collect(node);
        const header: writer_module.Header = .{ .kind = .table, .path = path };

        try writer_module.header_trusted_write(&serializer.writer, header);
    }

    pub inline fn array_header_write(serializer: *Serializer, array: u32) std.Io.Writer.Error!void {
        assert(array < serializer.document.node_count);
        assert(serializer.document.nodes[array].kind == .array);

        if (serializer.header_array == array) {
            const text = serializer.header_cache[0..serializer.header_length];
            return writer_module.header_text_write(&serializer.writer, text);
        }

        const header: writer_module.Header = .{
            .kind = .table_array,
            .path = serializer.header_path_collect(array),
        };

        var cache: std.Io.Writer = .fixed(&serializer.header_cache);

        writer_module.header_render(&cache, header) catch |err| switch (err) {
            error.WriteFailed => {
                serializer.header_array = none;

                return writer_module.header_trusted_write(&serializer.writer, header);
            },
        };

        serializer.header_array = array;
        serializer.header_length = @intCast(cache.end);

        try writer_module.header_text_write(&serializer.writer, cache.buffered());
    }

    pub fn chain_collect(serializer: *Serializer, chain: Chain) []const []const u8 {
        assert(chain.node < serializer.document.node_count);
        assert(chain.top < chain.node);

        const document = serializer.document;
        var start: u32 = depth_max;
        var current = chain.node;

        for (0..depth_max) |_| {
            start -= 1;
            serializer.path[start] = document.nodes[current].key;
            current = document.nodes[current].parent;

            if (current == chain.top) return serializer.path[start..];
        }

        unreachable;
    }

    fn header_path_collect(serializer: *Serializer, node: u32) []const []const u8 {
        assert(node > root_index);
        assert(node < serializer.document.node_count);

        const document = serializer.document;
        var start: u32 = depth_max;
        var current = node;

        for (0..document.node_count) |_| {
            if (current == root_index) {
                assert(start < depth_max);

                return serializer.path[start..];
            }

            const parent = document.nodes[current].parent;

            if (document.nodes[parent].kind == .table) {
                assert(start > 0);

                start -= 1;
                serializer.path[start] = document.nodes[current].key;
            }

            current = parent;
        }

        unreachable;
    }
};

pub const Chain = struct {
    node: u32,
    top: u32,
};

pub const Line = enum {
    dotted,
    line,
    section,
};

const Lines = struct {
    header_pending: bool,
    section: u32,
};

const depth_max = document_module.depth_max;
const header_cache_bytes_max: u32 = 512;
const none = storage_module.none;
const root_index: u32 = 0;

comptime {
    assert(header_cache_bytes_max >= 64);
    assert(root_index < none);
}

pub fn write(
    document: *const Document,
    sink: *std.Io.Writer,
    options: Writer.Options,
) std.Io.Writer.Error!void {
    assert(document.node_count > 0);
    assert(document.node_count <= document.nodes.len);
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    var serializer: Serializer = undefined;

    serializer.document = document;
    serializer.header_array = none;
    serializer.header_length = 0;

    serializer.writer.init(sink, options);

    try serializer.sections_write();

    serializer.writer.finish();
}

pub fn line_kind_of(document: *const Document, node: u32) Line {
    assert(node > root_index);
    assert(node < document.node_count);

    const record = &document.nodes[node];

    switch (record.kind) {
        .array => {
            if (array_of_tables_writable(document, record)) return .section;
            return .line;
        },
        .table => return table_line_kind_of(record),
        .boolean, .datetime, .float, .integer, .string => return .line,
    }
}

fn table_line_kind_of(record: *const Record) Line {
    assert(record.kind == .table);
    assert(!record.flags.detached);

    if (record.flags.closed) return .line;
    if (record.flags.explicit) return .section;
    if (record.section == none) return .section;
    if (record.count == 0) return .line;
    return .dotted;
}

pub fn array_of_tables_writable(document: *const Document, record: *const Record) bool {
    assert(record.kind == .array);
    assert(record.count <= document.node_count);

    if (!record.flags.array_of_tables) return false;
    if (record.count == 0) return false;

    var element = record.child_first;

    for (0..record.count) |_| {
        if (document.nodes[element].kind != .table) return false;

        element = document.nodes[element].sibling_next;
    }

    assert(element == none);

    return true;
}

pub fn flattened(document: *const Document, node: u32) bool {
    assert(node < document.node_count);
    assert(document.node_count <= document.nodes.len);

    const record = &document.nodes[node];
    if (record.kind != .table) return false;
    if (node == root_index) return false;
    if (document.nodes[record.parent].kind != .table) return false;
    if (record.flags.closed) return false;
    if (record.flags.explicit) return false;
    if (record.section == none) return false;
    return record.count > 0;
}

fn pair_count(document: *const Document, table: u32) u32 {
    assert(table < document.node_count);
    assert(document.nodes[table].kind == .table);

    var count: u32 = 0;
    var container = table;
    var cursor = document.nodes[table].child_first;

    for (0..2 * document.node_count + 1) |_| {
        if (cursor == none) {
            if (container == table) {
                assert(count >= document.nodes[table].count);

                return count;
            }

            cursor = document.nodes[container].sibling_next;
            container = document.nodes[container].parent;

            continue;
        }

        if (flattened(document, cursor)) {
            container = cursor;
            cursor = document.nodes[cursor].child_first;

            continue;
        }

        count += 1;
        cursor = document.nodes[cursor].sibling_next;
    }

    unreachable;
}

pub fn section_child_first(document: *const Document, node: u32) u32 {
    assert(node < document.node_count);
    assert(document.nodes[node].kind != .boolean);

    const record = &document.nodes[node];
    if (record.kind == .array) return record.child_first;
    return section_member_from(document, record.child_first);
}

pub fn section_sibling_next(document: *const Document, node: u32) u32 {
    assert(node > root_index);
    assert(node < document.node_count);

    const record = &document.nodes[node];
    if (document.nodes[record.parent].kind == .array) return record.sibling_next;
    return section_member_from(document, record.sibling_next);
}

fn section_member_from(document: *const Document, start: u32) u32 {
    assert(start == none or start < document.node_count);
    assert(document.node_count <= document.nodes.len);

    var cursor = start;

    for (0..document.node_count) |_| {
        if (cursor == none) return none;
        if (line_kind_of(document, cursor) != .line) return cursor;

        cursor = document.nodes[cursor].sibling_next;
    }

    unreachable;
}

const testing = std.testing;

const TestFixed = document_module.DocumentType(.{
    .line_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const test_options: Writer.Options = .{
    .layout = .vertical,
    .strings = .auto,
    .version = .v1_1,
};

const TestPair = struct {
    source: []const u8,
    written: []const u8,
};

const TestCase = struct {
    fixed: TestFixed,
    output: [4096]u8,
    sink: std.Io.Writer,

    fn written(test_case: *TestCase, options: Writer.Options) ![]const u8 {
        assert(test_case.fixed.document.node_count > 0);
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);

        test_case.sink = .fixed(&test_case.output);

        try write(&test_case.fixed.document, &test_case.sink, options);

        return test_case.sink.buffered();
    }

    fn round_trip(test_case: *TestCase, pair: TestPair) !void {
        assert(pair.source.len < test_case.output.len);
        assert(pair.written.len < test_case.output.len);

        try test_case.fixed.parse(pair.source, .{ .version = .v1_1 });

        const first = try test_case.written(test_options);
        var copy: [4096]u8 = undefined;

        @memcpy(copy[0..first.len], first);

        const second = try test_case.written(test_options);

        try testing.expectEqualStrings(pair.written, first);
        try testing.expectEqualStrings(copy[0..first.len], second);
    }
};

const test_specification_source =
    \\# This is a TOML document
    \\
    \\title = "TOML Example"
    \\
    \\[owner]
    \\name = "Tom Preston-Werner"
    \\dob = 1979-05-27T07:32:00-08:00
    \\
    \\[database]
    \\enabled = true
    \\ports = [ 8000, 8001, 8002 ]
    \\data = [ ["delta", "phi"], [3.14] ]
    \\temp_targets = { cpu = 79.5, case = 72.0 }
    \\
    \\[servers]
    \\
    \\[servers.alpha]
    \\ip = "10.0.0.1"
    \\role = "frontend"
    \\
    \\[servers.beta]
    \\ip = "10.0.0.2"
    \\role = "backend"
    \\
;

const test_specification_written =
    \\title = "TOML Example"
    \\
    \\[owner]
    \\name = "Tom Preston-Werner"
    \\dob = 1979-05-27T07:32:00-08:00
    \\
    \\[database]
    \\enabled = true
    \\ports = [
    \\    8000,
    \\    8001,
    \\    8002,
    \\]
    \\data = [
    \\    [
    \\        "delta",
    \\        "phi",
    \\    ],
    \\    [3.14],
    \\]
    \\temp_targets = {
    \\    cpu = 79.5,
    \\    case = 72.0,
    \\}
    \\
    \\[servers]
    \\
    \\[servers.alpha]
    \\ip = "10.0.0.1"
    \\role = "frontend"
    \\
    \\[servers.beta]
    \\ip = "10.0.0.2"
    \\role = "backend"
    \\
;

test "the specification's example is written back in the same shape" {
    const test_case = try testing.allocator.create(TestCase);
    defer testing.allocator.destroy(test_case);

    try test_case.round_trip(.{
        .source = test_specification_source,
        .written = test_specification_written,
    });
}

test "dotted keys stay dotted and their sub-tables follow as headers" {
    const source =
        \\name.first = "Tom"
        \\z = 1
        \\name.last.full = "Preston-Werner"
        \\point = { x.a = 1, x.b = 2, y = {} }
        \\[name.extra]
        \\k = true
        \\[name.last.more]
        \\
    ;

    const expected =
        \\name.first = "Tom"
        \\name.last.full = "Preston-Werner"
        \\z = 1
        \\point = {
        \\    x.a = 1,
        \\    x.b = 2,
        \\    y = {},
        \\}
        \\
        \\[name.last.more]
        \\
        \\[name.extra]
        \\k = true
        \\
    ;

    const test_case = try testing.allocator.create(TestCase);
    defer testing.allocator.destroy(test_case);

    try test_case.round_trip(.{ .source = source, .written = expected });
}

test "nested arrays of tables reuse their header and keep their sub-tables in order" {
    const source =
        \\[[fruits]]
        \\name = "apple"
        \\[fruits.physical]
        \\color = "red"
        \\[[fruits.varieties]]
        \\name = "red delicious"
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\[[fruits]]
        \\name = "banana"
        \\[[fruits.varieties]]
        \\name = "plantain"
        \\
    ;

    const expected =
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[fruits.physical]
        \\color = "red"
        \\
        \\[[fruits.varieties]]
        \\name = "red delicious"
        \\
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\
        \\[[fruits]]
        \\name = "banana"
        \\
        \\[[fruits.varieties]]
        \\name = "plantain"
        \\
    ;

    const test_case = try testing.allocator.create(TestCase);
    defer testing.allocator.destroy(test_case);

    try test_case.round_trip(.{ .source = source, .written = expected });
}

test "implicit tables stay silent until they hold a line or nothing at all" {
    const test_case = try testing.allocator.create(TestCase);
    defer testing.allocator.destroy(test_case);

    try test_case.fixed.parse("[a.b.c]\nx = 1\n", .{ .version = .v1_1 });

    const document = &test_case.fixed.document;
    const outer = document.member(document.root(), "a").?;
    const inner = document.member(outer, "b").?;

    try testing.expectEqualStrings("[a.b.c]\nx = 1\n", try test_case.written(test_options));

    _ = try document.set(inner, "line", .{ .integer = 2 });
    _ = try document.set(document.root(), "empty", .{ .table = .implicit });
    _ = try document.set(document.root(), "header", .{ .table = .header });
    _ = try document.set(document.root(), "dotted", .{ .table = .dotted });

    const expected =
        \\dotted = {}
        \\
        \\[a.b]
        \\line = 2
        \\
        \\[a.b.c]
        \\x = 1
        \\
        \\[empty]
        \\
        \\[header]
        \\
    ;

    try testing.expectEqualStrings(expected, try test_case.written(test_options));
}

test "an array of tables holding a scalar or nothing falls back to an inline array" {
    const test_case = try testing.allocator.create(TestCase);
    defer testing.allocator.destroy(test_case);

    try test_case.fixed.parse("[[a]]\nk = 1\n[[a]]\nk = 2\n", .{ .version = .v1_1 });

    const document = &test_case.fixed.document;
    const root = document.root();
    const tables = document.member(root, "a").?;

    _ = try document.set(root, "none", .{ .array = .array_of_tables });
    _ = try document.append(tables, .{ .string = "odd" });

    const expected = "a = [\n    { k = 1 },\n    { k = 2 },\n    \"odd\",\n]\nnone = []\n";

    try testing.expectEqualStrings(expected, try test_case.written(test_options));

    var compact = test_options;

    compact.layout = .compact;
    compact.strings = .basic;

    const flat = "a = [{ k = 1 }, { k = 2 }, \"odd\"]\nnone = []\n";

    try testing.expectEqualStrings(flat, try test_case.written(compact));
}

test "every form inside an inline container is written inline" {
    const test_case = try testing.allocator.create(TestCase);
    defer testing.allocator.destroy(test_case);

    try test_case.fixed.parse("t = {}\n", .{ .version = .v1_1 });

    const document = &test_case.fixed.document;
    const outer = document.member(document.root(), "t").?;
    const header = try document.set(outer, "h", .{ .table = .header });
    const tables = try document.set(outer, "list", .{ .array = .array_of_tables });
    const element = try document.append(tables, .{ .table = .implicit });

    _ = try document.set(header, "x", .{ .integer = 1 });
    _ = try document.set(element, "y", .{ .boolean = false });

    const expected = "t = { h = { x = 1 }, list = [{ y = false }] }\n";

    var strict = test_options;

    strict.version = .v1_0;

    try testing.expectEqualStrings(expected, try test_case.written(strict));
}

test write {
    const Config = document_module.DocumentType(.{
        .line_count_max = null,
        .node_count_max = 64,
        .text_bytes_max = 256,
    });

    const config = try testing.allocator.create(Config);
    defer testing.allocator.destroy(config);

    try config.parse("[server]\nports = [8000, 8001]\nhost = 'local'\n", .{ .version = .v1_1 });

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try config.write(&sink, .{ .layout = .compact, .strings = .basic, .version = .v1_0 });

    const expected = "[server]\nports = [8000, 8001]\nhost = \"local\"\n";

    try testing.expectEqualStrings(expected, sink.buffered());
}
