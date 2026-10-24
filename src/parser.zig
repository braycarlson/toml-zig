const std = @import("std");

const datetime_module = @import("datetime.zig");
const document_module = @import("document.zig");
const hash_index = @import("hash_index.zig");
const scalar = @import("scalar.zig");
const storage_module = @import("storage.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const Error = Document.Error;
const Kind = document_module.Kind;
const Version = document_module.Version;

const byte_order_mark = "\xef\xbb\xbf";
const none = storage_module.none;
const root_index: u32 = 0;

const flags_empty: storage_module.Flags = .{
    .array_of_tables = false,
    .closed = false,
    .detached = false,
    .edited = false,
    .explicit = false,
    .indexed = false,
    .owner = .none,
};

comptime {
    assert(root_index < none);
    assert(byte_order_mark.len == 3);
}

const FrameKind = enum {
    array,
    inline_table,
};

const FrameState = enum {
    close_or_value,
    separator,
    value_required,
};

const Frame = struct {
    kind: FrameKind,
    node: u32,
    state: FrameState,
};

const KeyMode = enum {
    inline_table,
    section,
};

const Lines = enum {
    discarded,
    kept,
};

const Owned = struct {
    node: u32,
    owner: storage_module.Owner,
};

const owned_none: Owned = .{ .node = none, .owner = .none };

const Refinable = enum {
    array_invalid,
    equals_missing,
    inline_table_invalid,
    key_invalid,
    value_missing,
};

const Segment = struct {
    mark: u32,
    start: u32,
    text: []const u8,
};

const Scalar = union(enum) {
    boolean: bool,
    datetime: datetime_module.Datetime,
    float: f64,
    integer: i64,
    string: []const u8,
};

const Stack = struct {
    depth: u32,
    frames: [document_module.depth_max]Frame,

    fn top(stack: *Stack) *Frame {
        assert(stack.depth > 0);
        assert(stack.depth <= document_module.depth_max);

        return &stack.frames[stack.depth - 1];
    }
};

pub fn parse(
    document: *Document,
    storage: storage_module.Storage,
    source: []const u8,
    options: Document.Options,
) Error!void {
    assert(source.len <= document_module.source_bytes_max);
    assert(std.math.isPowerOfTwo(storage.buckets.len));
    assert(storage.buckets.len >= storage.nodes.len * 2);
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    document.* = .{
        .bucket_count = 0,
        .buckets = storage.buckets,
        .diagnostic = document_module.position_none,
        .hash_seed = storage.hash_seed,
        .indexed_count = 0,
        .indexed_first = none,
        .line_count = 0,
        .lines = storage.lines,
        .node_count = 0,
        .node_count_parsed = 0,
        .nodes = storage.nodes,
        .source = source,
        .text = storage.text,
        .text_used = 0,
    };

    var parser: Parser = .{
        .document = document,
        .error_index = 0,
        .index = 0,
        .section = 0,
        .source = source,
        .stack = .{ .depth = 0, .frames = undefined },
        .table = root_index,
        .version = options.version,
    };

    parser.document_begin(storage.lines.len > 0) catch |err| {
        document.diagnostic = scalar.position_of(source, parser.error_index);

        return err;
    };

    document.node_count_parsed = document.node_count;

    assert(document.node_count > 0);
    assert(document.node_count <= source.len + 1);
    assert(document.line_count < document.node_count);
}

const Parser = struct {
    document: *Document,
    error_index: u32,
    index: u32,
    section: u32,
    source: []const u8,
    stack: Stack,
    table: u32,
    version: Version,

    fn fail(parser: *Parser, err: Error) Error {
        assert(parser.index <= parser.source.len);
        assert(@errorName(err).len > 0);

        parser.error_index = parser.index;

        return err;
    }

    fn fail_at(parser: *Parser, err: Error, index: u32) Error {
        assert(index <= parser.source.len);
        assert(@errorName(err).len > 0);

        parser.error_index = index;

        return err;
    }

    fn fail_or_end(parser: *Parser, refinable: Refinable) Error {
        @branchHint(.cold);

        assert(parser.index <= parser.source.len);
        assert(parser.stack.depth <= document_module.depth_max);

        const err: Error = switch (refinable) {
            .array_invalid => error.ArrayInvalid,
            .equals_missing => error.EqualsMissing,
            .inline_table_invalid => error.InlineTableInvalid,
            .key_invalid => error.KeyInvalid,
            .value_missing => error.ValueMissing,
        };

        if (parser.index < parser.source.len) return parser.fail(err);
        if (parser.stack.depth == 0) return parser.fail(err);

        const anchor = parser.anchor_of();
        const end = scalar.token_end_after(parser.source[0..parser.index], anchor);

        const unterminated: Error = switch (parser.stack.top().kind) {
            .array => error.ArrayUnterminated,
            .inline_table => error.InlineTableUnterminated,
        };

        return parser.fail_at(unterminated, end);
    }

    fn anchor_of(parser: *const Parser) u32 {
        @branchHint(.cold);

        assert(parser.stack.depth > 0);
        assert(parser.document.node_count <= parser.document.nodes.len);

        var current = parser.stack.frames[parser.stack.depth - 1].node;

        for (0..parser.document.node_count) |_| {
            const record = &parser.document.nodes[current];
            if (document_module.key_offset_of(parser.document, record)) |offset| return offset;

            assert(record.parent < current);

            current = record.parent;
        }

        unreachable;
    }

    fn table_unterminated(parser: *Parser) Error {
        @branchHint(.cold);

        assert(parser.index <= parser.source.len);
        assert(parser.stack.depth == 0);

        const kept = std.mem.trimEnd(u8, parser.source[0..parser.index], " \t");
        return parser.fail_at(error.TableUnterminated, @intCast(kept.len));
    }

    fn document_begin(parser: *Parser, kept: bool) Error!void {
        assert(parser.index == 0);
        assert(parser.document.node_count == 0);

        if (!std.unicode.utf8ValidateSlice(parser.source)) {
            return parser.fail_at(error.Utf8Invalid, scalar.utf8_invalid_index(parser.source));
        }

        const root = try parser.record_create(none, parser.source[0..0], .table);

        assert(root == root_index);

        parser.document.nodes[root].flags.explicit = true;

        if (std.mem.startsWith(u8, parser.source, byte_order_mark)) parser.index = 3;

        if (kept) return @call(.never_inline, run, .{ parser, .kept });
        return parser.run(.discarded);
    }

    fn run(parser: *Parser, comptime lines: Lines) Error!void {
        assert(parser.index <= byte_order_mark.len);
        assert(parser.document.node_count == 1);

        for (0..parser.source.len + 1) |_| {
            if (parser.index == parser.source.len) return;

            if (comptime lines == .kept) {
                try parser.expression_kept();
            } else {
                try parser.expression();
            }
        }

        unreachable;
    }

    fn expression(parser: *Parser) Error!void {
        assert(parser.index < parser.source.len);
        assert(parser.table < parser.document.node_count);

        parser.whitespace_skip();

        switch (parser.peek()) {
            '[' => try parser.header(),
            '#', '\n', '\r' => {},
            else => {
                if (parser.index < parser.source.len) _ = try parser.keyval_top();
            },
        }

        parser.whitespace_skip();

        try parser.comment_skip();
        try parser.line_end();
    }

    fn expression_kept(parser: *Parser) Error!void {
        assert(parser.index < parser.source.len);
        assert(parser.table < parser.document.node_count);

        const start = parser.index;

        parser.whitespace_skip();

        const owned: Owned = switch (parser.peek()) {
            '[' => header: {
                try parser.header();

                break :header .{ .node = parser.table, .owner = .header };
            },
            '#', '\n', '\r' => owned_none,
            else => pair: {
                if (parser.index == parser.source.len) break :pair owned_none;

                break :pair .{ .node = try parser.keyval_top(), .owner = .pair };
            },
        };

        parser.whitespace_skip();

        try parser.comment_skip();
        try parser.line_end();

        if (owned.owner != .none) try parser.line_record(start, owned);
    }

    fn line_record(parser: *Parser, start: u32, owned: Owned) Error!void {
        assert(start < parser.index);
        assert(owned.node < parser.document.node_count);
        assert(owned.owner != .none);

        const document = parser.document;

        if (document.line_count == document.lines.len) {
            return parser.fail_at(error.LinesExhausted, start);
        }

        document.lines[document.line_count] = .{
            .end = parser.index,
            .node = owned.node,
            .start = start,
        };

        document.line_count += 1;
        document.nodes[owned.node].flags.owner = owned.owner;
    }

    inline fn header(parser: *Parser) Error!void {
        assert(parser.peek() == '[');
        assert(parser.index < parser.source.len);

        parser.index += 1;

        const array_of_tables = parser.peek() == '[';

        if (array_of_tables) parser.index += 1;

        parser.section += 1;

        parser.whitespace_skip();
        parser.table = try parser.header_key(array_of_tables);

        parser.whitespace_skip();

        try parser.header_close();

        if (array_of_tables) try parser.header_close();
    }

    inline fn header_close(parser: *Parser) Error!void {
        assert(parser.index <= parser.source.len);
        assert(parser.stack.depth == 0);

        if (parser.peek() != ']') return parser.header_fail();

        parser.index += 1;
    }

    fn header_fail(parser: *Parser) Error {
        @branchHint(.cold);

        assert(parser.peek() != ']');
        assert(parser.stack.depth == 0);

        switch (parser.peek()) {
            '\n', '\r', '#' => return parser.table_unterminated(),
            else => {
                if (parser.index < parser.source.len) return parser.fail(error.TableInvalid);
                return parser.table_unterminated();
            },
        }
    }

    inline fn header_key(parser: *Parser, array_of_tables: bool) Error!u32 {
        assert(parser.index <= parser.source.len);
        assert(parser.document.node_count > 0);

        var current: u32 = root_index;

        for (0..document_module.key_segment_count_max) |_| {
            const segment = try parser.key_segment();

            parser.whitespace_skip();

            if (parser.peek() != '.') {
                if (array_of_tables) return parser.table_append(current, &segment);
                return parser.table_declare(current, &segment);
            }

            parser.index += 1;

            parser.whitespace_skip();
            current = try parser.header_descend(current, &segment);
        }

        return parser.fail(error.DepthExceeded);
    }

    fn header_descend(parser: *Parser, current: u32, segment: *const Segment) Error!u32 {
        assert(current < parser.document.node_count);
        assert(parser.document.nodes[current].kind == .table);

        const document = parser.document;

        const found = hash_index.member_find(document, current, segment.text) orelse {
            return parser.record_create(current, segment.text, .table);
        };

        document.text_used = segment.mark;

        const record = &document.nodes[found];

        switch (record.kind) {
            .table => {
                if (record.flags.closed) {
                    return parser.fail_at(error.TableRedefined, segment.start);
                }

                return found;
            },
            .array => {
                if (!record.flags.array_of_tables) {
                    return parser.fail_at(error.TableRedefined, segment.start);
                }

                assert(record.child_last != none);

                return record.child_last;
            },
            else => return parser.fail_at(error.KeyDuplicate, segment.start),
        }
    }

    inline fn table_declare(parser: *Parser, current: u32, segment: *const Segment) Error!u32 {
        assert(current < parser.document.node_count);
        assert(parser.document.nodes[current].kind == .table);

        const document = parser.document;

        const found = hash_index.member_find(document, current, segment.text) orelse {
            const created = try parser.record_create(current, segment.text, .table);

            document.nodes[created].flags.explicit = true;

            return created;
        };

        document.text_used = segment.mark;

        const record = &document.nodes[found];

        switch (record.kind) {
            .table => {},
            .array => return parser.fail_at(error.TableRedefined, segment.start),
            else => return parser.fail_at(error.KeyDuplicate, segment.start),
        }

        if (record.flags.closed) return parser.fail_at(error.TableRedefined, segment.start);
        if (record.flags.explicit) return parser.fail_at(error.TableRedefined, segment.start);
        if (record.section != none) return parser.fail_at(error.TableRedefined, segment.start);

        record.flags.explicit = true;

        return found;
    }

    inline fn table_append(parser: *Parser, current: u32, segment: *const Segment) Error!u32 {
        assert(current < parser.document.node_count);
        assert(parser.document.nodes[current].kind == .table);

        const document = parser.document;

        const found = hash_index.member_find(document, current, segment.text) orelse {
            const created = try parser.record_create(current, segment.text, .array);

            document.nodes[created].flags.array_of_tables = true;

            const element_key = parser.source[segment.start..segment.start];
            return parser.record_create(created, element_key, .table);
        };

        document.text_used = segment.mark;

        const record = &document.nodes[found];

        switch (record.kind) {
            .array => {
                if (!record.flags.array_of_tables) {
                    return parser.fail_at(error.TableRedefined, segment.start);
                }

                const element_key = parser.source[segment.start..segment.start];
                return parser.record_create(found, element_key, .table);
            },
            .table => return parser.fail_at(error.TableRedefined, segment.start),
            else => return parser.fail_at(error.KeyDuplicate, segment.start),
        }
    }

    inline fn keyval_top(parser: *Parser) Error!u32 {
        assert(parser.index < parser.source.len);
        assert(parser.table < parser.document.node_count);

        const target = try parser.keyval_key(parser.table, .section);

        try parser.value_parse(target);

        return target;
    }

    fn keyval_key(parser: *Parser, base: u32, mode: KeyMode) Error!u32 {
        assert(base < parser.document.node_count);
        assert(parser.document.nodes[base].kind == .table);

        var current = base;

        for (0..document_module.key_segment_count_max) |_| {
            const segment = try parser.key_segment();

            parser.whitespace_skip();

            if (parser.peek() == '.') {
                parser.index += 1;

                parser.whitespace_skip();
                current = try parser.dotted_descend(current, &segment, mode);

                continue;
            }

            if (parser.peek() != '=') return parser.fail_or_end(.equals_missing);

            parser.index += 1;

            parser.whitespace_skip();

            if (hash_index.member_find(parser.document, current, segment.text) != null) {
                return parser.fail_at(error.KeyDuplicate, segment.start);
            }

            return parser.record_create(current, segment.text, .string);
        }

        return parser.fail(error.DepthExceeded);
    }

    fn dotted_descend(
        parser: *Parser,
        current: u32,
        segment: *const Segment,
        mode: KeyMode,
    ) Error!u32 {
        assert(current < parser.document.node_count);
        assert(parser.document.nodes[current].kind == .table);

        const document = parser.document;

        const found = hash_index.member_find(document, current, segment.text) orelse {
            const created = try parser.record_create(current, segment.text, .table);

            document.nodes[created].section = parser.section;

            return created;
        };

        document.text_used = segment.mark;

        const record = &document.nodes[found];

        switch (record.kind) {
            .table => {},
            .array => return parser.fail_at(error.TableRedefined, segment.start),
            else => return parser.fail_at(error.KeyDuplicate, segment.start),
        }

        if (record.flags.closed) return parser.fail_at(error.TableRedefined, segment.start);
        if (mode == .inline_table) return found;
        if (record.flags.explicit) return parser.fail_at(error.TableRedefined, segment.start);

        if (record.section != none) {
            if (record.section < parser.section) {
                return parser.fail_at(error.TableRedefined, segment.start);
            }
        }

        record.section = parser.section;

        return found;
    }

    fn key_segment(parser: *Parser) Error!Segment {
        assert(parser.index <= parser.source.len);
        assert(parser.document.text_used <= parser.document.text.len);

        const start = parser.index;
        const mark = parser.document.text_used;

        const text = switch (parser.peek()) {
            '"' => try parser.string_basic(),
            '\'' => try parser.string_literal(),
            else => try parser.key_bare(),
        };

        return .{ .mark = mark, .start = start, .text = text };
    }

    fn key_bare(parser: *Parser) Error![]const u8 {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        const start = parser.index;
        var index = scalar.bare_skip(parser.source, start);

        for (parser.source[index..]) |byte| {
            switch (byte) {
                'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => index += 1,
                else => break,
            }
        }

        parser.index = index;

        if (parser.index == start) return parser.fail_or_end(.key_invalid);
        return parser.source[start..parser.index];
    }

    inline fn value_parse(parser: *Parser, target: u32) Error!void {
        assert(target < parser.document.node_count);
        assert(parser.index <= parser.source.len);
        assert(parser.stack.depth == 0);

        const stack = &parser.stack;

        try parser.value_begin(target, stack);

        for (0..parser.source.len + 1) |_| {
            if (stack.depth == 0) return;

            switch (stack.top().kind) {
                .array => try parser.array_step(stack),
                .inline_table => try parser.inline_step(stack),
            }
        }

        unreachable;
    }

    fn value_begin(parser: *Parser, target: u32, stack: *Stack) align(64) Error!void {
        assert(target < parser.document.node_count);
        assert(stack.depth <= document_module.depth_max);

        const record = &parser.document.nodes[target];

        switch (parser.peek()) {
            '[' => {
                record.kind = .array;

                try parser.frame_push(stack, .{
                    .kind = .array,
                    .node = target,
                    .state = .close_or_value,
                });
            },
            '{' => {
                record.kind = .table;

                try parser.frame_push(stack, .{
                    .kind = .inline_table,
                    .node = target,
                    .state = .close_or_value,
                });
            },
            else => try parser.scalar_parse(target),
        }
    }

    fn frame_push(parser: *Parser, stack: *Stack, frame: Frame) Error!void {
        assert(stack.depth <= document_module.depth_max);
        assert(frame.node < parser.document.node_count);

        if (stack.depth == document_module.depth_max) return parser.fail(error.DepthExceeded);

        stack.frames[stack.depth] = frame;
        stack.depth += 1;
        parser.index += 1;
    }

    fn container_close(parser: *Parser, stack: *Stack) void {
        assert(stack.depth > 0);
        assert(parser.index < parser.source.len);

        const frame = stack.top();

        parser.document.nodes[frame.node].flags.closed = true;
        parser.index += 1;
        stack.depth -= 1;
    }

    inline fn array_step(parser: *Parser, stack: *Stack) Error!void {
        assert(stack.depth > 0);
        assert(stack.top().kind == .array);

        const frame = stack.top();

        try parser.array_gap_skip();

        const byte = parser.peek();

        switch (frame.state) {
            .close_or_value => {
                if (byte == ']') return parser.container_close(stack);

                frame.state = .separator;

                const key = parser.source[parser.index..parser.index];
                const element = try parser.record_create(frame.node, key, .string);

                try parser.value_begin(element, stack);
            },
            .separator => {
                if (byte == ']') return parser.container_close(stack);
                if (byte != ',') return parser.fail_or_end(.array_invalid);

                parser.index += 1;
                frame.state = .close_or_value;
            },
            .value_required => unreachable,
        }
    }

    inline fn inline_step(parser: *Parser, stack: *Stack) Error!void {
        assert(stack.depth > 0);
        assert(stack.top().kind == .inline_table);

        const frame = stack.top();

        parser.whitespace_skip();

        const byte = switch (parser.peek()) {
            '#', '\n', '\r' => try parser.inline_gap_skip(),
            else => |next| next,
        };

        switch (frame.state) {
            .close_or_value => {
                if (byte == '}') return parser.container_close(stack);

                try parser.inline_keyval(stack);
            },
            .separator => {
                if (byte == '}') return parser.container_close(stack);
                if (byte != ',') return parser.fail_or_end(.inline_table_invalid);

                parser.index += 1;
                frame.state = .value_required;
            },
            .value_required => {
                if (byte == '}') return parser.comma_close(stack);

                try parser.inline_keyval(stack);
            },
        }
    }

    fn inline_gap_skip(parser: *Parser) Error!u8 {
        assert(parser.index < parser.source.len);
        assert(parser.stack.depth > 0);

        if (parser.version == .v1_1) try parser.array_gap_skip();

        return parser.peek();
    }

    fn comma_close(parser: *Parser, stack: *Stack) Error!void {
        assert(stack.depth > 0);
        assert(stack.top().state == .value_required);

        if (parser.version == .v1_0) return parser.fail(error.InlineTableInvalid);

        parser.container_close(stack);
    }

    fn inline_keyval(parser: *Parser, stack: *Stack) Error!void {
        assert(stack.depth > 0);
        assert(stack.top().kind == .inline_table);

        const frame = stack.top();

        frame.state = .separator;

        const target = try parser.keyval_key(frame.node, .inline_table);

        try parser.value_begin(target, stack);
    }

    fn array_gap_skip(parser: *Parser) align(64) Error!void {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        for (0..parser.source.len + 1) |_| {
            parser.whitespace_skip();

            switch (parser.peek()) {
                '#' => try parser.comment_skip(),
                '\n' => parser.index += 1,
                '\r' => try parser.crlf_skip(),
                else => return,
            }
        }

        unreachable;
    }

    fn scalar_parse(parser: *Parser, target: u32) Error!void {
        assert(target < parser.document.node_count);
        assert(parser.index <= parser.source.len);

        const value = try parser.scalar_read();
        const record = &parser.document.nodes[target];

        switch (value) {
            .boolean => |boolean| {
                record.kind = .boolean;
                record.payload = .{ .boolean = boolean };
            },
            .datetime => |datetime| {
                record.kind = .datetime;
                record.payload = .{ .datetime = datetime };
            },
            .float => |float| {
                record.kind = .float;
                record.payload = .{ .float = float };
            },
            .integer => |integer| {
                record.kind = .integer;
                record.payload = .{ .integer = integer };
            },
            .string => |text| {
                record.kind = .string;
                record.payload = .{ .string = text };
            },
        }
    }

    fn scalar_read(parser: *Parser) Error!Scalar {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        const rest = parser.source[parser.index..];

        switch (parser.peek()) {
            '"' => {
                if (std.mem.startsWith(u8, rest, "\"\"\"")) {
                    return .{ .string = try parser.string_basic_multiline() };
                }

                return .{ .string = try parser.string_basic() };
            },
            '\'' => {
                if (std.mem.startsWith(u8, rest, "'''")) {
                    return .{ .string = try parser.string_literal_multiline() };
                }

                return .{ .string = try parser.string_literal() };
            },
            't' => return .{ .boolean = try parser.keyword_read("true") },
            'f' => return .{ .boolean = try parser.keyword_read("false") },
            '+', '-', '0'...'9', 'i', 'n' => return parser.number_or_datetime(),
            else => return parser.value_fail(),
        }
    }

    fn value_fail(parser: *Parser) Error {
        @branchHint(.cold);

        assert(parser.index <= parser.source.len);
        assert(parser.stack.depth <= document_module.depth_max);

        switch (parser.peek()) {
            '#', '\n', '\r' => return parser.fail(error.ValueMissing),
            else => {
                if (parser.index < parser.source.len) return parser.fail(error.ValueInvalid);
                return parser.fail_or_end(.value_missing);
            },
        }
    }

    fn keyword_read(parser: *Parser, keyword: []const u8) Error!bool {
        assert(keyword.len >= 4);
        assert(parser.index < parser.source.len);

        if (!std.mem.startsWith(u8, parser.source[parser.index..], keyword)) {
            return parser.fail(error.ValueInvalid);
        }

        parser.index += @intCast(keyword.len);

        return keyword.len == 4;
    }

    fn number_or_datetime(parser: *Parser) Error!Scalar {
        assert(parser.index < parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        const start = parser.index;
        const end = scalar.value_end(parser.source, start);
        const token = parser.source[start..end];

        if (scalar.datetime_shaped(token)) {
            const datetime = datetime_module.parse(token, parser.version) catch {
                return parser.fail_at(error.DatetimeInvalid, start);
            };

            parser.index = end;

            return .{ .datetime = datetime };
        }

        const number = scalar.number_parse(token) catch {
            return parser.fail_at(error.NumberInvalid, start);
        };

        parser.index = end;

        return switch (number) {
            .float => |float| .{ .float = float },
            .integer => |integer| .{ .integer = integer },
        };
    }

    fn string_basic(parser: *Parser) Error![]const u8 {
        assert(parser.peek() == '"');
        assert(parser.index < parser.source.len);

        var scan: scalar.StringScan = undefined;

        scalar.basic_scan(parser.source, &parser.index, &scan) catch |err| {
            try parser.escapes_check(&scan);

            return parser.fail(err);
        };

        const content = parser.source[scan.content_start..scan.content_end];
        if (!scan.processed) return content;

        try parser.escapes_check(&scan);

        const target = try parser.text_reserve(@intCast(content.len));
        const decoded = scalar.basic_decode(content, target);

        parser.document.text_used -= @intCast(target.len - decoded.len);

        return decoded;
    }

    fn string_literal(parser: *Parser) Error![]const u8 {
        assert(parser.peek() == '\'');
        assert(parser.index < parser.source.len);

        var scan: scalar.StringScan = undefined;

        scalar.literal_scan(parser.source, &parser.index, &scan) catch |err| {
            return parser.fail(err);
        };

        assert(!scan.processed);

        return parser.source[scan.content_start..scan.content_end];
    }

    fn string_basic_multiline(parser: *Parser) Error![]const u8 {
        assert(parser.peek() == '"');
        assert(parser.index < parser.source.len);

        var scan: scalar.StringScan = undefined;

        scalar.basic_multiline_scan(parser.source, &parser.index, &scan) catch |err| {
            try parser.escapes_check(&scan);

            return parser.fail(err);
        };

        const content = parser.source[scan.content_start..scan.content_end];
        if (!scan.processed) return content;

        try parser.escapes_check(&scan);

        const target = try parser.text_reserve(@intCast(content.len));
        const decoded = scalar.basic_multiline_decode(content, target);

        parser.document.text_used -= @intCast(target.len - decoded.len);

        return decoded;
    }

    fn escapes_check(parser: *Parser, scan: *const scalar.StringScan) Error!void {
        assert(scan.content_start <= parser.index);
        assert(scan.content_end <= parser.index);

        const extended = scan.extended orelse return;
        if (parser.version == .v1_0) return parser.fail_at(error.EscapeInvalid, extended);
    }

    fn string_literal_multiline(parser: *Parser) Error![]const u8 {
        assert(parser.peek() == '\'');
        assert(parser.index < parser.source.len);

        var scan: scalar.StringScan = undefined;

        scalar.literal_multiline_scan(parser.source, &parser.index, &scan) catch |err| {
            return parser.fail(err);
        };

        const content = parser.source[scan.content_start..scan.content_end];
        if (!scan.processed) return content;

        const target = try parser.text_reserve(@intCast(content.len));
        const decoded = scalar.literal_multiline_decode(content, target);

        parser.document.text_used -= @intCast(target.len - decoded.len);

        return decoded;
    }

    fn text_reserve(parser: *Parser, length: u32) Error![]u8 {
        assert(parser.document.text_used <= parser.document.text.len);
        assert(length <= document_module.source_bytes_max);

        const document = parser.document;
        const available = document.text.len - document.text_used;
        if (length > available) return parser.fail(error.TextExhausted);

        const start = document.text_used;

        document.text_used += length;

        return document.text[start..document.text_used];
    }

    fn record_create(parser: *Parser, parent: u32, key: []const u8, kind: Kind) Error!u32 {
        const document = parser.document;

        assert(document.node_count <= document.nodes.len);
        assert(key.len <= document_module.source_bytes_max);

        if (parent == none) assert(kind == .table);
        if (parent != none) assert(parent < document.node_count);

        if (document.node_count == document.nodes.len) return parser.fail(error.NodesExhausted);

        const index = document.node_count;

        document.nodes[index] = .{
            .child_first = none,
            .child_last = none,
            .count = 0,
            .flags = flags_empty,
            .indexed_next = none,
            .key = key,
            .kind = kind,
            .parent = parent,
            .payload = .{ .none = {} },
            .section = none,
            .sibling_next = none,
        };

        document.node_count += 1;

        if (parent != none) {
            hash_index.child_link(document, .{ .child = index, .parent = parent });

            if (document.nodes[parent].kind == .table) hash_index.insert(document, index);
        }

        return index;
    }

    fn whitespace_skip(parser: *Parser) void {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        for (parser.source[parser.index..]) |byte| {
            switch (byte) {
                ' ', '\t' => parser.index += 1,
                else => return,
            }
        }
    }

    fn comment_skip(parser: *Parser) Error!void {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        if (parser.peek() != '#') return;

        parser.index += 1;

        for (0..parser.source.len - parser.index + 1) |_| {
            parser.index = scalar.stop_skip(parser.source, parser.index, scalar.stops_comment);

            if (parser.index == parser.source.len) return;

            switch (parser.source[parser.index]) {
                '\n', '\r' => return,
                0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                    return parser.fail(error.CommentInvalid);
                },
                else => parser.index += 1,
            }
        }

        unreachable;
    }

    fn line_end(parser: *Parser) Error!void {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        switch (parser.peek()) {
            '\n' => parser.index += 1,
            '\r' => try parser.crlf_skip(),
            else => {
                if (parser.index < parser.source.len) {
                    return parser.fail(error.ExpressionInvalid);
                }
            },
        }
    }

    fn crlf_skip(parser: *Parser) Error!void {
        assert(parser.peek() == '\r');
        assert(parser.index < parser.source.len);

        if (parser.index + 1 == parser.source.len) return parser.fail(error.NewlineInvalid);
        if (parser.source[parser.index + 1] != '\n') return parser.fail(error.NewlineInvalid);

        parser.index += 2;
    }

    fn peek(parser: *const Parser) u8 {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= document_module.source_bytes_max);

        if (parser.index == parser.source.len) return 0;
        return parser.source[parser.index];
    }
};
