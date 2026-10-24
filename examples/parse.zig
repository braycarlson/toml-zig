const std = @import("std");

const toml = @import("toml");

const assert = std.debug.assert;

const Document = toml.DocumentType(.{
    .line_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const source =
    \\[[servers]]
    \\host = "localhost"
    \\port = 8080
    \\
    \\[[servers]]
    \\host = "backup"
    \\port = 8081
    \\
;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(source.len <= toml.limits.source_bytes_max);

    const document = try init.gpa.create(Document);
    defer init.gpa.destroy(document);

    document.parse(source, .{ .version = .v1_1 }) catch |err| {
        const diagnostic = document.diagnostic();

        std.debug.print("{d}:{d}: {s}\n", .{
            diagnostic.line,
            diagnostic.column,
            toml.message(err),
        });

        return err;
    };

    const root = document.root();
    const first = document.path_find(root, &.{ "servers", "0" }) orelse return error.ServerMissing;
    const position = document.position_of(first) orelse return error.PositionMissing;
    const host = document.find("servers[0].host") orelse return error.HostMissing;
    const port = document.find("servers[0].port") orelse return error.PortMissing;

    std.debug.print("server: line {d}\n", .{position.line});

    switch (host) {
        .string => |text| std.debug.print("host: {s}\n", .{text}),
        else => return error.HostInvalid,
    }

    switch (port) {
        .integer => |number| std.debug.print("port: {d}\n", .{number}),
        else => return error.PortInvalid,
    }
}
