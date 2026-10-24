const std = @import("std");

const datetime_module = @import("datetime.zig");
const document_module = @import("document.zig");
const fuzz_model = @import("fuzz_model.zig");
const hash_index = @import("hash_index.zig");
const scalar = @import("scalar.zig");
const storage_module = @import("storage.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;
const testing = std.testing;

const Datetime = datetime_module.Datetime;
const Document = document_module.Document;
const DocumentType = document_module.DocumentType;
const Error = Document.Error;
const Kind = document_module.Kind;
const Node = document_module.Node;
const Position = document_module.Position;
const Storage = storage_module.Storage;
const StorageType = storage_module.StorageType;
const Value = document_module.Value;
const Version = document_module.Version;

const depth_max = document_module.depth_max;
const source_bytes_max = document_module.source_bytes_max;

const TestFixed = DocumentType(.{
    .line_count_max = null,
    .node_count_max = 512,
    .text_bytes_max = 8192,
});

const TestDocument = struct {
    document: TestFixed,

    fn parse(test_document: *TestDocument, source: []const u8) Error!*const TestFixed {
        assert(source.len <= source_bytes_max);

        try test_document.document.parse(source, .{ .version = .v1_1 });

        assert(test_document.document.document.node_count > 0);

        return &test_document.document;
    }

    fn parse_strict(test_document: *TestDocument, source: []const u8) Error!*const TestFixed {
        assert(source.len <= source_bytes_max);

        try test_document.document.parse(source, .{ .version = .v1_0 });

        assert(test_document.document.document.node_count > 0);

        return &test_document.document;
    }

    fn reject(test_document: *TestDocument, source: []const u8) ?Error {
        assert(source.len <= source_bytes_max);

        test_document.document.parse(source, .{ .version = .v1_1 }) catch |err| {
            return err;
        };

        assert(test_document.document.document.node_count > 0);

        return null;
    }
};

const versions_all = [_]Version{ .v1_0, .v1_1 };

const specification_example =
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

test "the specification's example document decodes to the values it states" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(specification_example);

    try testing.expectEqualStrings("TOML Example", document.find("title").?.string);
    try testing.expectEqualStrings("Tom Preston-Werner", document.find("owner.name").?.string);

    const dob = document.find("owner.dob").?.datetime;

    try testing.expectEqual(Datetime.Kind.datetime_offset, dob.kind);
    try testing.expectEqual(@as(u16, 1979), dob.year);
    try testing.expectEqual(@as(u8, 27), dob.day);
    try testing.expectEqual(@as(u8, 7), dob.hour);
    try testing.expectEqual(@as(i16, -480), dob.offset_minutes);
    try testing.expect(document.find("database.enabled").?.boolean);
}

test "the specification's example arrays and tables hold the elements it states" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(specification_example);
    const ports = document.path_find(document.root(), &.{ "database", "ports" }).?;
    const ports_expected = [_]i64{ 8000, 8001, 8002 };
    var elements = document.items(ports);

    try testing.expectEqual(@as(u32, 3), document.count_of(ports));

    for (ports_expected) |expected| {
        const element = elements.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqual(expected, document.integer_of(element).?);
    }

    const ports_after = elements.next();

    try testing.expectEqual(@as(?Node, null), ports_after);

    const data = document.path_find(document.root(), &.{ "database", "data" }).?;
    var rows = document.items(data);
    const words = rows.next().?;
    const numbers = rows.next().?;
    var number_elements = document.items(numbers);
    const number = number_elements.next().?;
    const cpu = document.find("database.temp_targets.cpu").?;
    const servers = document.path_find(document.root(), &.{"servers"}).?;

    try testing.expectEqual(@as(u32, 2), document.count_of(words));
    try testing.expectEqual(@as(f64, 3.14), document.float_of(number).?);
    try testing.expectEqual(@as(f64, 79.5), cpu.float);
    try testing.expectEqualStrings("backend", document.find("servers.beta.role").?.string);
    try testing.expectEqual(@as(u32, 2), document.count_of(servers));
}

test "find reads the dotted paths the way a build tool queries a pyproject" {
    const source =
        \\[project]
        \\name = "orchard-supply-shop"
        \\dependencies = [
        \\    "django>=5", # a comment with a ] inside
        \\    "psycopg[binary]",
        \\]
        \\description = """
        \\name = "not this one"
        \\"""
        \\
        \\[tool.dev_tool]
        \\port = 5745
        \\containerized = false
        \\
        \\[tool.dev_tool.docker]
        \\container-size = "8g"
        \\postgres-version = 1_4
        \\
    ;

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(source);

    try testing.expectEqualStrings("orchard-supply-shop", document.find("project.name").?.string);
    try testing.expectEqual(@as(i64, 5745), document.find("tool.dev_tool.port").?.integer);
    try testing.expect(!document.find("tool.dev_tool.containerized").?.boolean);
    const size = document.find("tool.dev_tool.docker.container-size").?;
    const version = document.find("tool.dev_tool.docker.postgres-version").?;
    const description = document.find("project.description").?;

    try testing.expectEqualStrings("8g", size.string);
    try testing.expectEqual(@as(i64, 14), version.integer);
    try testing.expectEqualStrings("name = \"not this one\"\n", description.string);
    try testing.expectEqual(@as(?Value, null), document.find("project.missing"));
    try testing.expectEqual(@as(?Value, null), document.find("project.name.deeper"));
}

test "entries follow document order and member finds exactly the key asked for" {
    const source = "z = 1\na = 2\n\"quoted key\" = 3\n'' = 4\n";
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(source);
    const root = document.root();
    const keys_expected = [_][]const u8{ "z", "a", "quoted key", "" };
    var entries_iterator = document.entries(root);

    try testing.expectEqual(@as(u32, 4), entries_iterator.remaining);

    for (keys_expected) |expected| {
        const entry = entries_iterator.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqualStrings(expected, document.key_of(entry));
    }

    const entry_after = entries_iterator.next();
    const quoted = document.member(root, "quoted key").?;
    const empty = document.member(root, "").?;

    try testing.expectEqual(@as(u32, 0), entries_iterator.remaining);
    try testing.expectEqual(@as(?Node, null), entry_after);
    try testing.expectEqual(@as(i64, 3), document.integer_of(quoted).?);
    try testing.expectEqual(@as(i64, 4), document.integer_of(empty).?);
    try testing.expectEqual(@as(?Node, null), document.member(root, "quoted"));
    try testing.expectEqual(@as(?Node, null), document.member(root, "Z"));
}

const path_source =
    \\servers = [ "alpha", "beta" ]
    \\matrix = [ [1, 2], [3, [4, 5]] ]
    \\points = [ { x = 1, y = 2 }, { x = 3, y = 4 } ]
    \\empty = []
    \\"a.b" = { "c[0]" = [7] }
    \\"" = [9]
    \\
    \\[[products]]
    \\name = "Hammer"
    \\
    \\[[products]]
    \\name = "Nail"
    \\
    \\[products.size]
    \\length = 3
    \\
    \\[[products.parts]]
    \\sku = 284758393
    \\
;

test "find indexes nested arrays, arrays of tables, and inline tables" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(path_source);
    const row = document.find("matrix[0]").?.array;

    try testing.expectEqualStrings("beta", document.find("servers[1]").?.string);
    try testing.expectEqual(@as(u32, 2), document.count_of(row));
    try testing.expectEqual(@as(i64, 3), document.find("matrix[1][0]").?.integer);
    try testing.expectEqual(@as(i64, 5), document.find("matrix[1][1][1]").?.integer);

    const point = document.find("points[0]").?.table;
    const point_found = document.path_find(document.root(), &.{ "points", "0" });

    try testing.expectEqual(@as(?Node, point), point_found);
    try testing.expectEqual(@as(i64, 4), document.find("points[1].y").?.integer);

    const sku = document.find("products[1].parts[0].sku").?;

    try testing.expectEqualStrings("Hammer", document.find("products[0].name").?.string);
    try testing.expectEqual(@as(i64, 3), document.find("products[1].size.length").?.integer);
    try testing.expectEqual(@as(i64, 284758393), sku.integer);
    try testing.expectEqual(@as(?Value, null), document.find("products[2].name"));
    try testing.expectEqual(@as(?Value, null), document.find("matrix[1][2]"));
    try testing.expectEqual(@as(?Value, null), document.find("servers[2]"));
}

test "a malformed path gives null where its well-formed neighbour resolves" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(path_source);

    const malformed = [_][]const u8{
        "[0]",
        "servers.[0]",
        "servers[",
        "servers[0",
        "servers[]",
        "servers[x]",
        "servers[01]",
        "servers[-1]",
        "servers[+1]",
        "servers[ 0]",
        "servers[0 ]",
        "servers[1.0]",
        "servers[0]x",
        "servers[0]]",
        "servers[0][",
        "servers[4294967296]",
        "servers[99999999999]",
        "matrix[1]x[0]",
    };

    for (malformed) |path| {
        errdefer std.debug.print("malformed path {s}\n", .{path});

        try testing.expectEqual(@as(?Value, null), document.find(path));
    }

    const unnamed = document.member(document.root(), "").?;

    try testing.expectEqualStrings("alpha", document.find("servers[0]").?.string);
    try testing.expectEqual(unnamed, document.find("").?.array);
    try testing.expectEqual(@as(u32, 1), document.count_of(unnamed));
}

test "a key holding a dot or a bracket is reached through path_find alone" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(path_source);
    const root = document.root();
    const seven = document.path_find(root, &.{ "a.b", "c[0]", "0" }).?;
    const nine = document.path_find(root, &.{ "", "0" }).?;

    try testing.expectEqual(@as(i64, 7), document.integer_of(seven).?);
    try testing.expectEqual(@as(i64, 9), document.integer_of(nine).?);
    try testing.expectEqual(@as(?Value, null), document.find("a.b.c[0][0]"));
    try testing.expectEqual(@as(?Value, null), document.find("\"a.b\".\"c[0]\"[0]"));
    try testing.expectEqual(@as(?Value, null), document.find("[0]"));
}

test "path_find starts at any node and reads a segment as an index only in an array" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(path_source);
    const root = document.root();
    const products = document.member(root, "products").?;
    const nail = document.item(products, 1).?;
    const sku = document.path_find(nail, &.{ "parts", "0", "sku" }).?;
    const servers = document.member(root, "servers").?;

    try testing.expectEqual(@as(i64, 284758393), document.integer_of(sku).?);
    try testing.expectEqual(@as(?Node, nail), document.path_find(root, &.{ "products", "1" }));
    try testing.expectEqual(@as(?Node, products), document.path_find(products, &.{}));
    try testing.expectEqual(document.item(servers, 1), document.path_find(servers, &.{"1"}));

    const refused = [_][]const u8{
        "",
        "x",
        "01",
        "-1",
        "+1",
        " 1",
        "1 ",
        "2",
        "4294967295",
        "4294967296",
        "18446744073709551616",
    };

    for (refused) |segment| {
        errdefer std.debug.print("refused segment {s}\n", .{segment});

        try testing.expectEqual(@as(?Node, null), document.path_find(servers, &.{segment}));
    }

    try testing.expectEqual(@as(?Node, null), document.path_find(root, &.{ "servers", "0", "x" }));
    try testing.expectEqual(@as(?Node, null), document.path_find(root, &.{"servers.0"}));
}

test "item reads each index below the count and null at or past it" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(path_source);
    const root = document.root();
    const servers = document.member(root, "servers").?;
    const products = document.member(root, "products").?;
    const empty = document.member(root, "empty").?;
    var elements = document.items(products);

    for (0..document.count_of(products)) |index| {
        const element = elements.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqual(@as(?Node, element), document.item(products, @intCast(index)));
    }

    try testing.expectEqualStrings("alpha", document.string_of(document.item(servers, 0).?).?);
    try testing.expectEqualStrings("beta", document.string_of(document.item(servers, 1).?).?);

    for ([_]u32{ 2, 3, 1000, std.math.maxInt(u32) }) |index| {
        try testing.expectEqual(@as(?Node, null), document.item(servers, index));
    }

    try testing.expectEqual(@as(u32, 0), document.count_of(empty));
    try testing.expectEqual(@as(?Node, null), document.item(empty, 0));
}

test "a lookup or an iterator on a node of the wrong kind answers empty" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(path_source);
    const root = document.root();
    const servers = document.member(root, "servers").?;
    const alpha = document.item(servers, 0).?;
    var scalar_entries = document.entries(alpha);
    var scalar_items = document.items(alpha);
    const scalar_entry = scalar_entries.next();
    const scalar_item = scalar_items.next();

    try testing.expectEqual(@as(u32, 0), scalar_entries.remaining);
    try testing.expectEqual(@as(?Node, null), scalar_entry);
    try testing.expectEqual(@as(u32, 0), scalar_items.remaining);
    try testing.expectEqual(@as(?Node, null), scalar_item);
    try testing.expectEqual(Kind.string, document.kind_of(alpha));
    try testing.expectEqual(@as(u32, 0), document.count_of(alpha));
    try testing.expectEqual(@as(?Node, null), document.member(alpha, "x"));
    try testing.expectEqual(@as(?Node, null), document.item(alpha, 0));
    try testing.expectEqual(@as(?Node, null), document.path_find(alpha, &.{"0"}));
    try testing.expectEqual(@as(?Node, alpha), document.path_find(alpha, &.{}));

    var array_entries = document.entries(servers);
    var table_items = document.items(root);
    const array_entry = array_entries.next();
    const table_item = table_items.next();

    try testing.expectEqual(@as(u32, 0), array_entries.remaining);
    try testing.expectEqual(@as(?Node, null), array_entry);
    try testing.expectEqual(@as(u32, 0), table_items.remaining);
    try testing.expectEqual(@as(?Node, null), table_item);
    try testing.expectEqual(@as(?Node, null), document.member(servers, "0"));
    try testing.expectEqual(@as(?Node, null), document.item(root, 0));
    try testing.expectEqual(@as(?Value, null), document.find("servers.x"));
    try testing.expectEqual(@as(?Value, null), document.find("servers[0].x"));
    try testing.expectEqual(@as(?Value, null), document.find("servers[0][0]"));
    try testing.expectEqual(@as(?Value, null), document.find("products[0][0]"));
}

const MemberLayout = enum {
    array_of_tables,
    dotted,
    header,
    inline_table,
    root,
};

fn member_source(writer: *std.Io.Writer, layout: MemberLayout, count: u32) !void {
    assert(count > 0);
    assert(count <= 64);

    switch (layout) {
        .array_of_tables => try writer.writeAll("[[t]]\nx = 0\n[[t]]\n"),
        .dotted, .root => {},
        .header => try writer.writeAll("[t]\n"),
        .inline_table => try writer.writeAll("t = { "),
    }

    for (0..count) |index| {
        switch (layout) {
            .array_of_tables, .header, .root => try writer.print("k{d} = {d}\n", .{ index, index }),
            .dotted => try writer.print("t.k{d} = {d}\n", .{ index, index }),
            .inline_table => try writer.print("k{d} = {d}, ", .{ index, index }),
        }
    }

    if (layout == .inline_table) try writer.writeAll("end = 0 }\n");
}

fn member_reference(document: *const TestFixed, table: Node, key: []const u8) ?Node {
    assert(@backingInt(table) < document.document.node_count);
    assert(document.kind_of(table) == .table);
    assert(key.len <= source_bytes_max);

    var iterator = document.entries(table);

    for (0..document.document.node_count) |_| {
        const entry = iterator.next() orelse return null;
        if (std.mem.eql(u8, document.key_of(entry), key)) return entry;
    }

    unreachable;
}

fn member_table(document: *const TestFixed, layout: MemberLayout) Node {
    assert(document.document.node_count > 0);
    assert(document.kind_of(document.root()) == .table);

    const result = switch (layout) {
        .array_of_tables => last: {
            var elements = document.items(document.find("t").?.array);
            var element: ?Node = null;

            for (0..2) |_| element = elements.next();

            break :last element.?;
        },
        .dotted, .header, .inline_table => document.find("t").?.table,
        .root => document.root(),
    };

    assert(document.kind_of(result) == .table);

    return result;
}

test "member lookups agree with a full scan on both sides of the index threshold" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    var buffer: [2048]u8 = undefined;
    var key_buffer: [8]u8 = undefined;

    for (std.enums.values(MemberLayout)) |layout| {
        for (1..41) |count| {
            var writer: std.Io.Writer = .fixed(&buffer);

            try member_source(&writer, layout, @intCast(count));

            const document = try test_document.parse(writer.buffered());
            const table = member_table(document, layout);

            for (0..count + 1) |index| {
                const key = try std.mem.print(&key_buffer, "k{d}", .{index});
                const found = document.member(table, key);

                try testing.expectEqual(member_reference(document, table, key), found);

                if (index < count) {
                    const expected: i64 = @intCast(index);

                    try testing.expectEqual(expected, document.integer_of(found.?).?);
                }
            }

            try testing.expectEqual(@as(?Node, null), document.member(table, "k"));
        }
    }
}

test "a duplicate key is refused at every table size" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    var buffer: [2048]u8 = undefined;

    for ([_]MemberLayout{ .dotted, .header, .root }) |layout| {
        for (1..41) |count| {
            for ([_]usize{ 0, count - 1 }) |duplicate| {
                var writer: std.Io.Writer = .fixed(&buffer);

                try member_source(&writer, layout, @intCast(count));

                if (layout == .dotted) try writer.writeAll("t.");

                try writer.print("k{d} = 0\n", .{duplicate});

                const refused = test_document.reject(writer.buffered());

                try testing.expectEqual(@as(?Error, error.KeyDuplicate), refused);
            }
        }
    }
}

const member_grid_key_count = hash_index.scan_member_count_max + 8;
const member_grid_table_count: u32 = 6;

fn member_grid_source(writer: *std.Io.Writer, interleaved: bool) !void {
    assert(writer.buffered().len == 0);
    assert(member_grid_table_count > 1);

    const outer_count = if (interleaved) member_grid_key_count else member_grid_table_count;
    const inner_count = if (interleaved) member_grid_table_count else member_grid_key_count;

    for (0..outer_count) |outer| {
        for (0..inner_count) |inner| {
            const table: u32 = @intCast(if (interleaved) inner else outer);
            const key: u32 = @intCast(if (interleaved) outer else inner);

            try writer.print("t{d}.k{d} = {d}\n", .{ table, key, key });
        }
    }
}

test "lookups stay exact while the index grows across several large tables" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const sentinel: u32 = 0xaaaa_aaaa;
    var buffer: [2048]u8 = undefined;
    var key_buffer: [8]u8 = undefined;
    var name_buffer: [8]u8 = undefined;

    for ([_]bool{ false, true }) |interleaved| {
        var writer: std.Io.Writer = .fixed(&buffer);

        try member_grid_source(&writer, interleaved);

        @memset(&test_document.document.storage.buckets, sentinel);

        const document = try test_document.parse(writer.buffered());
        const member_count = member_grid_table_count * member_grid_key_count;
        const unused = test_document.document.storage.buckets[document.document.bucket_count..];

        try testing.expectEqual(member_count, document.document.indexed_count);
        try testing.expect(document.document.bucket_count >= member_count * 2);
        try testing.expect(unused.len > 0);
        try testing.expect(std.mem.allEqual(u32, unused, sentinel));

        for (0..member_grid_table_count) |table_index| {
            const name = try std.mem.print(&name_buffer, "t{d}", .{table_index});
            const table = document.member(document.root(), name).?;

            for (0..member_grid_key_count + 1) |key_index| {
                const key = try std.mem.print(&key_buffer, "k{d}", .{key_index});
                const found = document.member(table, key);

                try testing.expectEqual(member_reference(document, table, key), found);

                if (key_index < member_grid_key_count) {
                    const expected: i64 = @intCast(key_index);

                    try testing.expectEqual(expected, document.integer_of(found.?).?);
                }
            }
        }
    }
}

test "the specification's valid table arrangements are accepted" {
    const sources = [_][]const u8{
        "[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n" ++
            "[fruit.apple.texture]\nsmooth = true\n",
        "[x.y.z.w]\n[x]\n",
        "[dog.\"tater.man\"]\ntype.name = \"pug\"\n",
        "[ j . \"ʞ\" . 'l' ]\n",
        "apple.type = \"fruit\"\norange.type = \"fruit\"\napple.skin = \"thin\"\n",
        "3.14159 = \"pi\"\n",
        "[[products]]\nname = \"Hammer\"\n[[products]]\n[[products]]\nname = \"Nail\"\n",
        "[[fruits]]\nname = \"apple\"\n[fruits.physical]\ncolor = \"red\"\n" ++
            "[[fruits.varieties]]\nname = \"red delicious\"\n[[fruits]]\nname = \"banana\"\n",
    };

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    for (sources) |source| {
        _ = try test_document.parse_strict(source);
        _ = try test_document.parse(source);
    }

    const document = try test_document.parse(sources[7]);
    const fruits = document.path_find(document.root(), &.{"fruits"}).?;
    var elements_iterator = document.items(fruits);
    const apple = elements_iterator.next().?;
    const physical = document.member(apple, "physical").?;
    const varieties = document.member(apple, "varieties").?;
    const name = document.member(apple, "name").?;
    const color = document.member(physical, "color").?;

    try testing.expectEqual(@as(u32, 2), document.count_of(fruits));
    try testing.expectEqualStrings("apple", document.string_of(name).?);
    try testing.expectEqualStrings("red", document.string_of(color).?);
    try testing.expectEqual(@as(u32, 1), document.count_of(varieties));
}

test "the specification's invalid arrangements are refused with the rule they break" {
    const Case = struct { expected: Error, source: []const u8 };

    const cases = [_]Case{
        .{ .expected = error.KeyDuplicate, .source = "name = \"Tom\"\nname = \"Pradyun\"\n" },
        .{
            .expected = error.KeyDuplicate,
            .source = "spelling = \"favorite\"\n\"spelling\" = \"favourite\"\n",
        },
        .{
            .expected = error.KeyDuplicate,
            .source = "fruit.apple = 1\nfruit.apple.smooth = true\n",
        },
        .{
            .expected = error.TableRedefined,
            .source = "[fruit]\napple = \"red\"\n[fruit]\norange = 1\n",
        },
        .{ .expected = error.KeyDuplicate, .source = "[fruit]\napple = \"red\"\n[fruit.apple]\n" },
        .{
            .expected = error.TableRedefined,
            .source = "[fruit]\napple.color = \"red\"\n[fruit.apple]\n",
        },
        .{
            .expected = error.TableRedefined,
            .source = "[product]\ntype = { name = \"Nail\" }\ntype.edible = false\n",
        },
        .{
            .expected = error.TableRedefined,
            .source = "[fruit.physical]\ncolor = \"red\"\n[[fruit]]\n",
        },
        .{ .expected = error.TableRedefined, .source = "fruits = []\n[[fruits]]\n" },
        .{ .expected = error.TableRedefined, .source = "[[fruits]]\n[fruits]\n" },
        .{ .expected = error.TableRedefined, .source = "[a.b.c]\nz = 9\n[a]\nb.c.t = 1\n" },
        .{ .expected = error.KeyInvalid, .source = "= \"no key name\"\n" },
        .{ .expected = error.ValueMissing, .source = "key = # INVALID\n" },
        .{
            .expected = error.ExpressionInvalid,
            .source = "first = \"Tom\" last = \"Preston-Werner\"\n",
        },
    };

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    for (cases) |case| {
        for (versions_all) |version| {
            const refused = test_document.document.parse(case.source, .{ .version = version });

            try testing.expectError(case.expected, refused);
        }
    }
}

test "a diagnostic names the line and column of the first error" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const unterminated = test_document.reject("a = 1\nb = \"x\nc = 3\n");

    try testing.expectEqual(@as(?Error, error.StringUnterminated), unterminated);
    try testing.expectEqual(@as(u32, 2), test_document.document.diagnostic().line);
    try testing.expectEqual(@as(u32, 7), test_document.document.diagnostic().column);

    const duplicate = test_document.reject("[t]\n'\u{e9}' = 1\n\"\u{e9}\" = 2\n");

    try testing.expectEqual(@as(?Error, error.KeyDuplicate), duplicate);
    try testing.expectEqual(@as(u32, 3), test_document.document.diagnostic().line);
    try testing.expectEqual(@as(u32, 1), test_document.document.diagnostic().column);

    const invalid = test_document.reject("ok = \"\xff\"\n");

    try testing.expectEqual(@as(?Error, error.Utf8Invalid), invalid);
    try testing.expectEqual(@as(u32, 1), test_document.document.diagnostic().line);
    try testing.expectEqual(@as(u32, 7), test_document.document.diagnostic().column);
}

const Refusal = struct {
    column: u32,
    expected: Error,
    line: u32,
    source: []const u8,
};

fn refusals_expect(
    test_document: *TestDocument,
    refusals: []const Refusal,
    versions: []const Version,
) !void {
    assert(refusals.len > 0);
    assert(versions.len > 0);
    assert(versions.len <= versions_all.len);

    for (versions) |version| {
        for (refusals) |refusal| {
            const refused = test_document.document.parse(refusal.source, .{ .version = version });
            const diagnostic = test_document.document.diagnostic();
            errdefer std.debug.print("refusal of {f} at {t}\n", .{
                std.zig.fmtString(refusal.source),
                version,
            });

            try testing.expectError(refusal.expected, refused);
            try testing.expectEqual(refusal.line, diagnostic.line);
            try testing.expectEqual(refusal.column, diagnostic.column);
        }
    }
}

const refined_refusals = [_]Refusal{
    .{ .column = 6, .expected = error.ArrayUnterminated, .line = 1, .source = "x = [\n" },
    .{ .column = 6, .expected = error.ArrayUnterminated, .line = 1, .source = "x = [" },
    .{ .column = 7, .expected = error.ArrayUnterminated, .line = 1, .source = "x = [1" },
    .{ .column = 8, .expected = error.ArrayUnterminated, .line = 1, .source = "x = [1," },
    .{
        .column = 8,
        .expected = error.ArrayUnterminated,
        .line = 1,
        .source = "x = [1,\n  \n",
    },
    .{
        .column = 4,
        .expected = error.ArrayUnterminated,
        .line = 4,
        .source = "a = 1\nx = [\n  1,\n  2\n",
    },
    .{ .column = 12, .expected = error.ArrayUnterminated, .line = 1, .source = "x = {a = [1" },
    .{ .column = 6, .expected = error.InlineTableUnterminated, .line = 1, .source = "x = {" },
    .{
        .column = 11,
        .expected = error.InlineTableUnterminated,
        .line = 1,
        .source = "x = {a = 1",
    },
    .{
        .column = 12,
        .expected = error.InlineTableUnterminated,
        .line = 1,
        .source = "x = {a = 1,",
    },
    .{ .column = 7, .expected = error.InlineTableUnterminated, .line = 1, .source = "x = {a" },
    .{ .column = 8, .expected = error.InlineTableUnterminated, .line = 1, .source = "x = {a." },
    .{
        .column = 9,
        .expected = error.InlineTableUnterminated,
        .line = 1,
        .source = "x = {a = ",
    },
    .{
        .column = 12,
        .expected = error.InlineTableUnterminated,
        .line = 1,
        .source = "x = [{a = 1",
    },
    .{
        .column = 17,
        .expected = error.InlineTableUnterminated,
        .line = 1,
        .source = "x = {a = {b = 1}",
    },
    .{ .column = 3, .expected = error.TableUnterminated, .line = 1, .source = "[a" },
    .{ .column = 3, .expected = error.TableUnterminated, .line = 1, .source = "[a\n" },
    .{ .column = 3, .expected = error.TableUnterminated, .line = 1, .source = "[a # c\n" },
    .{ .column = 4, .expected = error.TableUnterminated, .line = 1, .source = "[[a" },
    .{ .column = 5, .expected = error.TableUnterminated, .line = 1, .source = "[[a]\n" },
    .{
        .column = 5,
        .expected = error.TableUnterminated,
        .line = 2,
        .source = "x = 1\n[a.b  \r\n",
    },
    .{ .column = 5, .expected = error.ValueMissing, .line = 1, .source = "x = \n" },
    .{ .column = 5, .expected = error.ValueMissing, .line = 1, .source = "x = " },
    .{ .column = 5, .expected = error.ValueMissing, .line = 1, .source = "x = # c\n" },
    .{ .column = 5, .expected = error.ValueMissing, .line = 1, .source = "x = \r\n" },
    .{ .column = 2, .expected = error.EqualsMissing, .line = 1, .source = "x" },
    .{ .column = 2, .expected = error.EqualsMissing, .line = 1, .source = "x\n" },
    .{ .column = 3, .expected = error.EqualsMissing, .line = 1, .source = "x 1\n" },
    .{ .column = 4, .expected = error.EqualsMissing, .line = 1, .source = "x.y\n" },
    .{ .column = 2, .expected = error.EqualsMissing, .line = 2, .source = "a = 1\nb" },
};

const trailing_refusals = [_]Refusal{
    .{ .column = 7, .expected = error.ArrayUnterminated, .line = 1, .source = "x = [1 # c\n" },
    .{
        .column = 4,
        .expected = error.ArrayUnterminated,
        .line = 4,
        .source = "a = 1\nx = [\n  1,\n  2\n\n# tail\n",
    },
    .{
        .column = 12,
        .expected = error.ArrayUnterminated,
        .line = 1,
        .source = "x = [ \"a#b\" # c\n",
    },
    .{
        .column = 5,
        .expected = error.ArrayUnterminated,
        .line = 2,
        .source = "x = [\"\"\"m#\nn\"\"\" # c\n",
    },
    .{
        .column = 17,
        .expected = error.ArrayUnterminated,
        .line = 1,
        .source = "\"k#\" = [ 'v#w' , # c \"d\" '\n",
    },
    .{
        .column = 16,
        .expected = error.ArrayUnterminated,
        .line = 1,
        .source = "x = [ { a = 1 } # x\n",
    },
};

test "each refined error names the place toml-rs reports" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    try refusals_expect(test_document, &refined_refusals, &versions_all);
    try refusals_expect(test_document, &trailing_refusals, &versions_all);
}

test "an unterminated inline table behind comments and a multi-line string ends at its token" {
    const refusals = [_]Refusal{
        .{
            .column = 7,
            .expected = error.InlineTableUnterminated,
            .line = 2,
            .source = "x = {a = '''o\n#p''', # c\n\n",
        },
        .{
            .column = 6,
            .expected = error.InlineTableUnterminated,
            .line = 1,
            .source = "x = {\n  # only a comment\n",
        },
    };

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    try refusals_expect(test_document, &refusals, &.{.v1_1});
}

test "the errors the refinements leave alone keep their kind and place" {
    const refusals = [_]Refusal{
        .{ .column = 8, .expected = error.ArrayInvalid, .line = 1, .source = "x = [1 2]\n" },
        .{
            .column = 12,
            .expected = error.InlineTableInvalid,
            .line = 1,
            .source = "x = {a = 1 b = 2}\n",
        },
        .{ .column = 4, .expected = error.TableInvalid, .line = 1, .source = "[a b]\n" },
        .{ .column = 6, .expected = error.ValueInvalid, .line = 1, .source = "x = [,]\n" },
        .{ .column = 5, .expected = error.ValueInvalid, .line = 1, .source = "x = tru\n" },
        .{ .column = 1, .expected = error.KeyInvalid, .line = 1, .source = "= 1\n" },
        .{ .column = 4, .expected = error.KeyInvalid, .line = 1, .source = "[a.]\n" },
        .{ .column = 4, .expected = error.KeyInvalid, .line = 1, .source = "[a." },
        .{ .column = 6, .expected = error.KeyInvalid, .line = 1, .source = "t = {,}\n" },
        .{ .column = 13, .expected = error.KeyInvalid, .line = 1, .source = "t = { a = 1,, }\n" },
        .{ .column = 7, .expected = error.ExpressionInvalid, .line = 1, .source = "x = 1 y = 2\n" },
        .{ .column = 8, .expected = error.StringUnterminated, .line = 1, .source = "x = [\"a" },
    };

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    try refusals_expect(test_document, &refusals, &versions_all);
}

test "inline tables take newlines, comments, and a trailing comma under 1.1 only" {
    const source =
        \\t = { # opening
        \\    a = 1,
        \\    # between
        \\    b = [
        \\        2,
        \\    ], nested = {
        \\        c = 3,
        \\    },
        \\}
        \\u = { d = 4, }
        \\e = {
        \\}
        \\
    ;

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(source);

    try testing.expectEqual(@as(i64, 1), document.find("t.a").?.integer);
    try testing.expectEqual(@as(u32, 1), document.count_of(document.find("t.b").?.array));
    try testing.expectEqual(@as(i64, 3), document.find("t.nested.c").?.integer);
    try testing.expectEqual(@as(i64, 4), document.find("u.d").?.integer);
    try testing.expectEqual(@as(u32, 0), document.count_of(document.find("e").?.table));
    try testing.expectEqual(@as(u32, 3), document.count_of(document.find("t").?.table));

    const strict = [_]Refusal{
        .{ .column = 7, .expected = error.KeyInvalid, .line = 1, .source = "t = { # c\na = 1 }\n" },
        .{ .column = 6, .expected = error.KeyInvalid, .line = 1, .source = "t = {\na = 1 }\n" },
        .{
            .column = 12,
            .expected = error.InlineTableInvalid,
            .line = 1,
            .source = "t = { a = 1\n}\n",
        },
        .{
            .column = 14,
            .expected = error.InlineTableInvalid,
            .line = 1,
            .source = "t = { a = 1, }\n",
        },
        .{ .column = 6, .expected = error.KeyInvalid, .line = 1, .source = "t = {\n}\n" },
    };

    try refusals_expect(test_document, &strict, &.{.v1_0});

    const refused = [_]Refusal{
        .{ .column = 10, .expected = error.ValueMissing, .line = 1, .source = "t = { a =\n1 }\n" },
        .{ .column = 8, .expected = error.EqualsMissing, .line = 1, .source = "t = { a\n= 1 }\n" },
        .{ .column = 1, .expected = error.KeyInvalid, .line = 2, .source = "t = {\n,}\n" },
        .{
            .column = 8,
            .expected = error.CommentInvalid,
            .line = 1,
            .source = "t = { #\x01\na = 1 }\n",
        },
        .{
            .column = 12,
            .expected = error.NewlineInvalid,
            .line = 1,
            .source = "t = { a = 1\r}\n",
        },
    };

    try refusals_expect(test_document, &refused, &.{.v1_1});
}

test "the 1.1 escapes and short times are refused by 1.0 at their own column" {
    const strict = [_]Refusal{
        .{ .column = 7, .expected = error.EscapeInvalid, .line = 1, .source = "x = \"a\\eb\"\n" },
        .{ .column = 6, .expected = error.EscapeInvalid, .line = 1, .source = "x = \"\\xe9\"\n" },
        .{ .column = 2, .expected = error.EscapeInvalid, .line = 1, .source = "\"\\e\" = 1\n" },
        .{ .column = 5, .expected = error.DatetimeInvalid, .line = 1, .source = "x = 07:32\n" },
        .{
            .column = 5,
            .expected = error.DatetimeInvalid,
            .line = 1,
            .source = "x = 1979-05-27 07:32Z\n",
        },
        .{ .column = 6, .expected = error.EscapeInvalid, .line = 1, .source = "x = \"\\e\\q\"\n" },
        .{
            .column = 6,
            .expected = error.EscapeInvalid,
            .line = 1,
            .source = "x = \"\\x41\x01\"\n",
        },
        .{
            .column = 8,
            .expected = error.EscapeInvalid,
            .line = 1,
            .source = "x = \"\"\"\\e\\q\"\"\"\n",
        },
    };

    const relaxed = [_]Refusal{
        .{ .column = 8, .expected = error.EscapeInvalid, .line = 1, .source = "x = \"\\e\\q\"\n" },
        .{
            .column = 10,
            .expected = error.CharacterInvalid,
            .line = 1,
            .source = "x = \"\\x41\x01\"\n",
        },
        .{
            .column = 10,
            .expected = error.EscapeInvalid,
            .line = 1,
            .source = "x = \"\"\"\\e\\q\"\"\"\n",
        },
    };

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    try refusals_expect(test_document, &strict, &.{.v1_0});
    try refusals_expect(test_document, &relaxed, &.{.v1_1});

    const document = try test_document.parse(
        "x = \"a\\eb\\xe9\"\n\"\\e\" = 1\nt = 07:32\nd = 1979-05-27 07:32Z\n",
    );

    try testing.expectEqualStrings("a\x1bb\u{e9}", document.find("x").?.string);

    const escape = document.member(document.root(), "\x1b").?;

    try testing.expectEqual(@as(i64, 1), document.integer_of(escape).?);
    try testing.expect(!document.find("t").?.datetime.spelling.second_present);
    try testing.expect(document.find("d").?.datetime.spelling.offset_zulu);
}

const LineColumn = struct {
    column: u32,
    line: u32,
};

fn position_expect(document: *const TestFixed, node: Node, expected: ?LineColumn) !void {
    assert(@backingInt(node) < document.document.node_count);
    assert(document.document.node_count > 0);

    const position = document.position_of(node);

    try testing.expectEqual(expected == null, position == null);

    const found = position orelse return;
    const line_column = expected.?;
    const source = document.document.source;

    try testing.expectEqual(line_column.column, found.column);
    try testing.expectEqual(line_column.line, found.line);
    try testing.expectEqual(found, scalar.position_of(source, found.offset));
}

test "a position names where each node was written in the source" {
    const source =
        \\bare = 1
        \\"quoted" = 2
        \\'literal' = 3
        \\"esc\u0041ped" = 4
        \\"" = 5
        \\list = [ 10,
        \\  "eleven", [12] ]
        \\inline = { k = 7, "q" = 8 }
        \\[t . "u"]
        \\v = 6
        \\[[a]]
        \\[[ 'a' ]]
        \\
    ;

    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(source);
    const root = document.root();

    try position_expect(document, root, .{ .column = 1, .line = 1 });
    try position_expect(document, document.member(root, "bare").?, .{ .column = 1, .line = 1 });
    try position_expect(document, document.member(root, "quoted").?, .{ .column = 1, .line = 2 });
    try position_expect(document, document.member(root, "literal").?, .{ .column = 1, .line = 3 });
    try position_expect(document, document.member(root, "escAped").?, null);
    try position_expect(document, document.member(root, "").?, .{ .column = 1, .line = 5 });

    const list = document.member(root, "list").?;
    var elements = document.items(list);
    const ten = elements.next().?;
    const eleven = elements.next().?;
    const nested = elements.next().?;
    var nested_elements = document.items(nested);
    const twelve = nested_elements.next().?;

    try position_expect(document, list, .{ .column = 1, .line = 6 });
    try position_expect(document, ten, .{ .column = 10, .line = 6 });
    try position_expect(document, eleven, .{ .column = 3, .line = 7 });
    try position_expect(document, nested, .{ .column = 13, .line = 7 });
    try position_expect(document, twelve, .{ .column = 14, .line = 7 });

    const inline_table = document.member(root, "inline").?;
    const member_bare = document.member(inline_table, "k").?;
    const member_quoted = document.member(inline_table, "q").?;

    try position_expect(document, inline_table, .{ .column = 1, .line = 8 });
    try position_expect(document, member_bare, .{ .column = 12, .line = 8 });
    try position_expect(document, member_quoted, .{ .column = 19, .line = 8 });

    const value = document.path_find(root, &.{ "t", "u", "v" }).?;

    try position_expect(document, document.find("t").?.table, .{ .column = 2, .line = 9 });
    try position_expect(document, document.find("t.u").?.table, .{ .column = 6, .line = 9 });
    try position_expect(document, value, .{ .column = 1, .line = 10 });

    const array = document.member(root, "a").?;
    var tables = document.items(array);
    const first = tables.next().?;
    const second = tables.next().?;

    try position_expect(document, array, .{ .column = 3, .line = 11 });
    try position_expect(document, first, .{ .column = 3, .line = 11 });
    try position_expect(document, second, .{ .column = 4, .line = 12 });
}

test "a position counts characters after a byte order mark and multibyte keys" {
    const source = "\xef\xbb\xbf\"\u{e9}\" = [\"\u{e9}\", 2]\n";
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse(source);
    const array = document.member(document.root(), "\u{e9}").?;
    var elements = document.items(array);
    const word = elements.next().?;
    const number = elements.next().?;

    try position_expect(document, document.root(), .{ .column = 1, .line = 1 });
    try position_expect(document, array, .{ .column = 2, .line = 1 });
    try position_expect(document, word, .{ .column = 9, .line = 1 });
    try position_expect(document, number, .{ .column = 14, .line = 1 });
}

test "storage limits are reported as errors and plain strings need no text storage" {
    const Small = StorageType(.{
        .line_count_max = null,
        .node_count_max = 3,
        .text_bytes_max = 0,
    });

    var small: Small = undefined;
    var document: Document = undefined;

    try document.parse(small.storage(), "a = 'x'\nb = \"plain\"\n", .{ .version = .v1_1 });
    try testing.expectEqualStrings("plain", document.find("b").?.string);

    const crowded = "a = 1\nb = 2\nc = 3\n";
    const exhausted = document.parse(small.storage(), crowded, .{ .version = .v1_1 });

    try testing.expectError(error.NodesExhausted, exhausted);

    const escaped = document.parse(small.storage(), "a = \"tab\\there\"\n", .{ .version = .v1_1 });

    try testing.expectError(error.TextExhausted, escaped);
}

test "parse keeps the whole bucket slice and clears none of it for a short document" {
    const Large = StorageType(.{
        .line_count_max = null,
        .node_count_max = 1 << 12,
        .text_bytes_max = 0,
    });

    const sentinel: u32 = 0xaaaa_aaaa;
    const source = "a = 1\nb = 2\n";
    const large = try testing.allocator.create(Large);
    defer testing.allocator.destroy(large);

    var document: Document = undefined;

    @memset(&large.buckets, sentinel);

    try document.parse(large.storage(), source, .{ .version = .v1_1 });

    try testing.expectEqual(large.buckets.len, document.buckets.len);
    try testing.expectEqual(@as(u32, 0), document.bucket_count);
    try testing.expect(std.mem.allEqual(u32, &large.buckets, sentinel));
    try testing.expectEqual(@as(i64, 1), document.find("a").?.integer);
    try testing.expectEqual(@as(i64, 2), document.find("b").?.integer);
}

test "a document parsed into runtime storage equals one parsed into fixed storage" {
    const capacity: storage_module.Capacity = .{
        .line_count_max = null,
        .node_count_max = 128,
        .text_bytes_max = 256,
    };

    const Fixed = StorageType(capacity);
    const fixed = try testing.allocator.create(Fixed);
    defer testing.allocator.destroy(fixed);

    var runtime: Storage = try .init(testing.allocator, capacity);
    defer runtime.deinit(testing.allocator);

    var expected: Document = undefined;
    var actual: Document = undefined;

    try expected.parse(fixed.storage(), specification_example, .{ .version = .v1_1 });
    try actual.parse(runtime, specification_example, .{ .version = .v1_1 });

    try testing.expectEqual(fixed.buckets.len, runtime.buckets.len);
    try testing.expectEqual(fixed.nodes.len, runtime.nodes.len);
    try testing.expectEqual(fixed.text.len, runtime.text.len);
    try testing.expectEqual(expected.node_count, actual.node_count);

    for (0..expected.node_count) |index| {
        const node: Node = @fromBackingInt(@as(u32, @intCast(index)));

        try testing.expectEqual(expected.kind_of(node), actual.kind_of(node));
        try testing.expectEqualStrings(expected.key_of(node), actual.key_of(node));
        try testing.expectEqual(expected.position_of(node), actual.position_of(node));
    }
}

test "a storage that runs out of memory part way releases what it took" {
    const capacity: storage_module.Capacity = .{
        .line_count_max = null,
        .node_count_max = 16,
        .text_bytes_max = 64,
    };

    for (0..3) |fail_index| {
        const config: testing.FailingAllocator.Config = .{ .fail_index = fail_index };
        var failing: testing.FailingAllocator = .init(testing.allocator, config);
        const refused = Storage.init(failing.allocator(), capacity);

        try testing.expectError(error.OutOfMemory, refused);
    }
}

test "nesting at depth_max is accepted and one level deeper is refused" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    var buffer: [depth_max * 2 + 16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("a = ");
    try writer.splatByteAll('[', depth_max);
    try writer.splatByteAll(']', depth_max);
    _ = try test_document.parse(writer.buffered());

    writer = .fixed(&buffer);

    try writer.writeAll("a = ");
    try writer.splatByteAll('[', depth_max + 1);
    try writer.splatByteAll(']', depth_max + 1);

    const refused = test_document.reject(writer.buffered());

    try testing.expectEqual(@as(?Error, error.DepthExceeded), refused);
}

test "a byte order mark and CRLF lines are accepted and a bare carriage return is not" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    const document = try test_document.parse("\xef\xbb\xbfa = 1\r\nb = \"\"\"x\r\ny\"\"\"\r\n");

    try testing.expectEqual(@as(i64, 1), document.find("a").?.integer);
    try testing.expectEqualStrings("x\ny", document.find("b").?.string);

    const refused = test_document.reject("a = 1\rb = 2\n");

    try testing.expectEqual(@as(?Error, error.NewlineInvalid), refused);
}

const comment_prefix = "a = 1 #";
const comment_suffix = "\nb = 2\n";
const comment_width: u32 = 72;

fn comment_source(buffer: []u8, length: u32, byte: u8) []const u8 {
    assert(length < comment_width);
    assert(byte != '\n');
    assert(buffer.len >= comment_prefix.len + comment_width + comment_suffix.len);

    const end = comment_prefix.len + comment_width + comment_suffix.len;

    @memcpy(buffer[0..comment_prefix.len], comment_prefix);
    @memset(buffer[comment_prefix.len..][0..comment_width], 'c');
    @memcpy(buffer[end - comment_suffix.len .. end], comment_suffix);
    buffer[comment_prefix.len + length] = byte;

    const result = buffer[0..end];

    assert(result[comment_prefix.len + length] == byte);

    return result;
}

test "a comment refuses a control byte at its own column and accepts a tab at any offset" {
    const test_document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(test_document);

    var buffer: [128]u8 = undefined;

    for (0..comment_width) |length| {
        const tabbed = comment_source(&buffer, @intCast(length), '\t');
        const document = try test_document.parse(tabbed);

        try testing.expectEqual(@as(i64, 2), document.find("b").?.integer);

        const controlled = comment_source(&buffer, @intCast(length), 0x01);
        const refused = test_document.reject(controlled);
        const column: u32 = @intCast(comment_prefix.len + length + 1);

        try testing.expectEqual(@as(?Error, error.CommentInvalid), refused);
        try testing.expectEqual(@as(u32, 1), test_document.document.diagnostic().line);
        try testing.expectEqual(column, test_document.document.diagnostic().column);
    }
}

test "every error has a message of its own" {
    const names = @typeInfo(toml.Error).error_set.error_names.?;

    var messages: [names.len][]const u8 = undefined;

    inline for (names, 0..) |name, index| {
        messages[index] = toml.message(@field(toml.Error, name));
    }

    for (messages, 0..) |outer, outer_index| {
        try testing.expect(outer.len > 0);

        for (messages[outer_index + 1 ..]) |inner| {
            try testing.expect(!std.mem.eql(u8, outer, inner));
        }
    }
}

const EditStorage = StorageType(.{
    .line_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 2048,
});

const EditFixture = struct {
    output: [4096]u8,
    pairs: fuzz_model.Pairs,
    source_storage: EditStorage,
    storage: EditStorage,

    fn written(fixture: *EditFixture, document: *const Document) ![]const u8 {
        assert(document.node_count > 0);

        var sink: std.Io.Writer = .fixed(&fixture.output);

        try document.write(&sink, .{ .layout = .compact, .strings = .basic, .version = .v1_1 });

        assert(sink.end <= fixture.output.len);

        return sink.buffered();
    }
};

fn member_scan(document: *const Document, table: Node, key: []const u8) ?Node {
    assert(document.kind_of(table) == .table);
    assert(key.len <= source_bytes_max);

    var entries = document.entries(table);

    for (0..document.count_of(table)) |_| {
        const entry = entries.next() orelse return null;
        if (std.mem.eql(u8, document.key_of(entry), key)) return entry;
    }

    return null;
}

test "set swaps a scalar for a container and back in the same record" {
    const fixture = try testing.allocator.create(EditFixture);
    defer testing.allocator.destroy(fixture);

    var document: Document = undefined;

    document.init(fixture.storage.storage());

    const root = document.root();
    const value = try document.set(root, "value", .{ .integer = 1 });
    const table = try document.set(root, "value", .{ .table = .header });

    try testing.expectEqual(value, table);

    const inner = try document.set(table, "inner", .{ .string = "x" });
    const list = try document.set(table, "list", .{ .array = .inline_array });

    _ = try document.append(list, .{ .integer = 2 });
    _ = try document.append(list, .{ .float = 0.5 });

    const swapped = "[value]\ninner = \"x\"\nlist = [2, 0.5]\n";

    try testing.expectEqualStrings(swapped, try fixture.written(&document));

    const back = try document.set(root, "value", .{ .boolean = true });
    const inner_record = &document.nodes[@backingInt(inner)];

    try testing.expectEqual(value, back);
    try testing.expectEqual(Kind.boolean, document.kind_of(back));
    try testing.expect(inner_record.flags.detached);
    try testing.expectEqual(@as(u32, 1), document.count_of(root));
    try testing.expectEqualStrings("value = true\n", try fixture.written(&document));
    try fuzz_model.invariants_check(&document);
}

test "remove keeps every lookup exact on small and indexed tables" {
    const fixture = try testing.allocator.create(EditFixture);
    defer testing.allocator.destroy(fixture);

    var document: Document = undefined;
    var key_buffer: [8]u8 = undefined;

    for ([_]u32{ 5, 30 }) |count| {
        document.init(fixture.storage.storage());

        const root = document.root();

        for (0..count) |number| {
            const key = try std.mem.print(&key_buffer, "k{d}", .{number});

            _ = try document.set(root, key, .{ .integer = @intCast(number) });
        }

        try testing.expectEqual(count > 16, document.nodes[0].flags.indexed);

        for (0..count) |round| {
            if (round % 3 != 1) continue;

            const removed = try std.mem.print(&key_buffer, "k{d}", .{round});

            document.remove(document.member(root, removed).?);

            for (0..count + 1) |number| {
                const key = try std.mem.print(&key_buffer, "k{d}", .{number});
                const expected = member_scan(&document, root, key);

                try testing.expectEqual(expected, document.member(root, key));
            }

            try fuzz_model.invariants_check(&document);
        }
    }
}

test "merge joins or replaces arrays and descends into tables" {
    const fixture = try testing.allocator.create(EditFixture);
    defer testing.allocator.destroy(fixture);

    var document: Document = undefined;
    var source: Document = undefined;

    const target_text = "a = [1]\nb = 'kept'\n[t]\nx = 1\n";
    const source_text = "a = [2, 3]\n[t]\ny = 2\nx = 'replaced'\n[[u]]\nz = true\n";

    try source.parse(fixture.source_storage.storage(), source_text, .{ .version = .v1_1 });

    for ([_]Document.Merge.Arrays{ .join, .replace }) |arrays| {
        try document.parse(fixture.storage.storage(), target_text, .{ .version = .v1_1 });
        try document.merge(&source, .{ .arrays = arrays });
        try fuzz_model.invariants_check(&document);

        const head = switch (arrays) {
            .join => "a = [1, 2, 3]\n",
            .replace => "a = [2, 3]\n",
        };

        const tail = "b = \"kept\"\n\n[t]\nx = \"replaced\"\ny = 2\n\n[[u]]\nz = true\n";
        const written = try fixture.written(&document);
        const copied = document.find("u").?.array;

        try testing.expectEqualStrings(head, written[0..head.len]);
        try testing.expectEqualStrings(tail, written[head.len..]);
        try testing.expectEqual(@as(?Position, null), document.position_of(copied));
    }
}

test "a failed merge leaves the position of the source node it could not copy" {
    const Small = StorageType(.{
        .line_count_max = null,
        .node_count_max = 4,
        .text_bytes_max = 64,
    });

    const fixture = try testing.allocator.create(EditFixture);
    defer testing.allocator.destroy(fixture);

    var small: Small = undefined;
    var document: Document = undefined;
    var source: Document = undefined;
    const source_text = "a = 1\nb = 2\n[t]\nc = 3\n";

    try source.parse(fixture.source_storage.storage(), source_text, .{ .version = .v1_1 });

    document.init(small.storage());

    const refused = document.merge(&source, .{ .arrays = .join });
    const expected: Position = .{ .column = 1, .line = 4, .offset = 16 };

    try testing.expectError(error.NodesExhausted, refused);
    try testing.expectEqual(expected, document.diagnostic);
    try fuzz_model.invariants_check(&document);

    _ = try document.set(document.root(), "a", .{ .integer = 2 });

    try testing.expectEqual(document_module.position_none, document.diagnostic);
}

test "a failed set or append leaves the document unchanged" {
    const Small = StorageType(.{
        .line_count_max = null,
        .node_count_max = 4,
        .text_bytes_max = 8,
    });

    var small: Small = undefined;
    var document: Document = undefined;

    document.init(small.storage());

    const root = document.root();
    const list = try document.set(root, "l", .{ .array = .inline_array });

    _ = try document.set(root, "s", .{ .string = "abc" });

    var invalid = try datetime_module.parse("1979-05-27", .v1_1);

    invalid.day = 31;
    invalid.month = 2;

    const long = document.set(root, "t", .{ .string = "toolong" });
    const key_invalid = document.set(root, "\xff", .{ .integer = 1 });
    const string_invalid = document.append(list, .{ .string = "\xc3" });
    const datetime_invalid = document.append(list, .{ .datetime = invalid });

    try testing.expectError(error.TextExhausted, long);
    try testing.expectError(error.Utf8Invalid, key_invalid);
    try testing.expectError(error.Utf8Invalid, string_invalid);
    try testing.expectError(error.DatetimeInvalid, datetime_invalid);
    try testing.expectEqual(@as(u32, 3), document.node_count);
    try testing.expectEqual(@as(u32, "l".len + "s".len + "abc".len), document.text_used);

    _ = try document.append(list, .{ .integer = 1 });

    const member_full = document.set(root, "n", .{ .integer = 1 });
    const element_full = document.append(list, .{ .integer = 2 });

    try testing.expectError(error.NodesExhausted, member_full);
    try testing.expectError(error.NodesExhausted, element_full);
    try testing.expectEqual(@as(u32, 4), document.node_count);
    try testing.expectEqualStrings("abc", document.find("s").?.string);
    try fuzz_model.invariants_check(&document);
}

test "an edit may nest to depth_max and no deeper" {
    const fixture = try testing.allocator.create(EditFixture);
    defer testing.allocator.destroy(fixture);

    var document: Document = undefined;

    document.init(fixture.storage.storage());

    var table = document.root();

    for (0..depth_max) |_| table = try document.set(table, "d", .{ .table = .implicit });

    const count = document.node_count;
    const deeper = document.set(table, "d", .{ .integer = 1 });

    try testing.expectError(error.DepthExceeded, deeper);
    try testing.expectEqual(count, document.node_count);

    const list = try document.set(document.root(), "list", .{ .array = .inline_array });

    _ = try document.append(list, .{ .array = .inline_array });

    try fuzz_model.invariants_check(&document);

    var sink: std.Io.Writer = .fixed(&fixture.output);

    try document.write(&sink, .{ .layout = .compact, .strings = .auto, .version = .v1_1 });

    const reparsed = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(reparsed);

    _ = try reparsed.parse(sink.buffered());
}
