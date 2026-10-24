const std = @import("std");

const datetime_module = @import("datetime.zig");
const document_module = @import("document.zig");
const scalar = @import("scalar.zig");

const assert = std.debug.assert;

const Datetime = datetime_module.Datetime;
const Version = document_module.Version;

pub const Writer = struct {
    depth: u32,
    frames: [depth_max]Frame,
    indent_bound: u32,
    margin: []const u8,
    options: Options,
    out: *std.Io.Writer,
    state: State,
    written: bool,

    pub const Error = std.Io.Writer.Error || ValueError;

    pub const Layout = enum {
        compact,
        vertical,
    };

    pub const Options = struct {
        layout: Layout = .vertical,
        strings: Strings = .auto,
        version: Version = .v1_1,
    };

    pub const Strings = enum {
        auto,
        basic,
        literal,
    };

    pub const ValueError = error{
        DatetimeInvalid,
        Utf8Invalid,
    };

    pub fn init(writer: *Writer, out: *std.Io.Writer, options: Options) void {
        assert(out.end <= out.buffer.len);
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);

        writer.depth = 0;
        writer.indent_bound = indent_spaces_max + 1;
        writer.margin = "";
        writer.options = options;
        writer.out = out;
        writer.state = .line;
        writer.written = false;
    }

    pub fn table(
        writer: *Writer,
        path: []const []const u8,
    ) (error{Utf8Invalid} || std.Io.Writer.Error)!void {
        assert(path.len > 0);
        assert(path.len <= key_segment_count_max);

        try path_validate(path);
        try header_trusted_write(writer, .{ .kind = .table, .path = path });
    }

    pub fn table_array(
        writer: *Writer,
        path: []const []const u8,
    ) (error{Utf8Invalid} || std.Io.Writer.Error)!void {
        assert(path.len > 0);
        assert(path.len <= key_segment_count_max);

        try path_validate(path);
        try header_trusted_write(writer, .{ .kind = .table_array, .path = path });
    }

    pub fn key(
        writer: *Writer,
        path: []const []const u8,
    ) (error{Utf8Invalid} || std.Io.Writer.Error)!void {
        assert(path.len > 0);
        assert(path.len <= key_segment_count_max);

        try path_validate(path);
        try key_trusted_write(writer, path);
    }

    pub fn string(
        writer: *Writer,
        text: []const u8,
    ) (error{Utf8Invalid} || std.Io.Writer.Error)!void {
        assert(text.len <= source_bytes_max);
        assert(writer.depth <= depth_max);

        if (!std.unicode.utf8ValidateSlice(text)) return error.Utf8Invalid;

        try string_trusted_write(writer, text);
    }

    pub fn integer(writer: *Writer, value: i64) std.Io.Writer.Error!void {
        assert(std.math.log10_int(@abs(value) | 1) < integer_bytes_max);
        assert(writer.depth <= depth_max);

        try integer_write(writer, value);
    }

    pub fn float(writer: *Writer, value: f64) std.Io.Writer.Error!void {
        assert(@intFromBool(std.math.signbit(value)) + float_unsigned_bytes_max <= float_bytes_max);
        assert(writer.depth <= depth_max);

        try float_write(writer, f64, value);
    }

    pub fn boolean(writer: *Writer, value: bool) std.Io.Writer.Error!void {
        assert(writer.depth <= depth_max);
        assert(writer.state == .value);

        try boolean_write(writer, value);
    }

    pub fn datetime(
        writer: *Writer,
        value: Datetime,
    ) (error{DatetimeInvalid} || std.Io.Writer.Error)!void {
        assert(writer.depth <= depth_max);
        assert(writer.state == .value);

        if (!datetime_module.valid(&value)) return error.DatetimeInvalid;

        try datetime_trusted_write(writer, &value);
    }

    pub fn array_begin(writer: *Writer, count: u32) std.Io.Writer.Error!void {
        assert(count <= source_bytes_max);
        assert(writer.depth < depth_max);

        try container_open(writer, .{ .count = count, .inline_table = false });
    }

    pub fn array_end(writer: *Writer) std.Io.Writer.Error!void {
        assert(writer.depth > 0);
        assert(!writer.frames[writer.depth - 1].flags.inline_table);

        try container_close(writer);
    }

    pub fn inline_table_begin(writer: *Writer, count: u32) std.Io.Writer.Error!void {
        assert(count <= source_bytes_max);
        assert(writer.depth < depth_max);

        try container_open(writer, .{ .count = count, .inline_table = true });
    }

    pub fn inline_table_end(writer: *Writer) std.Io.Writer.Error!void {
        assert(writer.depth > 0);
        assert(writer.frames[writer.depth - 1].flags.inline_table);

        try container_close(writer);
    }

    pub fn comment(
        writer: *Writer,
        text: []const u8,
    ) (error{Utf8Invalid} || std.Io.Writer.Error)!void {
        assert(writer.depth == 0);
        assert(writer.state == .line);
        assert(comment_lines_clean(text));

        if (!std.unicode.utf8ValidateSlice(text)) return error.Utf8Invalid;

        try writer.out.writeAll(text);
        try writer.out.writeByte('\n');

        writer.written = true;
    }

    pub fn finish(writer: *const Writer) void {
        assert(writer.depth == 0);
        assert(writer.state == .line);
    }
};

const Body = struct {
    clean: u32,
    text: []const u8,
};

const Chunk = @Vector(lane_count, u8);

const Classes = packed struct(u8) {
    backslash: bool,
    carriage: bool,
    control: bool,
    newline: bool,
    quote_double: bool,
    quote_single: bool,
    padding: u2,
};

const ClassesLanes = struct {
    classes: Classes,
    index: u32,
};

const Decimal = struct {
    digit_count: u32,
    digits: [float_digit_count_max]u8,
    exponent: i32,
    negative: bool,
};

const Frame = struct {
    flags: FrameFlags,
    level: u8,
    remaining: u32,
};

const FrameFlags = packed struct(u8) {
    inline_table: bool,
    items: bool,
    key_pending: bool,
    single_line: bool,
    vertical: bool,
    padding: u3,
};

const Half = @Vector(half_count, u8);
const HalfLanes = @Vector(half_count, u1);
const HalfMask = @Int(.unsigned, half_count);

pub const Header = struct {
    kind: HeaderKind,
    path: []const []const u8,
};

pub const HeaderKind = enum {
    table,
    table_array,
};

const Indent = struct {
    level: u32,
    start: u32,
};

const Lanes = @Vector(lane_count, u1);

const MultilineByte = struct {
    byte: u8,
    quote_run: u32,
};

pub const Splice = struct {
    margin: []const u8,
    single_line: bool,
};

pub const Opening = struct {
    count: u32,
    inline_table: bool,
};

const State = enum(u8) {
    line,
    value,
};

const Style = enum {
    basic,
    basic_multiline,
    literal,
    literal_multiline,
};

const Styled = struct {
    clean: u32,
    style: Style,
};

const depth_max = document_module.depth_max;
const float_bytes_max: u32 = 32;
const float_digit_count_max: u32 = 17;
const float_unsigned_bytes_max: u32 = 24;
const half_count: u32 = 16;
const indent_spaces_max: u32 = 64;
const indent_width: u32 = 4;
const integer_bytes_max: u32 = 20;
const key_segment_count_max = document_module.key_segment_count_max;
const lane_count: u32 = 32;
const positional_exponent_max: i32 = 15;
const positional_exponent_min: i32 = -5;
const separator_bytes = ",\n" ++ spaces;
const source_bytes_max = document_module.source_bytes_max;
const spaces: [indent_spaces_max]u8 = @splat(' ');

const classes_empty: Classes = .{
    .backslash = false,
    .carriage = false,
    .control = false,
    .newline = false,
    .quote_double = false,
    .quote_single = false,
    .padding = 0,
};

const frame_flags_empty: FrameFlags = .{
    .inline_table = false,
    .items = false,
    .key_pending = false,
    .single_line = false,
    .vertical = false,
    .padding = 0,
};

const frame_outside: Frame = .{ .flags = frame_flags_empty, .level = 0, .remaining = 0 };
const bare_allowed: [256]bool = bare_table_build();
const escape_needed: [256]bool = escape_table_build();

comptime {
    assert(@sizeOf(Frame) == 8);
    assert(depth_max <= std.math.maxInt(u8));
    assert(float_unsigned_bytes_max < float_bytes_max);
    assert(std.math.isPowerOfTwo(indent_spaces_max));
    assert(integer_bytes_max == std.fmt.count("{d}", .{std.math.minInt(i64)}));
}

fn bare_table_build() [256]bool {
    var table: [256]bool = @splat(false);

    for ('A'..'Z' + 1) |byte| table[byte] = true;
    for ('a'..'z' + 1) |byte| table[byte] = true;
    for ('0'..'9' + 1) |byte| table[byte] = true;

    table['_'] = true;
    table['-'] = true;

    return table;
}

fn escape_table_build() [256]bool {
    var table: [256]bool = @splat(false);

    for (0..0x20) |byte| table[byte] = true;

    table[0x7f] = true;

    table['"'] = true;
    table['\\'] = true;

    return table;
}

inline fn put(out: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    assert(out.end <= out.buffer.len);
    assert(bytes.len <= source_bytes_max);

    if (out.buffer.len - out.end >= bytes.len) {
        @memcpy(out.buffer[out.end..][0..bytes.len], bytes);
        out.end += bytes.len;

        return;
    }

    try out.writeAll(bytes);
}

inline fn put_byte(out: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    assert(out.end <= out.buffer.len);
    assert(byte != 0);

    if (out.end < out.buffer.len) {
        out.buffer[out.end] = byte;
        out.end += 1;

        return;
    }

    try out.writeByte(byte);
}

pub fn header_trusted_write(writer: *Writer, header: Header) std.Io.Writer.Error!void {
    assert(header.path.len > 0);
    assert(header.path.len <= depth_max);
    assert(writer.depth == 0);
    assert(writer.state == .line);

    if (writer.written) try writer.out.writeByte('\n');

    try header_render(writer.out, header);

    writer.written = true;
}

pub fn header_render(out: *std.Io.Writer, header: Header) std.Io.Writer.Error!void {
    assert(header.path.len > 0);
    assert(header.path.len <= depth_max);

    switch (header.kind) {
        .table => {
            try out.writeByte('[');
            try key_path_write(out, header.path);
            try out.writeAll("]\n");
        },
        .table_array => {
            try out.writeAll("[[");
            try key_path_write(out, header.path);
            try out.writeAll("]]\n");
        },
    }
}

pub fn header_text_write(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
    assert(text.len >= 4);
    assert(text[text.len - 1] == '\n');
    assert(writer.depth == 0);
    assert(writer.state == .line);

    if (writer.written) try writer.out.writeByte('\n');

    try writer.out.writeAll(text);

    writer.written = true;
}

pub fn key_trusted_write(
    writer: *Writer,
    path: []const []const u8,
) align(64) std.Io.Writer.Error!void {
    assert(path.len > 0);
    assert(path.len <= depth_max);

    if (writer.depth == 0) {
        assert(writer.state == .line);

        try key_path_write(writer.out, path);
        try put(writer.out, " = ");

        writer.state = .value;
        writer.written = true;

        return;
    }

    const frame = &writer.frames[writer.depth - 1];

    assert(frame.flags.inline_table);
    assert(!frame.flags.key_pending);
    assert(frame.remaining > 0);

    try item_separator_write(writer, frame);

    frame.remaining -= 1;
    frame.flags.key_pending = true;

    try key_path_write(writer.out, path);
    try put(writer.out, " = ");
}

pub fn string_trusted_write(writer: *Writer, text: []const u8) align(64) std.Io.Writer.Error!void {
    assert(text.len <= source_bytes_max);
    assert(writer.depth <= depth_max);

    const styled: Styled = switch (writer.options.strings) {
        .auto => auto_styled(text),
        .basic => .{ .clean = 0, .style = .basic },
        .literal => .{ .clean = 0, .style = literal_style_of(text, classes_of(text, 0)) },
    };

    try value_open(writer);

    switch (styled.style) {
        .basic => {
            try put_byte(writer.out, '"');
            try basic_write(writer.out, .{ .clean = styled.clean, .text = text });
            try put_byte(writer.out, '"');
        },
        .basic_multiline => {
            try put(writer.out, "\"\"\"\n");
            try basic_multiline_write(writer.out, .{ .clean = styled.clean, .text = text });
            try put(writer.out, "\"\"\"");
        },
        .literal => {
            try put_byte(writer.out, '\'');
            try put(writer.out, text);
            try put_byte(writer.out, '\'');
        },
        .literal_multiline => {
            try put(writer.out, "'''\n");
            try put(writer.out, text);
            try put(writer.out, "'''");
        },
    }

    try value_close(writer);
}

pub fn datetime_trusted_write(writer: *Writer, value: *const Datetime) std.Io.Writer.Error!void {
    assert(value.spelling.padding == 0);
    assert(writer.depth <= depth_max);

    var spelled = value.*;

    if (writer.options.version == .v1_0) spelled.spelling.second_present = true;

    try value_open(writer);
    try spelled.format(writer.out);
    try value_close(writer);
}

pub fn integer_write(writer: *Writer, value: i64) align(64) std.Io.Writer.Error!void {
    assert(std.math.log10_int(@abs(value) | 1) < integer_bytes_max);
    assert(writer.depth <= depth_max);

    var buffer: [integer_bytes_max]u8 = undefined;

    try value_open(writer);
    try put(writer.out, integer_format(value, &buffer));
    try value_close(writer);
}

pub fn float_write(
    writer: *Writer,
    comptime T: type,
    value: T,
) align(64) std.Io.Writer.Error!void {
    comptime assert(@typeInfo(T) == .float);
    comptime assert(@bitSizeOf(T) <= 64);
    assert(@intFromBool(std.math.signbit(value)) + float_unsigned_bytes_max <= float_bytes_max);
    assert(writer.depth <= depth_max);

    var buffer: [float_bytes_max]u8 = undefined;

    try value_open(writer);
    try put(writer.out, float_format(T, value, &buffer));
    try value_close(writer);
}

pub fn boolean_write(writer: *Writer, value: bool) std.Io.Writer.Error!void {
    assert(writer.depth <= depth_max);
    assert(writer.state == .value);

    try value_open(writer);
    try put(writer.out, if (value) "true" else "false");
    try value_close(writer);
}

fn path_validate(path: []const []const u8) error{Utf8Invalid}!void {
    assert(path.len > 0);
    assert(path.len <= key_segment_count_max);

    for (path) |segment| {
        assert(segment.len <= source_bytes_max);

        if (!std.unicode.utf8ValidateSlice(segment)) return error.Utf8Invalid;
    }
}

fn comment_lines_clean(text: []const u8) bool {
    assert(text.len <= source_bytes_max);

    var start: u32 = 0;

    for (0..text.len + 1) |_| {
        const end: u32 = @intCast(std.mem.findScalarPos(u8, text, start, '\n') orelse text.len);
        if (end == start) return false;
        if (text[start] != '#') return false;

        for (text[start..end]) |byte| {
            switch (byte) {
                0x00...0x08, 0x0a...0x1f, 0x7f => return false,
                else => {},
            }
        }

        if (end == text.len) return true;

        start = end + 1;
    }

    unreachable;
}

inline fn value_open(writer: *Writer) std.Io.Writer.Error!void {
    assert(writer.depth <= depth_max);
    assert(writer.state == .value);

    if (writer.depth == 0) return;

    const frame = &writer.frames[writer.depth - 1];

    if (frame.flags.inline_table) {
        assert(frame.flags.key_pending);

        frame.flags.key_pending = false;

        return;
    }

    assert(frame.remaining > 0);

    try item_separator_write(writer, frame);

    frame.remaining -= 1;
}

inline fn value_close(writer: *Writer) std.Io.Writer.Error!void {
    assert(writer.depth <= depth_max);
    assert(writer.state == .value);

    if (writer.depth > 0) return;

    try put_byte(writer.out, '\n');

    writer.state = .line;
}

fn item_separator_write(writer: *Writer, frame: *Frame) align(64) std.Io.Writer.Error!void {
    assert(frame.remaining > 0);
    assert(frame.level <= depth_max);

    const items = frame.flags.items;

    frame.flags.items = true;

    if (frame.flags.vertical) {
        const start: u32 = if (items) 0 else 1;
        return indent_write(writer, .{ .level = frame.level, .start = start });
    }

    if (items) return put(writer.out, ", ");
    if (frame.flags.inline_table) return put_byte(writer.out, ' ');
}

fn indent_write(writer: *Writer, indent: Indent) std.Io.Writer.Error!void {
    assert(indent.level <= depth_max);
    assert(indent.start <= 1);

    const out = writer.out;
    const width = indent.level * indent_width;
    if (width < writer.indent_bound) return put(out, separator_bytes[indent.start .. 2 + width]);

    try out.writeAll(separator_bytes[indent.start..2]);
    try out.writeAll(writer.margin);
    try out.splatByteAll(' ', width);
}

pub fn splice_open(writer: *Writer, splice: Splice) void {
    assert(writer.depth == 0);
    assert(writer.state == .line);
    assert(splice.margin.len <= source_bytes_max);

    var flags = frame_flags_empty;

    flags.single_line = splice.single_line;

    writer.frames[0] = .{ .flags = flags, .level = 0, .remaining = 1 };
    writer.depth = 1;
    writer.state = .value;

    margin_set(writer, splice.margin);
}

pub fn splice_close(writer: *Writer) void {
    assert(writer.depth == 1);
    assert(writer.frames[0].remaining == 0);

    writer.depth = 0;
    writer.state = .line;

    margin_set(writer, "");
}

pub fn margin_set(writer: *Writer, margin: []const u8) void {
    assert(margin.len <= source_bytes_max);

    writer.indent_bound = if (margin.len == 0) indent_spaces_max + 1 else 0;
    writer.margin = margin;
}

pub fn container_open(writer: *Writer, opening: Opening) align(64) std.Io.Writer.Error!void {
    assert(writer.depth < depth_max);
    assert(opening.count <= source_bytes_max);

    try value_open(writer);

    const parent = if (writer.depth > 0) writer.frames[writer.depth - 1] else frame_outside;
    const version_single = opening.inline_table and writer.options.version == .v1_0;
    const single_line = parent.flags.single_line or version_single;
    const wide = writer.options.layout == .vertical and opening.count >= 2;
    const vertical = wide and !single_line;
    const level: u8 = parent.level + @intFromBool(vertical);

    var flags = frame_flags_empty;

    flags.inline_table = opening.inline_table;
    flags.single_line = single_line;
    flags.vertical = vertical;

    writer.frames[writer.depth] = .{ .flags = flags, .level = level, .remaining = opening.count };
    writer.depth += 1;

    try put_byte(writer.out, if (opening.inline_table) '{' else '[');
}

pub noinline fn container_close(writer: *Writer) align(64) std.Io.Writer.Error!void {
    assert(writer.depth > 0);
    assert(writer.state == .value);

    const frame = writer.frames[writer.depth - 1];

    assert(frame.remaining == 0);
    assert(!frame.flags.key_pending);

    if (frame.flags.vertical) {
        const closing: u8 = if (frame.flags.inline_table) '}' else ']';

        assert(frame.level > 0);

        try indent_write(writer, .{ .level = frame.level - 1, .start = 0 });
        try put_byte(writer.out, closing);
    } else {
        try compact_close_write(writer.out, frame.flags);
    }

    writer.depth -= 1;

    try value_close(writer);
}

fn compact_close_write(out: *std.Io.Writer, flags: FrameFlags) std.Io.Writer.Error!void {
    assert(!flags.vertical);
    assert(!flags.key_pending);

    if (!flags.inline_table) return put_byte(out, ']');
    if (flags.items) return put(out, " }");

    try put_byte(out, '}');
}

pub fn key_path_write(
    out: *std.Io.Writer,
    path: []const []const u8,
) align(64) std.Io.Writer.Error!void {
    assert(path.len > 0);
    assert(path.len <= depth_max);

    try key_segment_write(out, path[0]);

    for (path[1..]) |segment| {
        try put_byte(out, '.');
        try key_segment_write(out, segment);
    }
}

fn key_segment_write(out: *std.Io.Writer, segment: []const u8) std.Io.Writer.Error!void {
    assert(segment.len <= source_bytes_max);
    assert(out.end <= out.buffer.len);

    if (bare_is(segment)) return put(out, segment);

    try put_byte(out, '"');
    try basic_write(out, .{ .clean = 0, .text = segment });
    try put_byte(out, '"');
}

fn bare_short_is(tail: []const u8) bool {
    assert(tail.len < half_count);

    for (tail) |byte| {
        if (!bare_allowed[byte]) return false;
    }

    return true;
}

fn bare_is(segment: []const u8) bool {
    assert(segment.len <= source_bytes_max);

    if (segment.len == 0) return false;

    const index = scalar.bare_skip(segment, 0);
    const rest = segment.len - index;
    if (rest >= lane_count) return false;
    if (rest < half_count) return bare_short_is(segment[index..]);

    const last = segment.len - half_count;
    const head = bare_mask_of(segment[index..]);
    const tail = bare_mask_of(segment[last..]);

    return (head | tail) == 0;
}

fn auto_styled(text: []const u8) Styled {
    assert(text.len <= source_bytes_max);

    const stop = basic_stop_find(text, 0);
    if (stop == text.len) return .{ .clean = stop, .style = .basic };

    const result: Styled = .{ .clean = stop, .style = auto_style_of(classes_of(text, stop)) };

    assert(result.clean < text.len);

    return result;
}

fn auto_style_of(classes: Classes) Style {
    assert(classes.padding == 0);

    if (classes.newline) return .basic_multiline;
    if (classes.quote_single) return .basic;
    if (classes.carriage) return .basic;
    if (classes.control) return .basic;
    if (classes.quote_double) return .literal;
    if (classes.backslash) return .literal;
    return .basic;
}

fn literal_style_of(text: []const u8, classes: Classes) Style {
    assert(text.len <= source_bytes_max);
    assert(classes.padding == 0);

    if (classes.carriage) return .basic;
    if (classes.control) return .basic;

    if (classes.newline) {
        if (std.mem.find(u8, text, "'''") != null) return .basic;
        return .literal_multiline;
    }

    if (classes.quote_single) return .basic;
    return .literal;
}

fn classes_of(text: []const u8, start: u32) Classes {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    const lanes = classes_lanes_of(text, start);
    var classes = lanes.classes;

    for (text[lanes.index..]) |byte| {
        switch (byte) {
            '\n' => classes.newline = true,
            '\r' => classes.carriage = true,
            '"' => classes.quote_double = true,
            '\'' => classes.quote_single = true,
            '\\' => classes.backslash = true,
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => classes.control = true,
            else => {},
        }
    }

    if (start > 0) {
        if (std.mem.findScalar(u8, text[0..start], '\'') != null) classes.quote_single = true;
    }

    assert(classes.padding == 0);

    return classes;
}

fn classes_lanes_of(text: []const u8, start: u32) ClassesLanes {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    const zeros: Lanes = @splat(0);
    var backslash = zeros;
    var carriage = zeros;
    var control = zeros;
    var newline = zeros;
    var quote_double = zeros;
    var quote_single = zeros;
    var index = start;

    for (0..@divFloor(text.len - start, lane_count)) |_| {
        const bytes: Chunk = text[index..][0..lane_count].*;
        const low: Lanes = @intFromBool(bytes < @as(Chunk, @splat(0x20)));
        const tab: Lanes = @intFromBool(bytes == @as(Chunk, @splat('\t')));
        const line: Lanes = @intFromBool(bytes == @as(Chunk, @splat('\n')));
        const back: Lanes = @intFromBool(bytes == @as(Chunk, @splat('\r')));
        const delete: Lanes = @intFromBool(bytes == @as(Chunk, @splat(0x7f)));

        newline |= line;
        carriage |= back;
        control |= (low & ~tab & ~line & ~back) | delete;
        quote_double |= @intFromBool(bytes == @as(Chunk, @splat('"')));
        quote_single |= @intFromBool(bytes == @as(Chunk, @splat('\'')));
        backslash |= @intFromBool(bytes == @as(Chunk, @splat('\\')));
        index += lane_count;
    }

    var classes = classes_empty;

    classes.backslash = @reduce(.Or, backslash) != 0;
    classes.carriage = @reduce(.Or, carriage) != 0;
    classes.control = @reduce(.Or, control) != 0;
    classes.newline = @reduce(.Or, newline) != 0;
    classes.quote_double = @reduce(.Or, quote_double) != 0;
    classes.quote_single = @reduce(.Or, quote_single) != 0;

    assert(index <= text.len);

    return .{ .classes = classes, .index = index };
}

fn basic_stop_find_short(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len - start < half_count);

    var index = start;

    for (text[start..]) |byte| {
        if (escape_needed[byte]) break;

        index += 1;
    }

    assert(index <= text.len);

    return index;
}

inline fn basic_stop_find(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    const index = scalar.stop_skip(text, start, scalar.stops_basic);
    const rest = text.len - index;
    if (rest >= lane_count) return index;
    if (rest < half_count) return basic_stop_find_short(text, index);

    const last: u32 = @intCast(text.len - half_count);
    const head = escape_mask_of(text[index..]);
    const tail = escape_mask_of(text[last..]);

    var result: u32 = @intCast(text.len);

    if (tail != 0) result = last + @as(u32, @ctz(tail));
    if (head != 0) result = index + @as(u32, @ctz(head));

    assert(result <= text.len);

    return result;
}

fn escape_mask_of(text: []const u8) HalfMask {
    assert(text.len >= half_count);

    const bytes: Half = text[0..half_count].*;
    const control: HalfLanes = @intFromBool(bytes < @as(Half, @splat(0x20)));
    const delete: HalfLanes = @intFromBool(bytes == @as(Half, @splat(0x7f)));
    const quote: HalfLanes = @intFromBool(bytes == @as(Half, @splat('"')));
    const backslash: HalfLanes = @intFromBool(bytes == @as(Half, @splat('\\')));

    return @bitCast(control | delete | quote | backslash);
}

fn bare_mask_of(text: []const u8) HalfMask {
    assert(text.len >= half_count);

    const bytes: Half = text[0..half_count].*;
    const folded = (bytes | @as(Half, @splat(0x20))) -% @as(Half, @splat('a'));
    const letter: HalfLanes = @intFromBool(folded < @as(Half, @splat(26)));
    const digit: HalfLanes = @intFromBool(bytes -% @as(Half, @splat('0')) < @as(Half, @splat(10)));
    const underscore: HalfLanes = @intFromBool(bytes == @as(Half, @splat('_')));
    const dash: HalfLanes = @intFromBool(bytes == @as(Half, @splat('-')));

    return @bitCast(~(letter | digit | underscore | dash));
}

fn basic_write(out: *std.Io.Writer, body: Body) align(64) std.Io.Writer.Error!void {
    assert(body.text.len <= source_bytes_max);
    assert(body.clean <= body.text.len);

    const text = body.text;
    var start: u32 = 0;
    var scan = body.clean;

    for (0..text.len + 1) |_| {
        const stop = basic_stop_find(text, scan);

        try put(out, text[start..stop]);

        if (stop == text.len) return;

        try escape_write(out, text[stop]);

        start = stop + 1;
        scan = start;
    }

    unreachable;
}

fn basic_multiline_write(out: *std.Io.Writer, body: Body) std.Io.Writer.Error!void {
    assert(body.text.len <= source_bytes_max);
    assert(body.clean <= body.text.len);

    const text = body.text;
    var start: u32 = 0;
    var scan = body.clean;
    var quote_run: u32 = 0;

    for (0..text.len + 1) |_| {
        const stop = basic_stop_find(text, scan);

        if (stop > start) {
            try put(out, text[start..stop]);

            quote_run = 0;
        }

        if (stop == text.len) return;

        quote_run = try multiline_byte_write(out, .{ .byte = text[stop], .quote_run = quote_run });
        start = stop + 1;
        scan = start;
    }

    unreachable;
}

fn multiline_byte_write(out: *std.Io.Writer, multiline: MultilineByte) std.Io.Writer.Error!u32 {
    assert(escape_needed[multiline.byte]);
    assert(multiline.quote_run <= 2);

    var quote_run: u32 = 0;

    switch (multiline.byte) {
        '\n' => try put_byte(out, '\n'),
        '"' => {
            if (multiline.quote_run == 2) {
                try put(out, "\\\"");
            } else {
                try put_byte(out, '"');

                quote_run = multiline.quote_run + 1;
            }
        },
        else => try escape_write(out, multiline.byte),
    }

    assert(quote_run <= 2);

    return quote_run;
}

fn escape_write(out: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    assert(escape_needed[byte]);
    assert(byte < 0x80);

    const short: []const u8 = switch (byte) {
        0x08 => "\\b",
        '\t' => "\\t",
        '\n' => "\\n",
        0x0c => "\\f",
        '\r' => "\\r",
        '"' => "\\\"",
        '\\' => "\\\\",
        else => "",
    };

    if (short.len > 0) return put(out, short);

    const hex = "0123456789ABCDEF";
    const unicode = [6]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] };

    try put(out, &unicode);
}

fn integer_format(value: i64, buffer: *[integer_bytes_max]u8) []const u8 {
    assert(std.math.log10_int(@abs(value) | 1) < integer_bytes_max);

    var magnitude: u64 = @abs(value);
    var start: u32 = integer_bytes_max;

    for (0..integer_bytes_max) |_| {
        if (magnitude < 100) break;

        start -= 2;
        buffer[start..][0..2].* = std.fmt.digits2(@intCast(magnitude % 100));
        magnitude = @divFloor(magnitude, 100);
    }

    if (magnitude >= 10) {
        start -= 2;
        buffer[start..][0..2].* = std.fmt.digits2(@intCast(magnitude));
    } else {
        start -= 1;
        buffer[start] = '0' + @as(u8, @intCast(magnitude));
    }

    if (value < 0) {
        start -= 1;
        buffer[start] = '-';
    }

    assert(start < integer_bytes_max);

    return buffer[start..];
}

fn float_format(comptime T: type, value: T, buffer: *[float_bytes_max]u8) []const u8 {
    comptime assert(@typeInfo(T) == .float);
    comptime assert(@bitSizeOf(T) <= 64);
    assert(@intFromBool(std.math.signbit(value)) + float_unsigned_bytes_max <= float_bytes_max);

    if (std.math.isNan(value)) return if (std.math.signbit(value)) "-nan" else "nan";
    if (std.math.isInf(value)) return if (value < 0) "-inf" else "inf";
    if (value == 0) return if (std.math.signbit(value)) "-0.0" else "0.0";

    var decimal: Decimal = undefined;

    decimal_of(T, value, &decimal);

    const exponent = decimal.exponent + @as(i32, @intCast(decimal.digit_count)) - 1;
    const near = exponent >= positional_exponent_min and exponent <= positional_exponent_max;

    const filled = switch (near) {
        true => positional_fill(&decimal, buffer),
        false => scientific_fill(&decimal, buffer),
    };

    const result = buffer[0..filled];

    assert(std.mem.findAny(u8, result, ".e") != null);

    return result;
}

fn decimal_of(comptime T: type, value: T, decimal: *Decimal) void {
    comptime assert(@typeInfo(T) == .float);
    assert(std.math.isFinite(value));
    assert(value != 0);

    const bits: @Int(.unsigned, @bitSizeOf(T)) = @bitCast(value);
    const mantissa_bits = std.math.floatMantissaBits(T);
    const exponent_bits = std.math.floatExponentBits(T);
    const tables = &std.fmt.float.Backend64_TablesFull;

    const shortest = std.fmt.float.binaryToDecimal(
        u64,
        bits,
        mantissa_bits,
        exponent_bits,
        false,
        tables,
    );

    var mantissa = shortest.mantissa;
    var exponent = shortest.exponent;

    for (0..float_digit_count_max) |_| {
        if (mantissa % 10 != 0) break;

        mantissa = @divExact(mantissa, 10);
        exponent += 1;
    }

    assert(mantissa > 0);
    assert(mantissa < 100_000_000_000_000_000);

    var digits: [float_digit_count_max]u8 = undefined;
    var start: u32 = float_digit_count_max;

    for (0..float_digit_count_max) |_| {
        start -= 1;
        digits[start] = '0' + @as(u8, @intCast(mantissa % 10));
        mantissa = @divFloor(mantissa, 10);

        if (mantissa == 0) break;
    }

    const count = float_digit_count_max - start;

    @memcpy(decimal.digits[0..count], digits[start..]);

    decimal.digit_count = count;
    decimal.exponent = exponent;
    decimal.negative = shortest.sign;
}

fn positional_fill(decimal: *const Decimal, buffer: *[float_bytes_max]u8) u32 {
    assert(decimal.digit_count > 0);
    assert(decimal.digit_count <= float_digit_count_max);

    const digits = decimal.digits[0..decimal.digit_count];
    const point = decimal.exponent + @as(i32, @intCast(decimal.digit_count));
    const start: u32 = @intFromBool(decimal.negative);

    buffer[0] = '-';

    var length: u32 = start;

    if (decimal.exponent >= 0) {
        const zeros: u32 = @intCast(decimal.exponent);

        @memcpy(buffer[length..][0..digits.len], digits);
        @memset(buffer[length + digits.len ..][0..zeros], '0');
        length += @intCast(digits.len + zeros);

        @memcpy(buffer[length..][0..2], ".0");
        length += 2;
    } else if (point > 0) {
        const whole: u32 = @intCast(point);

        @memcpy(buffer[length..][0..whole], digits[0..whole]);
        buffer[length + whole] = '.';
        @memcpy(buffer[length + whole + 1 ..][0 .. digits.len - whole], digits[whole..]);
        length += @as(u32, @intCast(digits.len)) + 1;
    } else {
        const zeros: u32 = @intCast(-point);

        @memcpy(buffer[length..][0..2], "0.");
        @memset(buffer[length + 2 ..][0..zeros], '0');
        @memcpy(buffer[length + 2 + zeros ..][0..digits.len], digits);
        length += 2 + zeros + @as(u32, @intCast(digits.len));
    }

    assert(length > start);
    assert(length <= float_bytes_max);

    return length;
}

fn scientific_fill(decimal: *const Decimal, buffer: *[float_bytes_max]u8) u32 {
    assert(decimal.digit_count > 0);
    assert(decimal.digit_count <= float_digit_count_max);

    const start: u32 = @intFromBool(decimal.negative);

    buffer[0] = '-';
    buffer[start] = decimal.digits[0];

    var length: u32 = start + 1;

    if (decimal.digit_count > 1) {
        const fraction = decimal.digits[1..decimal.digit_count];

        buffer[length] = '.';

        @memcpy(buffer[length + 1 ..][0..fraction.len], fraction);
        length += @as(u32, @intCast(fraction.len)) + 1;
    }

    const scientific = decimal.exponent + @as(i32, @intCast(decimal.digit_count)) - 1;

    buffer[length] = 'e';

    buffer[length + 1] = '-';
    length += 1 + @as(u32, @intFromBool(scientific < 0));

    var exponent_buffer: [integer_bytes_max]u8 = undefined;
    const exponent_text = integer_format(@abs(scientific), &exponent_buffer);

    @memcpy(buffer[length..][0..exponent_text.len], exponent_text);
    length += @intCast(exponent_text.len);

    assert(length > start + 2);
    assert(length <= float_bytes_max);

    return length;
}

const testing = std.testing;

const test_options_vertical: Writer.Options = .{
    .layout = .vertical,
    .strings = .auto,
    .version = .v1_1,
};

const TestSink = struct {
    buffer: [4096]u8,
    sink: std.Io.Writer,
    writer: Writer,

    fn init(test_sink: *TestSink, options: Writer.Options) void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);

        test_sink.sink = .fixed(&test_sink.buffer);

        test_sink.writer.init(&test_sink.sink, options);

        assert(test_sink.sink.end == 0);
    }

    fn written(test_sink: *const TestSink) []const u8 {
        assert(test_sink.sink.end <= test_sink.buffer.len);
        assert(test_sink.writer.depth == 0);

        return test_sink.sink.buffered();
    }
};

const StringCase = struct {
    expected: []const u8,
    strings: Writer.Strings,
    text: []const u8,
};

test "each string takes the style its options and its bytes call for" {
    const cases = [_]StringCase{
        .{ .expected = "\"plain\"", .strings = .auto, .text = "plain" },
        .{ .expected = "\"\"", .strings = .auto, .text = "" },
        .{ .expected = "'C:\\path'", .strings = .auto, .text = "C:\\path" },
        .{ .expected = "'say \"hi\"'", .strings = .auto, .text = "say \"hi\"" },
        .{ .expected = "\"it's \\\"x\\\"\"", .strings = .auto, .text = "it's \"x\"" },
        .{ .expected = "\"\"\"\na\nb\"\"\"", .strings = .auto, .text = "a\nb" },
        .{ .expected = "\"tab\\there\"", .strings = .auto, .text = "tab\there" },
        .{ .expected = "'tab\there\"'", .strings = .auto, .text = "tab\there\"" },
        .{ .expected = "\"\\r\\\\\"", .strings = .auto, .text = "\r\\" },
        .{ .expected = "\"\\u0001\\u007F\\b\\f\"", .strings = .auto, .text = "\x01\x7f\x08\x0c" },
        .{ .expected = "\"caf\u{e9}\"", .strings = .auto, .text = "caf\u{e9}" },
        .{ .expected = "'plain'", .strings = .literal, .text = "plain" },
        .{ .expected = "\"it's\"", .strings = .literal, .text = "it's" },
        .{ .expected = "'''\na\n'b'\"'''", .strings = .literal, .text = "a\n'b'\"" },
        .{ .expected = "\"a\\n'''\"", .strings = .literal, .text = "a\n'''" },
        .{ .expected = "\"a\\r\\nb\"", .strings = .literal, .text = "a\r\nb" },
        .{ .expected = "\"C:\\\\path\"", .strings = .basic, .text = "C:\\path" },
        .{ .expected = "\"a\\nb\"", .strings = .basic, .text = "a\nb" },
    };

    for (cases) |case| {
        var test_sink: TestSink = undefined;
        var options = test_options_vertical;

        options.strings = case.strings;

        test_sink.init(options);

        try test_sink.writer.key(&.{"k"});
        try test_sink.writer.string(case.text);

        test_sink.writer.finish();

        const written = test_sink.written();

        try testing.expectEqualStrings("k = ", written[0..4]);
        try testing.expectEqualStrings(case.expected, written[4 .. written.len - 1]);
    }
}

test "a multi-line basic string escapes a carriage return and each third quote in a run" {
    var test_sink: TestSink = undefined;

    test_sink.init(test_options_vertical);

    try test_sink.writer.key(&.{"k"});
    try test_sink.writer.string("x\r\n\"\"\"\"\"\"y\"\"");

    test_sink.writer.finish();

    const expected = "k = \"\"\"\nx\\r\n\"\"\\\"\"\"\\\"y\"\"\"\"\"\n";

    try testing.expectEqualStrings(expected, test_sink.written());
}

test "keys are bare when every byte allows it and quoted with escapes otherwise" {
    var test_sink: TestSink = undefined;

    test_sink.init(test_options_vertical);

    try test_sink.writer.key(&.{ "a-b_C9", "", "dotted.key", "sp ace", "quote\"", "\u{e9}" });
    try test_sink.writer.integer(1);

    const long: [40]u8 = @splat('k');

    try test_sink.writer.key(&.{&long});
    try test_sink.writer.integer(2);

    test_sink.writer.finish();

    const expected = "a-b_C9.\"\".\"dotted.key\".\"sp ace\".\"quote\\\"\".\"\u{e9}\" = 1\n" ++
        long ++ " = 2\n";

    try testing.expectEqualStrings(expected, test_sink.written());
}

test "invalid UTF-8 and an invalid datetime are refused before any byte is written" {
    var test_sink: TestSink = undefined;

    test_sink.init(test_options_vertical);

    try testing.expectError(error.Utf8Invalid, test_sink.writer.key(&.{ "ok", "\xff" }));
    try testing.expectError(error.Utf8Invalid, test_sink.writer.table(&.{"\xc3"}));
    try testing.expectError(error.Utf8Invalid, test_sink.writer.comment("#\xfe"));
    try testing.expectEqual(@as(usize, 0), test_sink.written().len);

    try test_sink.writer.key(&.{"k"});
    try testing.expectError(error.Utf8Invalid, test_sink.writer.string("a\xffb"));

    var invalid = try datetime_module.parse("1979-05-27", .v1_1);

    invalid.month = 13;

    try testing.expectError(error.DatetimeInvalid, test_sink.writer.datetime(invalid));
    try testing.expectEqualStrings("k = ", test_sink.written());

    try test_sink.writer.boolean(true);

    test_sink.writer.finish();
}

const FloatCase = struct {
    expected: []const u8,
    value: f64,
};

test "floats are positional near one and scientific far from it, always with a point or e" {
    const cases = [_]FloatCase{
        .{ .expected = "0.0", .value = 0.0 },
        .{ .expected = "-0.0", .value = -0.0 },
        .{ .expected = "1.0", .value = 1.0 },
        .{ .expected = "100.0", .value = 100.0 },
        .{ .expected = "0.1", .value = 0.1 },
        .{ .expected = "-12.375", .value = -12.375 },
        .{ .expected = "1000000000000000.0", .value = 1e15 },
        .{ .expected = "1e16", .value = 1e16 },
        .{ .expected = "1.5e16", .value = 1.5e16 },
        .{ .expected = "0.00001", .value = 1e-5 },
        .{ .expected = "0.000012345", .value = 1.2345e-5 },
        .{ .expected = "1e-6", .value = 1e-6 },
        .{ .expected = "-2.5e-7", .value = -2.5e-7 },
        .{ .expected = "5e-324", .value = 5e-324 },
        .{ .expected = "1.7976931348623157e308", .value = std.math.floatMax(f64) },
        .{ .expected = "inf", .value = std.math.inf(f64) },
        .{ .expected = "-inf", .value = -std.math.inf(f64) },
        .{ .expected = "nan", .value = std.math.nan(f64) },
        .{ .expected = "-nan", .value = -std.math.nan(f64) },
    };

    for (cases) |case| {
        var buffer: [float_bytes_max]u8 = undefined;

        try testing.expectEqualStrings(case.expected, float_format(f64, case.value, &buffer));
    }
}

test "a float read back from its written form has the same bits" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_f10a7);
    const random = prng.random();

    for (0..20_000) |_| {
        const bits = random.int(u64);
        const value: f64 = @bitCast(bits);

        var buffer: [float_bytes_max]u8 = undefined;
        const text = float_format(f64, value, &buffer);
        const parsed = try std.fmt.parseFloat(f64, text);

        if (std.math.isNan(value)) {
            const expected = if (std.math.signbit(value)) "-nan" else "nan";

            try testing.expect(std.math.isNan(parsed));
            try testing.expectEqualStrings(expected, text);
        } else {
            try testing.expectEqual(bits, @as(u64, @bitCast(parsed)));
        }
    }
}

test "integers keep their sign and their extremes" {
    const values = [_]i64{
        0,
        7,
        -7,
        10,
        99,
        100,
        -1000,
        std.math.maxInt(i64),
        std.math.minInt(i64),
    };

    const texts = [_][]const u8{
        "0",
        "7",
        "-7",
        "10",
        "99",
        "100",
        "-1000",
        "9223372036854775807",
        "-9223372036854775808",
    };

    for (values, texts) |value, text| {
        var buffer: [integer_bytes_max]u8 = undefined;

        try testing.expectEqualStrings(text, integer_format(value, &buffer));
    }
}

fn test_arrays_write(writer: *Writer) !void {
    assert(writer.depth == 0);
    assert(writer.state == .line);

    try writer.key(&.{"empty"});
    try writer.array_begin(0);
    try writer.array_end();
    try writer.key(&.{"one"});
    try writer.array_begin(1);
    try writer.integer(1);
    try writer.array_end();
    try writer.key(&.{"many"});
    try writer.array_begin(3);
    try writer.integer(1);
    try writer.array_begin(2);
    try writer.string("a");
    try writer.string("b");
    try writer.array_end();
    try writer.array_begin(1);
    try writer.boolean(false);
    try writer.array_end();
    try writer.array_end();

    writer.finish();
}

test "arrays are vertical from two elements under the vertical layout and compact otherwise" {
    var test_sink: TestSink = undefined;

    test_sink.init(test_options_vertical);

    try test_arrays_write(&test_sink.writer);

    const vertical =
        \\empty = []
        \\one = [1]
        \\many = [
        \\    1,
        \\    [
        \\        "a",
        \\        "b",
        \\    ],
        \\    [false],
        \\]
        \\
    ;

    try testing.expectEqualStrings(vertical, test_sink.written());

    var compact = test_options_vertical;

    compact.layout = .compact;

    test_sink.init(compact);

    try test_arrays_write(&test_sink.writer);

    const expected = "empty = []\none = [1]\nmany = [1, [\"a\", \"b\"], [false]]\n";

    try testing.expectEqualStrings(expected, test_sink.written());
}

fn test_inline_write(writer: *Writer) !void {
    assert(writer.depth == 0);
    assert(writer.state == .line);

    try writer.key(&.{"t"});
    try writer.inline_table_begin(3);
    try writer.key(&.{"a"});
    try writer.integer(1);
    try writer.key(&.{ "b", "c" });
    try writer.array_begin(2);
    try writer.integer(2);
    try writer.integer(3);
    try writer.array_end();
    try writer.key(&.{"d"});
    try writer.inline_table_begin(0);
    try writer.inline_table_end();
    try writer.inline_table_end();
    try writer.key(&.{"u"});
    try writer.inline_table_begin(1);
    try writer.key(&.{"e"});
    try writer.float(0.5);
    try writer.inline_table_end();

    writer.finish();
}

test "an inline table is vertical only under 1.1 and on one line under 1.0" {
    var test_sink: TestSink = undefined;

    test_sink.init(test_options_vertical);

    try test_inline_write(&test_sink.writer);

    const relaxed =
        \\t = {
        \\    a = 1,
        \\    b.c = [
        \\        2,
        \\        3,
        \\    ],
        \\    d = {},
        \\}
        \\u = { e = 0.5 }
        \\
    ;

    try testing.expectEqualStrings(relaxed, test_sink.written());

    var strict = test_options_vertical;

    strict.version = .v1_0;

    test_sink.init(strict);

    try test_inline_write(&test_sink.writer);

    const expected = "t = { a = 1, b.c = [2, 3], d = {} }\nu = { e = 0.5 }\n";

    try testing.expectEqualStrings(expected, test_sink.written());
}

test "a header takes a blank line unless it is the first thing written, and comments stand alone" {
    var test_sink: TestSink = undefined;

    test_sink.init(test_options_vertical);

    try test_sink.writer.table(&.{"first"});
    try test_sink.writer.comment("# note");
    try test_sink.writer.key(&.{"k"});
    try test_sink.writer.integer(1);
    try test_sink.writer.table_array(&.{ "items", "x y" });
    try test_sink.writer.comment("#");
    try test_sink.writer.table_array(&.{ "items", "x y" });

    test_sink.writer.finish();

    const expected =
        \\[first]
        \\# note
        \\k = 1
        \\
        \\[[items."x y"]]
        \\#
        \\
        \\[[items."x y"]]
        \\
    ;

    try testing.expectEqualStrings(expected, test_sink.written());
}

test "a comment of several lines writes each line whole and reads back as nothing" {
    var test_sink: TestSink = undefined;

    test_sink.init(test_options_vertical);

    try test_sink.writer.comment("# first\n#\tsecond\n##");
    try test_sink.writer.key(&.{"k"});
    try test_sink.writer.integer(1);

    test_sink.writer.finish();

    try testing.expectEqualStrings("# first\n#\tsecond\n##\nk = 1\n", test_sink.written());

    const Fixed = document_module.DocumentType(.{
        .line_count_max = null,
        .node_count_max = 8,
        .text_bytes_max = 64,
    });

    var fixed: Fixed = undefined;

    try fixed.parse(test_sink.written(), .{ .version = .v1_1 });
    try testing.expectEqual(@as(u32, 1), fixed.count_of(fixed.root()));
    try testing.expectEqual(@as(?i64, 1), fixed.integer_of(fixed.member(fixed.root(), "k").?));
}

test "datetimes go through Datetime.format and gain seconds under 1.0" {
    var test_sink: TestSink = undefined;
    const short = try datetime_module.parse("1979-05-27T07:32Z", .v1_1);

    test_sink.init(test_options_vertical);

    try test_sink.writer.key(&.{"at"});
    try test_sink.writer.datetime(short);

    var strict = test_options_vertical;

    strict.version = .v1_0;

    try testing.expectEqualStrings("at = 1979-05-27T07:32Z\n", test_sink.written());

    test_sink.init(strict);

    try test_sink.writer.key(&.{"at"});
    try test_sink.writer.datetime(short);
    try testing.expectEqualStrings("at = 1979-05-27T07:32:00Z\n", test_sink.written());
}

test Writer {
    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = undefined;

    writer.init(&sink, .{ .layout = .vertical, .strings = .auto, .version = .v1_1 });

    try writer.key(&.{"title"});
    try writer.string("TOML");
    try writer.table(&.{"server"});
    try writer.key(&.{"ports"});
    try writer.array_begin(2);
    try writer.integer(8000);
    try writer.integer(8001);
    try writer.array_end();
    try writer.table_array(&.{"user"});
    try writer.key(&.{"name"});
    try writer.string("Tom");

    writer.finish();

    const expected =
        \\title = "TOML"
        \\
        \\[server]
        \\ports = [
        \\    8000,
        \\    8001,
        \\]
        \\
        \\[[user]]
        \\name = "Tom"
        \\
    ;

    try testing.expectEqualStrings(expected, sink.buffered());
}
