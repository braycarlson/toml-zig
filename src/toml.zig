const std = @import("std");
const assert = std.debug.assert;

const codec = @import("codec.zig");
const datetime_module = @import("datetime.zig");
const document_module = @import("document.zig");
const region_module = @import("region.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

pub const Capacity = storage_module.Capacity;
pub const CapacityError = document_module.CapacityError;
pub const Datetime = datetime_module.Datetime;
pub const DecodeError = codec.DecodeError;
pub const DecodeOptions = codec.DecodeOptions;
pub const Document = document_module.Document;
pub const DocumentType = document_module.DocumentType;
pub const Entries = document_module.Entries;

pub const Error = DecodeError ||
    Document.EditError ||
    Document.Error ||
    std.mem.Allocator.Error ||
    Writer.Error;

pub const Items = document_module.Items;
pub const Kind = document_module.Kind;
pub const MismatchError = codec.MismatchError;
pub const Node = document_module.Node;
pub const Position = document_module.Position;
pub const Region = region_module.Region;
pub const Storage = storage_module.Storage;
pub const StorageType = storage_module.StorageType;
pub const SyntaxError = document_module.SyntaxError;
pub const Value = document_module.Value;
pub const ValueError = writer_module.Writer.ValueError;
pub const Version = document_module.Version;
pub const Writer = writer_module.Writer;

pub const decode = codec.decode;
pub const encode = codec.encode;

pub fn message(err: Error) []const u8 {
    assert(@errorName(err).len > 0);

    const result: []const u8 = switch (err) {
        error.ArrayInvalid => "missing comma between array elements",
        error.ArrayUnterminated => "unclosed array, expected `]`",
        error.CharacterInvalid => "invalid control character in string",
        error.CommentInvalid => "invalid comment character",
        error.DatetimeInvalid => "invalid datetime",
        error.DepthExceeded => "nesting is deeper than the limit",
        error.EqualsMissing => "key with no value, expected `=`",
        error.EscapeInvalid => "invalid escape sequence",
        error.ExpressionInvalid => "expected newline, `#`",
        error.InlineTableInvalid => "missing comma between key-value pairs",
        error.InlineTableUnterminated => "unclosed inline table, expected `}`",
        error.KeyDuplicate => "duplicate key",
        error.KeyInvalid => "invalid key",
        error.LinesExhausted => "the document holds more lines than its capacity",
        error.MemberMissing => "missing key",
        error.MemberUnknown => "unknown key",
        error.Mismatch => "the value does not match the field's type",
        error.NewlineInvalid => "carriage return must be followed by newline",
        error.NodesExhausted => "the document holds more nodes than its capacity",
        error.NumberInvalid => "invalid number",
        error.OutOfMemory => "out of memory",
        error.RegionFull => "the region is full",
        error.StringInvalid => "too many quotes closing a multi-line string",
        error.StringUnterminated => "unclosed string",
        error.TableInvalid => "invalid table header",
        error.TableRedefined => "table defined more than once",
        error.TableUnterminated => "unclosed table, expected `]`",
        error.TextExhausted => "the document holds more text than its capacity",
        error.Utf8Invalid => "invalid UTF-8",
        error.ValueInvalid => "invalid value",
        error.ValueMissing => "missing value",
        error.WriteFailed => "the output could not be written",
    };

    assert(result.len > 0);

    return result;
}

pub const limits = struct {
    pub const depth_max: u32 = document_module.depth_max;
    pub const key_segment_count_max: u32 = document_module.key_segment_count_max;
    pub const source_bytes_max: u32 = document_module.source_bytes_max;
};

test message {
    const Config = DocumentType(.{
        .line_count_max = null,
        .node_count_max = 16,
        .text_bytes_max = 64,
    });

    const config = try std.testing.allocator.create(Config);
    defer std.testing.allocator.destroy(config);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    config.parse("ports = [8000, 8001\n", .{}) catch |err| {
        const diagnostic = config.diagnostic();

        try writer.print("{d}:{d}: {s}", .{ diagnostic.line, diagnostic.column, message(err) });
    };

    try std.testing.expectEqualStrings("1:20: unclosed array, expected `]`", writer.buffered());

    var region_buffer: [256]u8 = undefined;
    var region: Region = .init(&region_buffer);
    var diagnostic: Position = undefined;
    var target: struct { port: u16 } = undefined;

    try config.parse("port = \"80\"\n", .{});

    const result = decode(@TypeOf(target), &region, &config.document, config.root(), &target, .{
        .diagnostic = &diagnostic,
    });

    const sentence = "the value does not match the field's type";

    try std.testing.expectError(error.Mismatch, result);
    try std.testing.expectEqualStrings(sentence, message(error.Mismatch));
    try std.testing.expectEqual(Position{ .column = 8, .line = 1, .offset = 7 }, diagnostic);

    const names = @typeInfo(Error).error_set.error_names.?;

    @setEvalBranchQuota(64 * names.len * names.len);

    inline for (names, 0..) |left, index| {
        const text = message(@field(Error, left));

        try std.testing.expect(text.len > 0);

        inline for (names[index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, text, message(@field(Error, right))));
        }
    }
}
