const std = @import("std");

const toml = @import("toml");

const assert = std.debug.assert;

const output_bytes_max: u32 = 1024;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(output_bytes_max >= 512);

    var buffer: [output_bytes_max]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: toml.Writer = undefined;

    writer.init(&sink, .{ .layout = .vertical, .strings = .auto, .version = .v1_1 });

    try writer.comment("# written by examples/write.zig");
    try writer.key(&.{"title"});
    try writer.string("toml-zig");
    try writer.table(&.{"server"});
    try writer.key(&.{"ports"});
    try writer.array_begin(2);
    try writer.integer(8000);
    try writer.integer(8001);
    try writer.array_end();
    try writer.key(&.{"limits"});
    try writer.inline_table_begin(2);
    try writer.key(&.{"memory"});
    try writer.string("8g");
    try writer.key(&.{"ratio"});
    try writer.float(0.75);
    try writer.inline_table_end();

    for ([_][]const u8{ "alpha", "beta" }) |name| {
        try writer.table_array(&.{ "server", "replica" });
        try writer.key(&.{"name"});
        try writer.string(name);
    }

    writer.finish();

    std.debug.print("{s}", .{sink.buffered()});
}
