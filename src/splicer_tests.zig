const std = @import("std");

const document_module = @import("document.zig");

const assert = std.debug.assert;
const testing = std.testing;

const Content = Document.Content;
const Document = document_module.Document;
const Node = document_module.Node;
const Version = document_module.Version;

const operation_count_max: u32 = 8;
const output_bytes_max: u32 = 4096;
const path_none: []const []const u8 = &.{};

const Kept = document_module.DocumentType(.{
    .line_count_max = 64,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const Append = struct {
    content: Content,
    path: []const []const u8,
};

const Buffers = [2][output_bytes_max]u8;

const Golden = struct {
    expected: []const u8,
    operations: []const Operation,
    source: []const u8,
    version: Version = .v1_1,
};

const Operation = union(enum) {
    append: Append,
    remove: []const []const u8,
    set: Set,
};

const Set = struct {
    content: Content,
    key: []const u8,
    path: []const []const u8,
};

const Written = struct {
    first: []const u8,
    second: []const u8,
};

fn golden_write(golden: Golden, buffers: *Buffers) !Written {
    assert(golden.source.len < output_bytes_max);
    assert(golden.expected.len < output_bytes_max);

    const kept = try testing.allocator.create(Kept);
    defer testing.allocator.destroy(kept);

    const again = try testing.allocator.create(Kept);
    defer testing.allocator.destroy(again);

    const options: Document.Options = .{ .version = golden.version };

    try kept.parse(golden.source, options);

    try operations_apply(&kept.document, golden.operations);

    var first: std.Io.Writer = .fixed(&buffers[0]);

    try kept.write(&first, .{ .version = golden.version });
    try again.parse(first.buffered(), options);

    var second: std.Io.Writer = .fixed(&buffers[1]);

    again.document.nodes[0].flags.edited = true;

    try again.write(&second, .{ .version = golden.version });

    return .{ .first = first.buffered(), .second = second.buffered() };
}

fn node_at(document: *const Document, path: []const []const u8) Node {
    assert(document.node_count > 0);
    assert(path.len <= document.node_count);

    if (path.len == 0) return document.root();
    return document.path_find(document.root(), path) orelse unreachable;
}

fn operations_apply(document: *Document, operations: []const Operation) !void {
    assert(document.line_count > 0);
    assert(operations.len <= operation_count_max);

    for (operations) |operation| {
        switch (operation) {
            .append => |append| {
                _ = try document.append(node_at(document, append.path), append.content);
            },
            .remove => |path| document.remove(node_at(document, path)),
            .set => |set| {
                _ = try document.set(node_at(document, set.path), set.key, set.content);
            },
        }
    }
}

test "an unedited document is written back byte for byte" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "\xef\xbb\xbf# head\r\na  .  b = 0xDEAD_BEEF # c\r\n[t]\r\ns = '''x'''",
        .operations = &.{},
        .source = "\xef\xbb\xbf# head\r\na  .  b = 0xDEAD_BEEF # c\r\n[t]\r\ns = '''x'''",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "new text takes the CRLF line ending of the source" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = 1\r\nc = 3\r\n[t]\r\nb = 2\r\nx = \"s\"\r\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .integer = 3 }, .key = "c", .path = path_none } },
            .{ .set = .{ .content = .{ .string = "s" }, .key = "x", .path = &.{"t"} } },
        },
        .source = "a = 1\r\n[t]\r\nb = 2\r\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a byte order mark stays first and root members go after it" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "\xef\xbb\xbfa = 1\n\n[t]\nb = 2\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .integer = 1 }, .key = "a", .path = path_none } },
        },
        .source = "\xef\xbb\xbf[t]\nb = 2\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a source without a final newline gets one before anything is appended" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = 1 # one\nb = 2\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .integer = 2 }, .key = "b", .path = path_none } },
        },
        .source = "a = 1 # one",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "an edited value is written over its old span and keeps its key and comment" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = \"x\" # keep\nb   =   5\nc = 'same'\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .string = "x" }, .key = "a", .path = path_none } },
            .{ .set = .{ .content = .{ .integer = 5 }, .key = "b", .path = path_none } },
        },
        .source = "a = 1 # keep\nb   =   0x10\nc = 'same'\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a new section goes after the last section of its parent's subtree" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "[a]\nx = 1\n\n[b]\ny = 2\n\n[a.c]\nz = 3\n\n[a.d]\nk = 1\n\n# tail\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .table = .header }, .key = "d", .path = &.{"a"} } },
            .{ .set = .{ .content = .{ .integer = 1 }, .key = "k", .path = &.{ "a", "d" } } },
        },
        .source = "[a]\nx = 1\n\n[b]\ny = 2\n\n[a.c]\nz = 3\n\n# tail\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a new section goes in before the comment block that leads into the next header" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "[a]\nx = 1\n# end of a\n\n[a.n]\nk = true\n\n# about b\n[b]\ny = 2\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .table = .header }, .key = "n", .path = &.{"a"} } },
            .{ .set = .{ .content = .{ .boolean = true }, .key = "k", .path = &.{ "a", "n" } } },
        },
        .source = "[a]\nx = 1\n# end of a\n\n# about b\n[b]\ny = 2\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "new members of a dotted table follow its last line in the section" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "[t]\n  a.b = 1\n  c = 2\n  a.d = 3\n  a.f = 5\n  e = 4\n  g = 6\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .integer = 5 }, .key = "f", .path = &.{ "t", "a" } } },
            .{ .set = .{ .content = .{ .integer = 6 }, .key = "g", .path = &.{"t"} } },
        },
        .source = "[t]\n  a.b = 1\n  c = 2\n  a.d = 3\n  e = 4\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "an implicit table that gains a line member gets its own header first" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "top = 0\n\n[a]\ny = 2\n\n[a.b]\nx = 1\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .integer = 2 }, .key = "y", .path = &.{"a"} } },
        },
        .source = "top = 0\n\n[a.b]\nx = 1\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "an appended array of tables element goes after the previous element's sub-tables" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "[[p]]\nn = 1\n[p.q]\nm = 2\n\n[[p]]\nn = 2\n\n[r]\ns = 3\n",
        .operations = &.{
            .{ .append = .{ .content = .{ .table = .implicit }, .path = &.{"p"} } },
            .{ .set = .{ .content = .{ .integer = 2 }, .key = "n", .path = &.{ "p", "1" } } },
        },
        .source = "[[p]]\nn = 1\n[p.q]\nm = 2\n\n[r]\ns = 3\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a multi-line array keeps its trailing comma habit when it grows" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = [\n  1,\n  2,\n  3,\n]\nb = [\n    1,\n    2, # two\n    3\n]\n",
        .operations = &.{
            .{ .append = .{ .content = .{ .integer = 3 }, .path = &.{"a"} } },
            .{ .append = .{ .content = .{ .integer = 3 }, .path = &.{"b"} } },
        },
        .source = "a = [\n  1,\n  2,\n]\nb = [\n    1,\n    2 # two\n]\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a single-line container takes a new element after its last one" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = [1, 2, 3]\nt = { a = 1, b = 2, c = 3 }\ne = [1]\n",
        .operations = &.{
            .{ .append = .{ .content = .{ .integer = 3 }, .path = &.{"a"} } },
            .{ .set = .{ .content = .{ .integer = 3 }, .key = "c", .path = &.{"t"} } },
            .{ .append = .{ .content = .{ .integer = 1 }, .path = &.{"e"} } },
        },
        .source = "a = [1, 2]\nt = { a = 1, b = 2 }\ne = []\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a removed element takes one comma and an edited element is replaced in place" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = [1, 3]\nt = { a = \"x\" }\nz = [1, 2]\n",
        .operations = &.{
            .{ .remove = &.{ "a", "1" } },
            .{ .remove = &.{ "t", "b" } },
            .{ .set = .{ .content = .{ .string = "x" }, .key = "a", .path = &.{"t"} } },
            .{ .remove = &.{ "z", "2" } },
        },
        .source = "a = [1, 2, 3]\nt = { a = 1, b = 2 }\nz = [1, 2, 3]\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a removed element alone on its line takes the line and its comment" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = [\n  1, # one\n  3,\n]\n",
        .operations = &.{
            .{ .remove = &.{ "a", "1" } },
        },
        .source = "a = [\n  1, # one\n  2, # two\n  3,\n]\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a removed key and a removed section take their head comments" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = 1\n\nc = 3\n\n[r]\nx = 1\n\n# about t\n[t]\nz = 3\n",
        .operations = &.{
            .{ .remove = &.{"b"} },
            .{ .remove = &.{"s"} },
        },
        .source = "a = 1\n\n# about b\nb = 2\nc = 3\n\n[r]\nx = 1\n\n# about s\n[s]\ny = 2\n\n" ++
            "# about t\n[t]\nz = 3\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "a value that changes form leaves its old place and is written where the form goes" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "t = 5\n\n[u]\ny = 2\n\n[h]\nk = 1\n",
        .operations = &.{
            .{ .set = .{ .content = .{ .integer = 5 }, .key = "t", .path = path_none } },
            .{ .set = .{ .content = .{ .table = .header }, .key = "h", .path = path_none } },
            .{ .set = .{ .content = .{ .integer = 1 }, .key = "k", .path = &.{"h"} } },
        },
        .source = "h = 0\n\n[t]\nx = 1\n\n[u]\ny = 2\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}

test "an array of tables that loses every element becomes an empty inline array" {
    var buffers: Buffers = undefined;

    const golden: Golden = .{
        .expected = "a = 1\np = []\n\n[q]\nz = 1\n",
        .operations = &.{
            .{ .remove = &.{ "p", "0" } },
        },
        .source = "a = 1\n\n[[p]]\nn = 1\n\n[q]\nz = 1\n",
    };

    const written = try golden_write(golden, &buffers);

    try testing.expectEqualStrings(golden.expected, written.first);
    try testing.expectEqualStrings(written.first, written.second);
}
