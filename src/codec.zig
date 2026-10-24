const std = @import("std");

const datetime_module = @import("datetime.zig");
const document_module = @import("document.zig");
const region_module = @import("region.zig");
const scalar = @import("scalar.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Datetime = datetime_module.Datetime;
const Document = document_module.Document;
const Kind = document_module.Kind;
const KindSet = std.EnumSet(Kind);
const Node = document_module.Node;
const Position = document_module.Position;
const Region = region_module.Region;
const Writer = writer_module.Writer;

pub const DecodeError = region_module.Error || MismatchError;

pub const DecodeOptions = struct {
    diagnostic: ?*Position = null,
    unknown_members: UnknownMembers = .ignored,

    pub const UnknownMembers = enum {
        ignored,
        refused,
    };
};

pub const MismatchError = error{
    MemberMissing,
    MemberUnknown,
    Mismatch,
};

const Decoder = struct {
    document: *const Document,
    node: Node,
    region: *Region,
    unknown_members: DecodeOptions.UnknownMembers,
};

const Shape = enum {
    array,
    boolean,
    choice,
    datetime,
    enumeration,
    float,
    integer,
    optional,
    string,
    table,
};

const kind_count = @typeInfo(Kind).@"enum".field_names.len;
const type_depth_max: u32 = 64;

comptime {
    assert(type_depth_max >= 16);
    assert(kind_count == 7);
}

pub fn decode(
    comptime T: type,
    region: *Region,
    document: *const Document,
    node: Node,
    target: *T,
    options: DecodeOptions,
) DecodeError!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(@backingInt(node) < document.node_count);
    assert(region.used <= region.top);

    const used = region.used;
    const top = region.top;

    var decoder: Decoder = .{
        .document = document,
        .node = node,
        .region = region,
        .unknown_members = options.unknown_members,
    };

    value_decode(T, 0, &decoder, node, target) catch |err| {
        region.used = used;
        region.top = top;

        if (options.diagnostic) |diagnostic| diagnostic.* = failure_position(&decoder, err);

        return err;
    };

    assert(region.top == top);
    assert(region.used >= used);
}

pub fn encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(shape_of(T) == .table);
    assert(writer.depth == 0);
    assert(writer.state == .line);

    try table_encode(T, 0, &.{}, writer, value);

    assert(writer.depth == 0);
}

fn shape_of(comptime T: type) Shape {
    if (T == Datetime) return .datetime;

    switch (@typeInfo(T)) {
        .bool => return .boolean,
        .@"enum" => return .enumeration,
        .float => return .float,
        .int => return .integer,
        .optional => return .optional,
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("the pointer type " ++ @typeName(T) ++ " is not a slice");
            }

            if (!pointer.attrs.@"const") {
                @compileError("the slice type " ++ @typeName(T) ++ " is not const");
            }

            if (pointer.child == u8) return .string;
            return .array;
        },
        .@"struct" => return .table,
        .@"union" => |choice| {
            if (choice.tag_type == null) {
                @compileError("the union " ++ @typeName(T) ++ " has no tag");
            }

            return .choice;
        },
        else => @compileError("the type " ++ @typeName(T) ++ " has no TOML shape"),
    }
}

fn element_of(comptime T: type) type {
    comptime assert(shape_of(T) == .array);

    const Element = @typeInfo(T).pointer.child;

    if (shape_of(Element) == .optional) {
        @compileError("the slice type " ++ @typeName(T) ++ " holds optionals, which TOML lacks");
    }

    return Element;
}

fn names_check(comptime T: type) void {
    if (!@hasDecl(T, "toml")) return;

    for (@typeInfo(@TypeOf(T.toml)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) {
            @compileError("the type " ++ @typeName(T) ++ " names " ++ name ++
                " in its toml declaration, which is not one of its fields");
        }
    }
}

fn name_of(comptime T: type, comptime field_name: []const u8) []const u8 {
    comptime assert(@hasField(T, field_name));

    names_check(T);

    if (@hasDecl(T, "toml")) {
        if (@hasField(@TypeOf(T.toml), field_name)) return @field(T.toml, field_name);
    }

    return field_name;
}

fn names_of(comptime T: type) std.StaticStringMap(T) {
    const field_names = @typeInfo(T).@"enum".field_names;

    @setEvalBranchQuota(64 * field_names.len * field_names.len + 1000);

    var entries: [field_names.len]struct { []const u8, T } = undefined;

    for (field_names, 0..) |name, index| entries[index] = .{ name_of(T, name), @field(T, name) };

    const result: std.StaticStringMap(T) = .initComptime(&entries);

    for (entries) |entry| assert(result.get(entry[0]).? == entry[1]);

    return result;
}

fn kinds_of(comptime T: type) KindSet {
    return switch (shape_of(T)) {
        .array => .initOne(.array),
        .boolean => .initOne(.boolean),
        .choice => choice_kinds(T),
        .datetime => .initOne(.datetime),
        .enumeration, .string => .initOne(.string),
        .float => .initOne(.float),
        .integer => .initOne(.integer),
        .optional => @compileError("the union payload " ++ @typeName(T) ++ " is optional"),
        .table => .initOne(.table),
    };
}

fn choice_kinds(comptime T: type) KindSet {
    const table = choice_table(T);

    var result: KindSet = .empty;

    for (table, 0..) |slot, index| {
        if (slot != null) result.insert(@fromBackingInt(index));
    }

    return result;
}

fn choice_table(comptime T: type) [kind_count]?u32 {
    const choice = @typeInfo(T).@"union";

    var table: [kind_count]?u32 = @splat(null);
    var float_index: ?u32 = null;

    for (choice.field_types, choice.field_names, 0..) |Payload, name, index| {
        if (Payload == void) {
            @compileError("the union " ++ @typeName(T) ++ " has the empty variant " ++ name);
        }

        const kinds = kinds_of(Payload);

        if (kinds.contains(.float)) float_index = index;

        for (std.enums.values(Kind)) |kind| {
            if (!kinds.contains(kind)) continue;

            if (table[@backingInt(kind)] != null) {
                @compileError("the union " ++ @typeName(T) ++ " has two variants that claim " ++
                    @tagName(kind) ++ ", one of them " ++ name);
            }

            table[@backingInt(kind)] = index;
        }
    }

    if (table[@backingInt(Kind.integer)] == null) table[@backingInt(Kind.integer)] = float_index;

    return table;
}

fn failure_position(decoder: *const Decoder, err: DecodeError) Position {
    assert(@backingInt(decoder.node) < decoder.document.node_count);
    assert(@errorName(err).len > 0);

    const document = decoder.document;
    const node = decoder.node;

    return switch (err) {
        error.MemberMissing, error.MemberUnknown => position_near(document, node),
        error.Mismatch => value_position_of(document, node),
        error.RegionFull => position_near(document, node),
    };
}

fn position_near(document: *const Document, node: Node) Position {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= document.nodes.len);

    var current = @backingInt(node);

    for (0..document.node_count) |_| {
        if (document.position_of(@fromBackingInt(current))) |position| return position;
        if (current == 0) break;

        current = document.nodes[current].parent;
    }

    return document_module.position_none;
}

fn value_position_of(document: *const Document, node: Node) Position {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= document.nodes.len);

    const record = &document.nodes[@backingInt(node)];
    const key_position = document.position_of(node) orelse return position_near(document, node);
    if (record.parent == storage_module.none) return key_position;
    if (document.nodes[record.parent].kind != .table) return key_position;

    const source = document.source;

    assert(key_position.offset < source.len);

    const quoted = source[key_position.offset] == '"' or source[key_position.offset] == '\'';
    const quote_bytes: u32 = 2 * @as(u32, @intFromBool(quoted));
    const key_bytes: u32 = @intCast(record.key.len);
    const equals = scalar.whitespace_end(source, key_position.offset + key_bytes + quote_bytes);
    if (equals == source.len) return key_position;
    if (source[equals] != '=') return key_position;

    const result = scalar.position_of(source, scalar.whitespace_end(source, equals + 1));

    assert(result.offset > key_position.offset);
    assert(result.offset <= source.len);

    return result;
}

fn value_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(depth < type_depth_max);
    assert(@backingInt(node) < decoder.document.node_count);

    const document = decoder.document;

    decoder.node = node;

    switch (comptime shape_of(T)) {
        .array => try array_decode(T, depth + 1, decoder, node, target),
        .boolean => target.* = try boolean_of(document, node),
        .choice => try choice_decode(T, depth + 1, decoder, node, target),
        .datetime => target.* = try datetime_of(document, node),
        .enumeration => target.* = try enumeration_of(T, document, node),
        .float => target.* = try float_of(T, document, node),
        .integer => target.* = try integer_of(T, document, node),
        .optional => {
            const Child = @typeInfo(T).optional.child;

            var child: Child = undefined;

            try value_decode(Child, depth + 1, decoder, node, &child);

            target.* = child;
        },
        .string => target.* = try string_of(document, node),
        .table => try table_decode(T, depth + 1, decoder, node, target),
    }
}

fn table_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .table);
    comptime assert(depth < type_depth_max);
    assert(@backingInt(node) < decoder.document.node_count);

    const document = decoder.document;
    if (document.kind_of(node) != .table) return error.Mismatch;

    comptime names_check(T);

    if (decoder.unknown_members == .refused) try members_known_check(T, decoder, node);

    inline for (@typeInfo(T).@"struct".field_names, 0..) |name, index| {
        const wire_name = comptime name_of(T, name);
        const field = &@field(target, name);

        if (document.member(node, wire_name)) |value| {
            const Field = @TypeOf(field.*);

            try value_decode(Field, depth + 1, decoder, value, field);
        } else {
            try field_absent(T, index, decoder, node, field);
        }
    }
}

noinline fn members_known_check(
    comptime T: type,
    decoder: *Decoder,
    table: Node,
) MismatchError!void {
    comptime assert(shape_of(T) == .table);
    assert(decoder.unknown_members == .refused);
    assert(decoder.document.kind_of(table) == .table);

    const document = decoder.document;
    const wire_names = comptime wire_names_of(T);
    var entries = document.entries(table);

    for (0..document.count_of(table)) |_| {
        const entry = entries.next() orelse break;

        if (!wire_names.has(document.key_of(entry))) {
            decoder.node = entry;

            return error.MemberUnknown;
        }
    }

    assert(entries.remaining == 0);
}

fn wire_names_of(comptime T: type) std.StaticStringMap(void) {
    const field_names = @typeInfo(T).@"struct".field_names;

    @setEvalBranchQuota(64 * field_names.len * field_names.len + 1000);

    var entries: [field_names.len]struct { []const u8 } = undefined;

    for (field_names, &entries) |name, *entry| entry.* = .{name_of(T, name)};

    const result: std.StaticStringMap(void) = .initComptime(entries);

    for (field_names) |name| assert(result.has(name_of(T, name)));

    return result;
}

fn field_absent(
    comptime T: type,
    comptime index: usize,
    decoder: *Decoder,
    table: Node,
    field: *@typeInfo(T).@"struct".field_types[index],
) MismatchError!void {
    const structure = @typeInfo(T).@"struct";

    comptime assert(index < structure.field_names.len);
    assert(decoder.document.kind_of(table) == .table);

    const Field = structure.field_types[index];

    if (comptime structure.field_attrs[index].defaultValue(Field)) |default| {
        field.* = default;
    } else if (comptime shape_of(Field) == .optional) {
        field.* = null;
    } else {
        decoder.node = table;

        return error.MemberMissing;
    }
}

fn array_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .array);
    comptime assert(depth < type_depth_max);
    assert(@backingInt(node) < decoder.document.node_count);

    const Element = element_of(T);
    const document = decoder.document;
    if (document.kind_of(node) != .array) return error.Mismatch;

    const count = document.count_of(node);
    if (count > decoder.region.unused_bytes()) return error.RegionFull;

    const elements = try decoder.region.reserve(Element, count);

    var items = document.items(node);

    for (elements) |*element| {
        const item = items.next() orelse unreachable;

        try value_decode(Element, depth + 1, decoder, item, element);
    }

    assert(items.remaining == 0);

    target.* = elements;
}

fn choice_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .choice);
    comptime assert(depth < type_depth_max);
    assert(@backingInt(node) < decoder.document.node_count);

    const choice = @typeInfo(T).@"union";
    const table = comptime choice_table(T);
    const kind = decoder.document.kind_of(node);
    const index = table[@backingInt(kind)] orelse return error.Mismatch;

    switch (index) {
        inline 0...choice.field_names.len - 1 => |variant_index| {
            const name = choice.field_names[variant_index];
            const Payload = choice.field_types[variant_index];

            var payload: Payload = undefined;

            try value_decode(Payload, depth + 1, decoder, node, &payload);

            target.* = @unionInit(T, name, payload);
        },
        else => unreachable,
    }
}

fn boolean_of(document: *const Document, node: Node) MismatchError!bool {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= document.nodes.len);

    return document.boolean_of(node) orelse error.Mismatch;
}

fn datetime_of(document: *const Document, node: Node) MismatchError!Datetime {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= document.nodes.len);

    const result = document.datetime_of(node) orelse return error.Mismatch;

    assert(datetime_module.valid(&result));

    return result;
}

fn string_of(document: *const Document, node: Node) MismatchError![]const u8 {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count <= document.nodes.len);

    const result = document.string_of(node) orelse return error.Mismatch;

    assert(std.unicode.utf8ValidateSlice(result));

    return result;
}

fn enumeration_of(comptime T: type, document: *const Document, node: Node) MismatchError!T {
    comptime assert(shape_of(T) == .enumeration);
    assert(@backingInt(node) < document.node_count);

    const names = comptime names_of(T);
    const text = try string_of(document, node);

    return names.get(text) orelse error.Mismatch;
}

fn integer_of(comptime T: type, document: *const Document, node: Node) MismatchError!T {
    comptime assert(shape_of(T) == .integer);
    assert(@backingInt(node) < document.node_count);

    if (@typeInfo(T).int.bits > 64) {
        @compileError("the integer type " ++ @typeName(T) ++ " is wider than 64 bits");
    }

    const integer = document.integer_of(node) orelse return error.Mismatch;
    return std.math.cast(T, integer) orelse error.Mismatch;
}

fn float_of(comptime T: type, document: *const Document, node: Node) MismatchError!T {
    comptime assert(shape_of(T) == .float);
    assert(@backingInt(node) < document.node_count);

    if (@bitSizeOf(T) > 64) @compileError("the float type " ++ @typeName(T) ++ " is too wide");

    const value: f64 = switch (document.value_of(node)) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        .array, .boolean, .datetime, .string, .table => return error.Mismatch,
    };

    const result: T = @floatCast(value);

    if (std.math.isFinite(value)) {
        if (!std.math.isFinite(result)) return error.Mismatch;
    }

    assert(std.math.isNan(result) == std.math.isNan(value));

    return result;
}

fn table_encode(
    comptime T: type,
    comptime depth: u32,
    comptime path: []const []const u8,
    writer: *Writer,
    value: *const T,
) Writer.Error!void {
    comptime assert(shape_of(T) == .table);
    comptime assert(depth < type_depth_max);
    comptime assert(path.len < type_depth_max);
    assert(writer.depth == 0);

    const structure = @typeInfo(T).@"struct";

    comptime names_check(T);

    inline for (structure.field_names, structure.field_types) |name, Field| {
        const key = comptime name_of(T, name);

        try line_encode(Field, depth + 1, key, writer, &@field(value, name));
    }

    inline for (structure.field_names, structure.field_types) |name, Field| {
        const child_path: []const []const u8 = comptime path ++ &[_][]const u8{name_of(T, name)};

        try section_encode(Field, depth + 1, child_path, writer, &@field(value, name));
    }

    assert(writer.depth == 0);
}

fn line_encode(
    comptime T: type,
    comptime depth: u32,
    comptime key: []const u8,
    writer: *Writer,
    value: *const T,
) Writer.Error!void {
    comptime assert(depth < type_depth_max);
    comptime assert(std.unicode.utf8ValidateSlice(key));
    assert(writer.depth == 0);

    switch (comptime shape_of(T)) {
        .optional => {
            const Child = @typeInfo(T).optional.child;

            if (value.*) |*child| try line_encode(Child, depth + 1, key, writer, child);
        },
        .table => {},
        .array => {
            if (comptime shape_of(element_of(T)) == .table) {
                if (value.len > 0) return;
            }

            try writer.key(&.{key});
            try inline_encode(T, depth + 1, writer, value);
        },
        .boolean, .choice, .datetime, .enumeration, .float, .integer, .string => {
            try writer.key(&.{key});
            try inline_encode(T, depth + 1, writer, value);
        },
    }
}

fn section_encode(
    comptime T: type,
    comptime depth: u32,
    comptime path: []const []const u8,
    writer: *Writer,
    value: *const T,
) Writer.Error!void {
    comptime assert(depth < type_depth_max);
    comptime assert(path.len > 0);
    assert(writer.depth == 0);

    switch (comptime shape_of(T)) {
        .optional => {
            const Child = @typeInfo(T).optional.child;

            if (value.*) |*child| try section_encode(Child, depth + 1, path, writer, child);
        },
        .table => {
            try writer.table(path);
            try table_encode(T, depth + 1, path, writer, value);
        },
        .array => {
            const Element = element_of(T);
            if (comptime shape_of(Element) != .table) return;

            for (value.*) |*element| {
                try writer.table_array(path);
                try table_encode(Element, depth + 1, path, writer, element);
            }
        },
        .boolean, .choice, .datetime, .enumeration, .float, .integer, .string => {},
    }
}

fn inline_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
) Writer.Error!void {
    comptime assert(depth < type_depth_max);
    assert(writer.state == .value);

    switch (comptime shape_of(T)) {
        .array => {
            const Element = element_of(T);

            try writer.array_begin(@intCast(value.len));

            for (value.*) |*element| try inline_encode(Element, depth + 1, writer, element);

            try writer.array_end();
        },
        .boolean => try writer.boolean(value.*),
        .choice => switch (value.*) {
            inline else => |*payload| {
                try inline_encode(@TypeOf(payload.*), depth + 1, writer, payload);
            },
        },
        .datetime => try writer.datetime(value.*),
        .enumeration => try writer.string(enumeration_text(T, value)),
        .float => try float_encode(T, writer, value),
        .integer => try integer_encode(T, writer, value),
        .optional => @compileError("the optional " ++ @typeName(T) ++ " has no inline form"),
        .string => try writer.string(value.*),
        .table => try inline_table_encode(T, depth + 1, writer, value),
    }
}

fn inline_table_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
) Writer.Error!void {
    comptime assert(shape_of(T) == .table);
    comptime assert(depth < type_depth_max);
    assert(writer.state == .value);

    const structure = @typeInfo(T).@"struct";

    comptime names_check(T);

    var count: u32 = 0;

    inline for (structure.field_names) |name| {
        if (present_is(@TypeOf(@field(value, name)), &@field(value, name))) count += 1;
    }

    try writer.inline_table_begin(count);

    inline for (structure.field_names, structure.field_types) |name, Field| {
        const field = &@field(value, name);

        if (comptime shape_of(Field) == .optional) {
            if (field.*) |*child| {
                try writer.key(&.{comptime name_of(T, name)});
                try inline_encode(@typeInfo(Field).optional.child, depth + 1, writer, child);
            }
        } else {
            try writer.key(&.{comptime name_of(T, name)});
            try inline_encode(Field, depth + 1, writer, field);
        }
    }

    try writer.inline_table_end();
}

fn present_is(comptime T: type, value: *const T) bool {
    if (comptime shape_of(T) != .optional) return true;
    return value.* != null;
}

fn enumeration_text(comptime T: type, value: *const T) []const u8 {
    comptime assert(shape_of(T) == .enumeration);

    switch (value.*) {
        inline else => |tag| return comptime name_of(T, @tagName(tag)),
    }
}

fn float_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(shape_of(T) == .float);
    assert(writer.state == .value);

    if (@bitSizeOf(T) > 64) @compileError("the float type " ++ @typeName(T) ++ " is too wide");

    try writer_module.float_write(writer, T, value.*);
}

fn integer_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(shape_of(T) == .integer);
    assert(writer.state == .value);

    const integer = @typeInfo(T).int;

    if (integer.bits > 64) {
        @compileError("the integer type " ++ @typeName(T) ++ " is wider than 64 bits");
    }

    if (integer.signedness == .unsigned) {
        if (integer.bits > 63) {
            @compileError("the integer type " ++ @typeName(T) ++ " does not fit a TOML integer");
        }
    }

    try writer.integer(value.*);
}

const testing = std.testing;

const test_region_bytes: u32 = 16 * 1024;

const TestFixed = document_module.DocumentType(.{
    .line_count_max = null,
    .node_count_max = 512,
    .text_bytes_max = 8192,
});

const test_writer_options: Writer.Options = .{
    .layout = .vertical,
    .strings = .auto,
    .version = .v1_1,
};

const TestColor = enum {
    blue,
    red,

    pub const toml = .{ .red = "Red" };
};

const TestPort = struct {
    number: u16,
    open: bool = true,

    pub const toml = .{};
};

const TestValue = union(enum) {
    count: i64,
    label: []const u8,
    list: []const u32,
    ratio: f64,

    pub const toml = .{};
};

const TestServer = struct {
    color: TestColor = .blue,
    host: []const u8,
    limits: TestLimits,
    note: ?[]const u8 = null,
    ports: []const TestPort,
    started: ?Datetime,
    tags: []const []const u8,
    value: TestValue,
    weight: f32 = 1.5,

    pub const toml = .{ .host = "host-name" };
};

const TestLimits = struct {
    depth: u8,
    pairs: []const TestPort = &.{},

    pub const toml = .{};
};

const TestRegion = struct {
    buffer: [test_region_bytes]u8 align(region_module.alignment_bytes),
    region: Region,

    fn init(test_region: *TestRegion) void {
        assert(@intFromPtr(&test_region.buffer) % region_module.alignment_bytes == 0);

        test_region.region = .init(&test_region.buffer);
    }
};

const TestState = struct {
    fixed: TestFixed,
    output: [8192]u8,
    region: TestRegion,
    sink: std.Io.Writer,
    writer: Writer,

    fn reset(state: *TestState) void {
        state.region.init();
        state.sink = .fixed(&state.output);

        state.writer.init(&state.sink, test_writer_options);

        assert(state.sink.end == 0);
        assert(state.writer.depth == 0);
    }
};

const test_source =
    \\host-name = "example.org"
    \\tags = ["a", "b"]
    \\value = [1, 2, 3]
    \\started = 1979-05-27T07:32:00Z
    \\color = "Red"
    \\ignored = "unknown keys are skipped"
    \\
    \\[limits]
    \\depth = 3
    \\
    \\[[ports]]
    \\number = 80
    \\
    \\[[ports]]
    \\number = 443
    \\open = false
    \\
;

const test_encoded =
    \\color = "Red"
    \\host-name = "example.org"
    \\note = 'quoted "text"'
    \\started = 1979-05-27T07:32:00Z
    \\tags = [
    \\    "a",
    \\    "b",
    \\]
    \\value = [
    \\    1,
    \\    2,
    \\]
    \\weight = 0.5
    \\
    \\[limits]
    \\depth = 3
    \\
    \\[[limits.pairs]]
    \\number = 1
    \\open = true
    \\
    \\[[ports]]
    \\number = 80
    \\open = true
    \\
    \\[[ports]]
    \\number = 443
    \\open = false
    \\
;

test "a document decodes into the type and unknown keys are skipped" {
    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    state.reset();

    try state.fixed.parse(test_source, .{ .version = .v1_1 });

    var server: TestServer = undefined;
    const root = state.fixed.root();

    try decode(TestServer, &state.region.region, &state.fixed.document, root, &server, .{
        .diagnostic = null,
    });

    try testing.expectEqualStrings("example.org", server.host);
    try testing.expectEqual(TestColor.red, server.color);
    try testing.expectEqual(@as(u8, 3), server.limits.depth);
    try testing.expectEqual(@as(usize, 0), server.limits.pairs.len);
    try testing.expectEqual(@as(?[]const u8, null), server.note);
    try testing.expectEqual(@as(usize, 2), server.ports.len);
    try testing.expect(server.ports[0].open);
    try testing.expect(!server.ports[1].open);
    try testing.expectEqual(@as(u16, 443), server.ports[1].number);
    try testing.expectEqual(@as(u16, 1979), server.started.?.year);
    try testing.expectEqualStrings("b", server.tags[1]);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, server.value.list);
    try testing.expectEqual(@as(f32, 1.5), server.weight);
}

test "a missing required key points at its table and a failed decode restores the region" {
    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    state.reset();

    try state.fixed.parse("host-name = 'x'\ntags = []\nvalue = 1\n[limits]\n", .{
        .version = .v1_1,
    });

    var server: TestServer = undefined;
    var diagnostic: Position = undefined;
    const region = &state.region.region;
    const used = region.used;
    const document = &state.fixed.document;

    const missing = decode(TestServer, region, document, document.root(), &server, .{
        .diagnostic = &diagnostic,
    });

    try testing.expectError(error.MemberMissing, missing);
    try testing.expectEqual(Position{ .column = 2, .line = 4, .offset = 37 }, diagnostic);
    try testing.expectEqual(used, region.used);
}

test "a value of the wrong kind or out of range is a mismatch" {
    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    const sources = [_][]const u8{
        "number = 70000\n",
        "number = -1\n",
        "number = 'eighty'\n",
        "number = 80\nopen = 1\n",
    };

    for (sources) |source| {
        state.reset();

        try state.fixed.parse(source, .{ .version = .v1_1 });

        var port: TestPort = undefined;
        var diagnostic: Position = undefined;
        const root = state.fixed.root();
        const document = &state.fixed.document;

        const refused = decode(TestPort, &state.region.region, document, root, &port, .{
            .diagnostic = &diagnostic,
        });

        try testing.expectError(error.Mismatch, refused);
        try testing.expect(diagnostic.line >= 1);
    }
}

test "a union decodes by the kind of its node and a float takes an integer" {
    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    state.reset();

    try state.fixed.parse("a = 5\nb = 'x'\nc = 0.25\nd = [7]\ne = true\n", .{
        .version = .v1_1,
    });

    const document = &state.fixed.document;
    const root = state.fixed.root();
    const region = &state.region.region;
    const options: DecodeOptions = .{ .diagnostic = null };

    var value: TestValue = undefined;

    try decode(TestValue, region, document, document.member(root, "a").?, &value, options);
    try testing.expectEqual(@as(i64, 5), value.count);
    try decode(TestValue, region, document, document.member(root, "b").?, &value, options);
    try testing.expectEqualStrings("x", value.label);
    try decode(TestValue, region, document, document.member(root, "c").?, &value, options);
    try testing.expectEqual(@as(f64, 0.25), value.ratio);
    try decode(TestValue, region, document, document.member(root, "d").?, &value, options);
    try testing.expectEqualSlices(u32, &.{7}, value.list);

    const boolean = document.member(root, "e").?;
    const refused = decode(TestValue, region, document, boolean, &value, options);

    try testing.expectError(error.Mismatch, refused);

    var ratio: f32 = undefined;

    try decode(f32, region, document, document.member(root, "a").?, &ratio, options);
    try testing.expectEqual(@as(f32, 5), ratio);
}

test "an array larger than the region is refused and the region is restored" {
    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    state.reset();

    try state.fixed.parse("list = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]\n", .{
        .version = .v1_1,
    });

    var buffer: [64]u8 align(region_module.alignment_bytes) = undefined;
    var region: Region = .init(&buffer);
    var list: []const u64 = undefined;
    const document = &state.fixed.document;
    const node = document.member(state.fixed.root(), "list").?;
    const refused = decode([]const u64, &region, document, node, &list, .{ .diagnostic = null });

    try testing.expectError(error.RegionFull, refused);
    try testing.expectEqual(@as(u32, 0), region.used);
}

test "encoding writes lines first, then tables and arrays of tables, and decodes back equal" {
    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    state.reset();

    const ports = [_]TestPort{ .{ .number = 80 }, .{ .number = 443, .open = false } };
    const pairs = [_]TestPort{.{ .number = 1 }};
    const started = try datetime_module.parse("1979-05-27T07:32:00Z", .v1_1);

    const original: TestServer = .{
        .color = .red,
        .host = "example.org",
        .limits = .{ .depth = 3, .pairs = &pairs },
        .note = "quoted \"text\"",
        .ports = &ports,
        .started = started,
        .tags = &.{ "a", "b" },
        .value = .{ .list = &.{ 1, 2 } },
        .weight = 0.5,
    };

    try encode(TestServer, &state.writer, &original);

    state.writer.finish();

    try testing.expectEqualStrings(test_encoded, state.sink.buffered());
    try state.fixed.parse(state.sink.buffered(), .{ .version = .v1_1 });

    var decoded: TestServer = undefined;

    const document = &state.fixed.document;

    try decode(TestServer, &state.region.region, document, document.root(), &decoded, .{
        .diagnostic = null,
    });

    try testing.expectEqualDeep(original, decoded);
}

test "an empty slice of tables is a line and a struct inside an array is an inline table" {
    const Inner = struct {
        count: i32,
        flag: ?bool = null,

        pub const toml = .{};
    };

    const Outer = struct {
        grid: []const []const Inner,
        none: []const Inner,

        pub const toml = .{};
    };

    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    state.reset();

    const row = [_]Inner{ .{ .count = 1 }, .{ .count = 2, .flag = true } };
    const outer: Outer = .{ .grid = &.{&row}, .none = &.{} };

    try encode(Outer, &state.writer, &outer);

    const expected =
        \\grid = [[
        \\    { count = 1 },
        \\    {
        \\        count = 2,
        \\        flag = true,
        \\    },
        \\]]
        \\none = []
        \\
    ;

    try testing.expectEqualStrings(expected, state.sink.buffered());
}

test "a mismatch points at the value, not at its key" {
    const Case = struct {
        column: u32,
        line: u32,
        offset: u32,
        source: []const u8,
    };

    const cases = [_]Case{
        .{ .column = 10, .line = 1, .offset = 9, .source = "number = 'eighty'\n" },
        .{ .column = 8, .line = 2, .offset = 19, .source = "number = 80\nopen = 1\n" },
        .{ .column = 14, .line = 1, .offset = 13, .source = "\"number\"  =  -1\n" },
        .{ .column = 16, .line = 1, .offset = 15, .source = "t = { number = 70000 }\n" },
        .{ .column = 12, .line = 1, .offset = 11, .source = "t.number = 'x'\n" },
        .{ .column = 9, .line = 2, .offset = 12, .source = "[t]\nnumber=\ttrue\n" },
        .{ .column = 2, .line = 1, .offset = 1, .source = "[t]\n\"n\\u0075mber\" = 1.5\n" },
    };

    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    for (cases) |case| {
        state.reset();

        try state.fixed.parse(case.source, .{ .version = .v1_1 });

        var port: TestPort = undefined;
        var diagnostic: Position = undefined;
        const document = &state.fixed.document;
        const table = document.member(document.root(), "t") orelse document.root();

        const refused = decode(TestPort, &state.region.region, document, table, &port, .{
            .diagnostic = &diagnostic,
        });

        const expected: Position = .{
            .column = case.column,
            .line = case.line,
            .offset = case.offset,
        };

        try testing.expectError(error.Mismatch, refused);
        try testing.expectEqual(expected, diagnostic);
        try testing.expectEqual(expected, scalar.position_of(case.source, diagnostic.offset));
    }

    state.reset();

    try state.fixed.parse("list = [1, 'two']\n", .{ .version = .v1_1 });

    var list: []const u16 = undefined;
    var diagnostic: Position = undefined;
    const document = &state.fixed.document;
    const node = document.member(document.root(), "list").?;

    const refused = decode([]const u16, &state.region.region, document, node, &list, .{
        .diagnostic = &diagnostic,
    });

    try testing.expectError(error.Mismatch, refused);
    try testing.expectEqual(Position{ .column = 12, .line = 1, .offset = 11 }, diagnostic);
}

test "a refused unknown member is MemberUnknown at its key, and an ignored one is skipped" {
    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    const source = "host-name = 'x'\ntags = []\nvalue = 1\n[limits]\ndepth = 1\n" ++
        "[[ports]]\nnumber = 80\n'shut' = true\n";

    state.reset();

    try state.fixed.parse(source, .{ .version = .v1_1 });

    var server: TestServer = undefined;
    var diagnostic: Position = undefined;
    const document = &state.fixed.document;
    const region = &state.region.region;
    const used = region.used;

    const refused = decode(TestServer, region, document, document.root(), &server, .{
        .diagnostic = &diagnostic,
        .unknown_members = .refused,
    });

    try testing.expectError(error.MemberUnknown, refused);
    try testing.expectEqual(Position{ .column = 1, .line = 8, .offset = 77 }, diagnostic);
    try testing.expectEqual(used, region.used);

    try decode(TestServer, region, document, document.root(), &server, .{
        .diagnostic = null,
        .unknown_members = .ignored,
    });

    try testing.expectEqual(@as(u16, 80), server.ports[0].number);

    state.reset();

    try state.fixed.parse("host = 'x'\n", .{ .version = .v1_1 });

    const renamed = decode(TestServer, &state.region.region, document, document.root(), &server, .{
        .diagnostic = &diagnostic,
        .unknown_members = .refused,
    });

    try testing.expectError(error.MemberUnknown, renamed);
    try testing.expectEqual(Position{ .column = 1, .line = 1, .offset = 0 }, diagnostic);
}

test "a struct without a toml declaration decodes and encodes by its field names" {
    const Plain = struct {
        name: []const u8,
        port: u16 = 80,
        ratio: f32,
    };

    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    state.reset();

    const original: Plain = .{ .name = "web", .port = 8080, .ratio = 0.1 };

    try encode(Plain, &state.writer, &original);

    state.writer.finish();

    const expected = "name = \"web\"\nport = 8080\nratio = 0.1\n";

    try testing.expectEqualStrings(expected, state.sink.buffered());
    try state.fixed.parse(state.sink.buffered(), .{ .version = .v1_1 });

    var decoded: Plain = undefined;
    const document = &state.fixed.document;

    try decode(Plain, &state.region.region, document, document.root(), &decoded, .{
        .diagnostic = null,
        .unknown_members = .refused,
    });

    try testing.expectEqualDeep(original, decoded);
}

test "an f32 encodes in its own shortest form and decodes back to the same bits" {
    const Single = struct {
        ratio: f32,
    };

    const Case = struct {
        expected: []const u8,
        value: f32,
    };

    const cases = [_]Case{
        .{ .expected = "ratio = 0.1\n", .value = 0.1 },
        .{ .expected = "ratio = 3.4028235e38\n", .value = std.math.floatMax(f32) },
        .{ .expected = "ratio = 1e-45\n", .value = 1e-45 },
        .{ .expected = "ratio = 16777216.0\n", .value = 16777216 },
        .{ .expected = "ratio = 70000.0\n", .value = 70000 },
        .{ .expected = "ratio = 1e-7\n", .value = 1e-7 },
        .{ .expected = "ratio = 0.00001\n", .value = 1e-5 },
        .{ .expected = "ratio = 1e16\n", .value = 1e16 },
        .{ .expected = "ratio = -0.0\n", .value = -0.0 },
        .{ .expected = "ratio = -inf\n", .value = -std.math.inf(f32) },
    };

    const state = try testing.allocator.create(TestState);
    defer testing.allocator.destroy(state);

    for (cases) |case| {
        state.reset();

        const single: Single = .{ .ratio = case.value };

        try encode(Single, &state.writer, &single);
        try testing.expectEqualStrings(case.expected, state.sink.buffered());
        try state.fixed.parse(state.sink.buffered(), .{ .version = .v1_1 });

        var decoded: Single = undefined;
        const document = &state.fixed.document;

        try decode(Single, &state.region.region, document, document.root(), &decoded, .{
            .diagnostic = null,
            .unknown_members = .refused,
        });

        const expected: u32 = @bitCast(case.value);

        try testing.expectEqual(expected, @as(u32, @bitCast(decoded.ratio)));
    }
}

test decode {
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,

        pub const toml = .{ .host = "address" };
    };

    const Config = document_module.DocumentType(.{
        .line_count_max = null,
        .node_count_max = 16,
        .text_bytes_max = 64,
    });

    const config = try testing.allocator.create(Config);
    defer testing.allocator.destroy(config);

    try config.parse("[server]\naddress = \"localhost\"\n", .{ .version = .v1_1 });

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var server: Server = undefined;
    const node = config.path_find(config.root(), &.{"server"}) orelse return error.ServerMissing;

    try decode(Server, &region, &config.document, node, &server, .{ .diagnostic = null });

    try testing.expectEqualStrings("localhost", server.host);
    try testing.expectEqual(@as(u16, 8080), server.port);
}

test encode {
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,

        pub const toml = .{ .host = "address" };
    };

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = undefined;
    const server: Server = .{ .host = "localhost" };

    writer.init(&sink, .{ .layout = .vertical, .strings = .auto, .version = .v1_1 });

    try encode(Server, &writer, &server);

    writer.finish();

    try testing.expectEqualStrings("address = \"localhost\"\nport = 8080\n", sink.buffered());
}
