const std = @import("std");

const bounded = @import("bounded.zig");
const toml = @import("toml.zig");

const assert = std.debug.assert;

const Content = toml.Document.Content;
const element_append = toml.Document.append;

const file_bytes_max: u32 = 4 * 1024 * 1024;
const fraction_digit_count_max: u32 = 9;
const json_values_bytes_max: u32 = 16 * 1024 * 1024;
const output_bytes_max: u32 = 4 * file_bytes_max;
const pair_count_max: u32 = 1 << 16;
const path_bytes_max: u32 = 1024;
const usage_text = "usage: conformance <toml-test tests directory> [output directory]\n";

const capacity: toml.Capacity = .{
    .line_count_max = null,
    .node_count_max = 1 << 18,
    .text_bytes_max = 1 << 22,
};

const capacity_kept: toml.Capacity = .{
    .line_count_max = 1 << 18,
    .node_count_max = capacity.node_count_max,
    .text_bytes_max = capacity.text_bytes_max,
};

const datetime_kinds: std.StaticStringMap(toml.Datetime.Kind) = .initComptime(.{
    .{ "date-local", .date_local },
    .{ "datetime", .datetime_offset },
    .{ "datetime-local", .datetime_local },
    .{ "time-local", .time_local },
});

const leaf_kinds: std.StaticStringMap(toml.Kind) = .initComptime(.{
    .{ "bool", .boolean },
    .{ "date-local", .datetime },
    .{ "datetime", .datetime },
    .{ "datetime-local", .datetime },
    .{ "float", .float },
    .{ "integer", .integer },
    .{ "string", .string },
    .{ "time-local", .datetime },
});

const json_options: std.json.ParseOptions = .{
    .allocate = .alloc_always,
    .duplicate_field_behavior = .@"error",
    .ignore_unknown_fields = false,
    .max_value_len = null,
    .parse_numbers = false,
};

const Documents = struct {
    left: *const toml.Document,
    right: *const toml.Document,
};

const List = struct {
    name: []const u8,
    version: toml.Version,
};

const lists = [_]List{
    .{ .name = "files-toml-1.0.0", .version = .v1_0 },
    .{ .name = "files-toml-1.1.0", .version = .v1_1 },
};

const table_forms = [_]toml.Document.TableForm{ .header, .implicit, .dotted, .inline_table };

const writings = [_]Writing{
    .{ .layout = .vertical, .name = "vertical-auto", .strings = .auto },
    .{ .layout = .compact, .name = "compact-basic", .strings = .basic },
};

comptime {
    assert(json_values_bytes_max >= file_bytes_max);
    assert(lists.len == std.enums.values(toml.Version).len);
    assert(pair_count_max >= 1024);
    assert(path_bytes_max >= 256);
    assert(table_forms.len == std.enums.values(toml.Document.TableForm).len);
}

const Document = toml.DocumentType(capacity);
const DocumentKept = toml.DocumentType(capacity_kept);
const Path = bounded.BoundedArrayType(u8, path_bytes_max);

const Direction = enum {
    encoder,
    round_trip,
};

const Writing = struct {
    layout: toml.Writer.Layout,
    name: []const u8,
    strings: toml.Writer.Strings,
};

const Pair = struct {
    expected: *const std.json.Value,
    node: toml.Node,
};

const Pairs = bounded.BoundedArrayType(Pair, pair_count_max);

const Leaf = struct {
    kind: []const u8,
    value: []const u8,
};

const Rotation = struct {
    arrays: u32,
    tables: u32,
};

const Outcome = struct {
    failed: u32,
    passed: u32,

    const empty: Outcome = .{ .failed = 0, .passed = 0 };

    fn count(outcome: *Outcome, passed: bool) void {
        assert(outcome.failed < std.math.maxInt(u32));
        assert(outcome.passed < std.math.maxInt(u32));

        if (passed) {
            outcome.passed += 1;
        } else {
            outcome.failed += 1;
        }
    }
};

const Tally = struct {
    encoder: Outcome,
    invalid_accepted: u32,
    invalid_rejected: u32,
    layout: Outcome,
    round_trip: Outcome,
    valid: Outcome,

    const empty: Tally = .{
        .encoder = .empty,
        .invalid_accepted = 0,
        .invalid_rejected = 0,
        .layout = .empty,
        .round_trip = .empty,
        .valid = .empty,
    };
};

const Case = struct {
    expected: *const std.json.Value,
    expected_text: []const u8,
    name: []const u8,
};

const Runner = struct {
    built: toml.Document,
    built_storage: toml.StorageType(capacity),
    document: Document,
    dump: ?std.Io.Dir,
    expected: [file_bytes_max]u8,
    io: std.Io,
    json_values: [json_values_bytes_max]u8,
    kept: DocumentKept,
    list: [file_bytes_max]u8,
    output: [output_bytes_max]u8,
    pairs: Pairs,
    rotation: Rotation,
    source: [file_bytes_max]u8,
    suite: []const u8,
    tally: Tally,
    version: toml.Version,
    written: Document,

    fn list_run(runner: *Runner, list: *const List) !void {
        assert(list.name.len > 0);
        assert(runner.suite.len > 0);

        runner.tally = .empty;
        runner.version = list.version;

        const names = try runner.file_read(list.name, &runner.list);

        var lines = std.mem.tokenizeScalar(u8, names, '\n');

        for (0..names.len + 1) |_| {
            const line = lines.next() orelse break;

            try runner.case_run(std.mem.trim(u8, line, " \r"));
        }

        const tally = runner.tally;

        std.debug.print("{s} at {t}: decoder valid {d} passed, {d} failed; " ++
            "invalid {d} rejected, {d} accepted; encoder {d} passed, {d} failed; " ++
            "round trip {d} passed, {d} failed\n", .{
            list.name,
            list.version,
            tally.valid.passed,
            tally.valid.failed,
            tally.invalid_rejected,
            tally.invalid_accepted,
            tally.encoder.passed,
            tally.encoder.failed,
            tally.round_trip.passed,
            tally.round_trip.failed,
        });

        std.debug.print("layout: {d} cases, {d} differ\n", .{
            tally.layout.passed + tally.layout.failed,
            tally.layout.failed,
        });
    }

    fn case_run(runner: *Runner, name: []const u8) !void {
        assert(name.len > 0);
        assert(runner.suite.len > 0);

        if (std.mem.endsWith(u8, name, ".json")) return;
        if (std.mem.startsWith(u8, name, "valid/")) return runner.valid_run(name);
        if (std.mem.startsWith(u8, name, "invalid/")) return runner.invalid_run(name);

        std.debug.print("unrecognized entry {s}\n", .{name});

        return error.ListInvalid;
    }

    fn invalid_run(runner: *Runner, name: []const u8) !void {
        assert(std.mem.startsWith(u8, name, "invalid/"));
        assert(std.mem.endsWith(u8, name, ".toml"));

        const source = try runner.file_read(name, &runner.source);

        runner.document.parse(source, .{ .version = runner.version }) catch {
            runner.tally.invalid_rejected += 1;

            return;
        };

        runner.tally.invalid_accepted += 1;

        std.debug.print("FAIL {s}: accepted\n", .{name});
    }

    fn valid_run(runner: *Runner, name: []const u8) !void {
        assert(std.mem.startsWith(u8, name, "valid/"));
        assert(std.mem.endsWith(u8, name, ".toml"));

        const source = try runner.file_read(name, &runner.source);

        var expected_name: Path = .empty;

        try expected_name.print("{s}.json", .{name[0 .. name.len - ".toml".len]});

        const expected_text = try runner.file_read(expected_name.slice(), &runner.expected);

        var values: std.heap.FixedBufferAllocator = .init(&runner.json_values);

        const expected = try std.json.parseFromSliceLeaky(
            std.json.Value,
            values.allocator(),
            expected_text,
            json_options,
        );

        const case: Case = .{ .expected = &expected, .expected_text = expected_text, .name = name };
        const decoded = runner.decoder_run(&case, source);

        if (decoded) runner.tally.layout.count(try runner.layout_run(&case, source));

        runner.tally.round_trip.count(decoded and try runner.direction_run(&case, .round_trip));
        runner.tally.encoder.count(try runner.encoder_run(&case));
    }

    fn layout_run(runner: *Runner, case: *const Case, source: []const u8) !bool {
        assert(case.name.len > 0);
        assert(source.len <= file_bytes_max);

        runner.kept.parse(source, .{ .version = runner.version }) catch |err| {
            std.debug.print("FAIL {s}: refused with lines kept: {t}\n", .{ case.name, err });

            return false;
        };

        const documents: Documents = .{
            .left = &runner.document.document,
            .right = &runner.kept.document,
        };

        if (!records_equal(documents)) {
            std.debug.print("FAIL {s}: lines kept changed the tree\n", .{case.name});

            return false;
        }

        for ([_]bool{ false, true }) |walked| {
            runner.kept.document.nodes[0].flags.edited = walked;

            var sink: std.Io.Writer = .fixed(&runner.output);

            try runner.kept.write(&sink, .{ .version = runner.version });

            if (!std.mem.eql(u8, sink.buffered(), source)) {
                std.debug.print("FAIL {s}: layout differs, walked {}\n{s}\n", .{
                    case.name,
                    walked,
                    sink.buffered(),
                });

                return false;
            }
        }

        return true;
    }

    fn decoder_run(runner: *Runner, case: *const Case, source: []const u8) bool {
        assert(case.name.len > 0);
        assert(source.len <= file_bytes_max);

        runner.document.parse(source, .{ .version = runner.version }) catch |err| {
            runner.tally.valid.failed += 1;

            std.debug.print("FAIL {s}: rejected {t} at {d}:{d}\n", .{
                case.name,
                err,
                runner.document.diagnostic().line,
                runner.document.diagnostic().column,
            });

            return false;
        };

        const matched = runner.document_matches(&runner.document, case.expected);

        runner.tally.valid.count(matched);

        if (!matched) std.debug.print("FAIL {s}: decoded value differs\n", .{case.name});

        return matched;
    }

    fn encoder_run(runner: *Runner, case: *const Case) !bool {
        assert(case.name.len > 0);
        assert(runner.built_storage.nodes.len == capacity.node_count_max);

        runner.json_build(case.expected) catch |err| {
            std.debug.print("FAIL {s}: the document was not built: {t}\n", .{ case.name, err });

            return false;
        };

        return runner.direction_run(case, .encoder);
    }

    fn direction_run(runner: *Runner, case: *const Case, direction: Direction) !bool {
        assert(case.name.len > 0);
        assert(@backingInt(direction) < std.enums.values(Direction).len);

        const document = switch (direction) {
            .encoder => &runner.built,
            .round_trip => &runner.document.document,
        };

        var passed = true;

        for (&writings) |*writing| {
            var sink: std.Io.Writer = .fixed(&runner.output);

            try document.write(&sink, .{
                .layout = writing.layout,
                .strings = writing.strings,
                .version = runner.version,
            });

            const written = sink.buffered();
            const dump: Dump = .{ .direction = direction, .written = written, .writing = writing };

            try runner.output_dump(case, dump);

            if (!runner.written_matches(case, written)) {
                std.debug.print("FAIL {s}: {t} {s}\n{s}\n", .{
                    case.name,
                    direction,
                    writing.name,
                    written,
                });

                passed = false;
            }
        }

        return passed;
    }

    fn written_matches(runner: *Runner, case: *const Case, written: []const u8) bool {
        assert(case.name.len > 0);
        assert(written.len <= output_bytes_max);

        runner.written.parse(written, .{ .version = runner.version }) catch |err| {
            std.debug.print("written text refused with {t} at {d}:{d}\n", .{
                err,
                runner.written.diagnostic().line,
                runner.written.diagnostic().column,
            });

            return false;
        };

        return runner.document_matches(&runner.written, case.expected);
    }

    fn output_dump(runner: *Runner, case: *const Case, dump: Dump) !void {
        assert(case.name.len > 0);
        assert(dump.written.len <= output_bytes_max);

        if (runner.version != .v1_0) return;

        var name: Path = .empty;

        try name.print("{t}-{s}-", .{ dump.direction, dump.writing.name });

        const stem_start = name.count;

        try name.push_slice(case.name[0 .. case.name.len - ".toml".len]);
        std.mem.replaceScalar(u8, name.slice_mutable()[stem_start..], '/', '_');

        const stem_end = name.count;
        const directory = runner.dump orelse return;

        try name.push_slice(".toml");
        try file_write(runner.io, directory, .{ .data = dump.written, .name = name.slice() });

        name.truncate(stem_end);

        try name.push_slice(".json");
        try file_write(runner.io, directory, .{ .data = case.expected_text, .name = name.slice() });
    }

    fn json_build(runner: *Runner, expected: *const std.json.Value) !void {
        assert(expected.* == .object);
        assert(runner.pairs.count <= pair_count_max);

        const built = &runner.built;

        built.init(runner.built_storage.storage());

        runner.pairs = .empty;
        runner.rotation = .{ .arrays = 0, .tables = 0 };
        const top: Pair = .{ .expected = expected, .node = built.root() };

        runner.pairs.push_slot_assume_capacity().* = top;

        for (0..pair_count_max) |_| {
            if (runner.pairs.count == 0) return;

            const pair = runner.pairs.get(runner.pairs.count - 1).*;

            runner.pairs.truncate(runner.pairs.count - 1);

            switch (pair.expected.*) {
                .array => |*array| try runner.elements_build(pair.node, array.items),
                .object => |*object| try runner.members_build(pair.node, object),
                else => return error.ShapeInvalid,
            }
        }

        return error.ComparisonUnbounded;
    }

    fn members_build(runner: *Runner, table: toml.Node, object: *const std.json.ObjectMap) !void {
        assert(@backingInt(table) < runner.built.node_count);
        assert(object.count() < pair_count_max);

        for (object.keys(), object.values()) |key, *value| {
            const content = try runner.content_of(value);
            const member = try runner.built.set(table, key, content);

            try runner.child_push(member, value);
        }
    }

    fn elements_build(runner: *Runner, array: toml.Node, items: []const std.json.Value) !void {
        assert(@backingInt(array) < runner.built.node_count);
        assert(items.len < pair_count_max);

        for (items) |*item| {
            const content = try runner.content_of(item);
            const element = try element_append(&runner.built, array, content);

            try runner.child_push(element, item);
        }
    }

    fn child_push(runner: *Runner, node: toml.Node, value: *const std.json.Value) !void {
        assert(@backingInt(node) < runner.built.node_count);
        assert(runner.pairs.count < pair_count_max);

        if (leaf_of(value) != null) return;

        const slot = try runner.pairs.push_slot();

        slot.* = .{ .expected = value, .node = node };
    }

    fn content_of(runner: *Runner, value: *const std.json.Value) !Content {
        assert(value.* != .null);
        assert(runner.rotation.tables < std.math.maxInt(u32));

        if (leaf_of(value)) |leaf| return leaf_content(&leaf);

        switch (value.*) {
            .array => |*array| {
                if (!tables_only(array.items)) return .{ .array = .inline_array };

                runner.rotation.arrays += 1;

                const aot = runner.rotation.arrays % 2 == 1;
                return .{ .array = if (aot) .array_of_tables else .inline_array };
            },
            .object => {
                const form = table_forms[runner.rotation.tables % table_forms.len];

                runner.rotation.tables += 1;

                return .{ .table = form };
            },
            else => return error.ShapeInvalid,
        }
    }

    fn file_read(runner: *Runner, name: []const u8, buffer: []u8) ![]const u8 {
        assert(name.len > 0);
        assert(runner.suite.len > 0);
        assert(buffer.len == file_bytes_max);

        var full: Path = .empty;

        try full.print("{s}/{s}", .{ runner.suite, name });

        const content = try std.Io.Dir.cwd().readFile(runner.io, full.slice(), buffer);
        if (content.len == buffer.len) return error.FileTooLarge;
        return content;
    }

    fn document_matches(
        runner: *Runner,
        document: *const Document,
        expected: *const std.json.Value,
    ) bool {
        assert(document.document.node_count > 0);
        assert(runner.pairs.count <= pair_count_max);

        runner.pairs = .empty;

        runner.pairs.push_slot_assume_capacity().* = .{
            .expected = expected,
            .node = document.root(),
        };

        for (0..pair_count_max) |_| {
            if (runner.pairs.count == 0) return true;

            const pair = runner.pairs.get(runner.pairs.count - 1).*;

            runner.pairs.truncate(runner.pairs.count - 1);

            if (!runner.pair_matches(document, &pair)) return false;
        }

        std.debug.print("comparison exceeded {d} steps\n", .{pair_count_max});

        return false;
    }

    fn pair_matches(runner: *Runner, document: *const Document, pair: *const Pair) bool {
        assert(pair.expected.* != .null);
        assert(runner.pairs.count < pair_count_max);

        if (leaf_of(pair.expected)) |leaf| return leaf_matches(document, pair.node, &leaf);

        switch (pair.expected.*) {
            .array => |array| {
                if (document.kind_of(pair.node) != .array) return mismatch("array", pair.node);

                if (document.count_of(pair.node) != array.items.len) {
                    return mismatch("array length", pair.node);
                }

                var elements = document.items(pair.node);

                for (array.items) |*item| {
                    const element = elements.next() orelse return false;
                    const slot = runner.pairs.push_slot() catch return false;

                    slot.* = .{ .expected = item, .node = element };
                }

                return true;
            },
            .object => |*object| return runner.table_matches(document, pair.node, object),
            else => return mismatch("JSON shape", pair.node),
        }
    }

    fn table_matches(
        runner: *Runner,
        document: *const Document,
        node: toml.Node,
        object: *const std.json.ObjectMap,
    ) bool {
        assert(@backingInt(node) < document.document.node_count);
        assert(object.count() < pair_count_max);

        if (document.kind_of(node) != .table) return mismatch("table", node);
        if (document.count_of(node) != object.count()) return mismatch("table size", node);

        for (object.keys(), object.values()) |key, *value| {
            const member = document.member(node, key) orelse {
                std.debug.print("missing key {s}\n", .{key});

                return false;
            };

            const slot = runner.pairs.push_slot() catch return false;

            slot.* = .{ .expected = value, .node = member };
        }

        return true;
    }
};

const Dump = struct {
    direction: Direction,
    written: []const u8,
    writing: *const Writing,
};

const FileWrite = struct {
    data: []const u8,
    name: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return usage();
    if (arguments.len > 3) return usage();

    const runner = try init.gpa.create(Runner);
    defer init.gpa.destroy(runner);

    runner.dump = null;
    runner.io = init.io;
    runner.pairs = .empty;
    runner.suite = arguments[1];

    if (arguments.len == 3) {
        runner.dump = try std.Io.Dir.cwd().createDirPathOpen(init.io, arguments[2], .{
            .open_options = .{
                .access_sub_paths = true,
                .follow_symlinks = true,
                .iterate = false,
            },
            .permissions = .default_dir,
        });
    }

    defer if (runner.dump) |directory| directory.close(init.io);

    var failed = false;

    for (&lists) |*list| {
        try runner.list_run(list);

        if (runner.tally.valid.failed > 0) failed = true;
        if (runner.tally.invalid_accepted > 0) failed = true;
        if (runner.tally.encoder.failed > 0) failed = true;
        if (runner.tally.round_trip.failed > 0) failed = true;
        if (runner.tally.layout.failed > 0) failed = true;
    }

    if (failed) return 1;
    return 0;
}

fn records_equal(documents: Documents) bool {
    assert(documents.left.node_count > 0);
    assert(documents.right.node_count > 0);

    const left = documents.left.nodes[0..documents.left.node_count];
    const right = documents.right.nodes[0..documents.right.node_count];
    if (left.len != right.len) return false;

    for (left, right, 0..) |*one, *two, index| {
        var flags_one = one.flags;
        var flags_two = two.flags;

        flags_one.owner = .none;
        flags_two.owner = .none;

        if (flags_one != flags_two) return false;
        if (one.kind != two.kind) return false;
        if (one.parent != two.parent) return false;
        if (one.child_first != two.child_first) return false;
        if (one.child_last != two.child_last) return false;
        if (one.sibling_next != two.sibling_next) return false;
        if (one.count != two.count) return false;
        if (one.section != two.section) return false;
        if (!std.mem.eql(u8, one.key, two.key)) return false;
        if (!payload_equal(documents, @intCast(index))) return false;
    }

    return true;
}

fn payload_equal(documents: Documents, index: u32) bool {
    assert(index < documents.left.node_count);
    assert(index < documents.right.node_count);

    const one = &documents.left.nodes[index];
    const two = &documents.right.nodes[index];

    assert(one.kind == two.kind);
    assert(one.count == two.count);

    return switch (one.kind) {
        .array, .table => true,
        .boolean => one.payload.boolean == two.payload.boolean,
        .datetime => std.meta.eql(one.payload.datetime, two.payload.datetime),
        .float => @as(u64, @bitCast(one.payload.float)) == @as(u64, @bitCast(two.payload.float)),
        .integer => one.payload.integer == two.payload.integer,
        .string => std.mem.eql(u8, one.payload.string, two.payload.string),
    };
}

fn usage() u8 {
    assert(usage_text.len > 0);
    assert(usage_text[usage_text.len - 1] == '\n');

    std.debug.print("{s}", .{usage_text});

    return 2;
}

fn file_write(io: std.Io, directory: std.Io.Dir, file: FileWrite) !void {
    assert(file.name.len > 0);
    assert(file.data.len <= output_bytes_max);
    assert(directory.handle != std.Io.Dir.cwd().handle);

    try directory.writeFile(io, .{
        .sub_path = file.name,
        .data = file.data,
        .flags = .{
            .exclusive = false,
            .lock = .none,
            .lock_nonblocking = false,
            .permissions = .default_file,
            .read = false,
            .resolve_beneath = false,
            .truncate = true,
        },
    });
}

fn tables_only(items: []const std.json.Value) bool {
    assert(items.len < pair_count_max);

    if (items.len == 0) return false;

    for (items) |*item| {
        if (item.* != .object) return false;
        if (leaf_of(item) != null) return false;
    }

    return true;
}

fn leaf_content(leaf: *const Leaf) !Content {
    assert(leaf.kind.len > 0);
    assert(leaf.value.len <= file_bytes_max);

    const kind = leaf_kinds.get(leaf.kind) orelse return error.LeafInvalid;

    return switch (kind) {
        .boolean => .{ .boolean = std.mem.eql(u8, leaf.value, "true") },
        .datetime => .{ .datetime = rfc3339_parse(leaf.value) orelse return error.LeafInvalid },
        .float => .{ .float = try std.fmt.parseFloat(f64, leaf.value) },
        .integer => .{ .integer = try std.fmt.parseInt(i64, leaf.value, 10) },
        .string => .{ .string = leaf.value },
        .array, .table => error.LeafInvalid,
    };
}

fn leaf_of(value: *const std.json.Value) ?Leaf {
    assert(value.* != .null);

    const object = switch (value.*) {
        .object => |object| object,
        else => return null,
    };

    if (object.count() != 2) return null;

    const kind = object.get("type") orelse return null;
    const text = object.get("value") orelse return null;

    if (kind != .string) return null;
    if (text != .string) return null;
    return .{ .kind = kind.string, .value = text.string };
}

fn leaf_matches(document: *const Document, node: toml.Node, leaf: *const Leaf) bool {
    assert(@backingInt(node) < document.document.node_count);
    assert(leaf.kind.len > 0);

    const kind = document.kind_of(node);
    const expected = leaf_kinds.get(leaf.kind) orelse return mismatch(leaf.kind, node);
    if (kind != expected) return mismatch(leaf.kind, node);

    return switch (kind) {
        .boolean => document.boolean_of(node).? == std.mem.eql(u8, leaf.value, "true"),
        .datetime => datetime_matches(document, node, leaf),
        .float => float_matches(document, node, leaf),
        .integer => integer_matches(document, node, leaf),
        .string => text_matches(document, node, leaf),
        .array, .table => unreachable,
    };
}

fn text_matches(document: *const Document, node: toml.Node, leaf: *const Leaf) bool {
    assert(document.kind_of(node) == .string);
    assert(leaf.value.len <= file_bytes_max);

    const actual = document.string_of(node).?;
    if (std.mem.eql(u8, actual, leaf.value)) return true;

    std.debug.print("string differs: got {f} expected {f}\n", .{
        std.zig.fmtString(actual),
        std.zig.fmtString(leaf.value),
    });

    return false;
}

fn integer_matches(document: *const Document, node: toml.Node, leaf: *const Leaf) bool {
    assert(document.kind_of(node) == .integer);
    assert(leaf.value.len > 0);

    const expected = std.fmt.parseInt(i64, leaf.value, 10) catch return false;
    return document.integer_of(node).? == expected;
}

fn float_matches(document: *const Document, node: toml.Node, leaf: *const Leaf) bool {
    assert(document.kind_of(node) == .float);
    assert(leaf.value.len > 0);

    const actual = document.float_of(node).?;
    const expected = std.fmt.parseFloat(f64, leaf.value) catch return false;
    if (std.math.isNan(expected)) return std.math.isNan(actual);
    if (actual != expected) return false;
    return std.math.signbit(actual) == std.math.signbit(expected);
}

fn datetime_matches(document: *const Document, node: toml.Node, leaf: *const Leaf) bool {
    assert(document.kind_of(node) == .datetime);
    assert(leaf.value.len > 0);

    const expected = rfc3339_parse(leaf.value) orelse return mismatch(leaf.value, node);
    const kind = datetime_kinds.get(leaf.kind) orelse return mismatch(leaf.kind, node);
    if (expected.kind != kind) return mismatch(leaf.kind, node);

    var actual = document.datetime_of(node).?;

    actual.spelling = expected.spelling;

    if (std.meta.eql(actual, expected)) return true;

    std.debug.print("datetime differs: got {f} expected {s}\n", .{ actual, leaf.value });

    return false;
}

fn rfc3339_parse(text: []const u8) ?toml.Datetime {
    assert(text.len > 0);
    assert(text.len <= file_bytes_max);

    var result: toml.Datetime = .{
        .day = 0,
        .hour = 0,
        .kind = .time_local,
        .minute = 0,
        .month = 0,
        .nanosecond = 0,
        .offset_minutes = 0,
        .second = 0,
        .spelling = .canonical,
        .year = 0,
    };

    var rest = text;

    if (date_shaped(rest)) {
        if (rest[7] != '-') return null;

        result.year = @intCast(digits_of(rest[0..4]) orelse return null);
        result.month = @intCast(digits_of(rest[5..7]) orelse return null);
        result.day = @intCast(digits_of(rest[8..10]) orelse return null);
        result.kind = .date_local;

        if (rest.len == 10) return result;

        switch (rest[10]) {
            'T', 't', ' ' => {},
            else => return null,
        }

        rest = rest[11..];
        result.kind = .datetime_local;
    }

    rest = rfc3339_time(rest, &result) orelse return null;

    if (rest.len == 0) return result;
    if (result.kind != .datetime_local) return null;

    result.offset_minutes = rfc3339_offset(rest) orelse return null;
    result.kind = .datetime_offset;

    return result;
}

fn rfc3339_time(text: []const u8, result: *toml.Datetime) ?[]const u8 {
    assert(text.len <= file_bytes_max);
    assert(result.hour == 0);

    if (text.len < 8) return null;
    if (text[2] != ':') return null;
    if (text[5] != ':') return null;

    result.hour = @intCast(digits_of(text[0..2]) orelse return null);
    result.minute = @intCast(digits_of(text[3..5]) orelse return null);
    result.second = @intCast(digits_of(text[6..8]) orelse return null);

    if (text.len == 8) return text[8..];
    if (text[8] != '.') return text[8..];

    var digit_count: u32 = 0;

    for (text[9..]) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        digit_count += 1;
    }

    if (digit_count == 0) return null;

    const kept = text[9..][0..@min(digit_count, fraction_digit_count_max)];
    const value = digits_of(kept) orelse return null;
    const scale = std.math.pow(u32, 10, fraction_digit_count_max - @as(u32, @intCast(kept.len)));

    result.nanosecond = value * scale;

    return text[9 + digit_count ..];
}

fn rfc3339_offset(text: []const u8) ?i16 {
    assert(text.len > 0);
    assert(text.len <= file_bytes_max);

    if (text.len == 1) {
        if (text[0] == 'Z') return 0;
        if (text[0] == 'z') return 0;
        return null;
    }

    if (text.len != 6) return null;
    if (text[3] != ':') return null;

    const sign: i16 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };

    const hours = digits_of(text[1..3]) orelse return null;
    const minutes = digits_of(text[4..6]) orelse return null;
    const result = sign * @as(i16, @intCast(hours * 60 + minutes));

    assert(@abs(result) <= 99 * 60 + 99);

    return result;
}

fn date_shaped(text: []const u8) bool {
    assert(text.len > 0);
    assert(text.len <= file_bytes_max);

    if (text.len < 10) return false;
    return text[4] == '-';
}

fn digits_of(text: []const u8) ?u32 {
    assert(text.len > 0);
    assert(text.len <= fraction_digit_count_max);

    var value: u32 = 0;

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;

        value = value * 10 + (byte - '0');
    }

    return value;
}

fn mismatch(what: []const u8, node: toml.Node) bool {
    assert(what.len > 0);
    assert(@backingInt(node) < std.math.maxInt(u32));

    std.debug.print("kind differs: expected {s} at node {d}\n", .{ what, @backingInt(node) });

    return false;
}
