const std = @import("std");

const toml = @import("toml");

const assert = std.debug.assert;

const Datetime = toml.Datetime;

const Document = toml.DocumentType(.{
    .line_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const Mode = enum {
    production,
    staging,
};

const Replica = struct {
    name: []const u8,
    weight: u8 = 1,
};

const Server = struct {
    deployed: ?Datetime = null,
    host: []const u8,
    mode: Mode,
    port: u16 = 8080,
    replicas: []const Replica,

    pub const toml = .{ .host = "address" };
};

const source =
    \\[server]
    \\address = "localhost"
    \\mode = "staging"
    \\deployed = 2026-10-21T09:30:00-06:00
    \\
    \\[[server.replicas]]
    \\name = "alpha"
    \\
    \\[[server.replicas]]
    \\name = "beta"
    \\weight = 3
    \\
;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(source.len <= toml.limits.source_bytes_max);

    const document = try init.gpa.create(Document);
    defer init.gpa.destroy(document);

    try document.parse(source, .{ .version = .v1_1 });

    var region_buffer: [1024]u8 = undefined;
    var region: toml.Region = .init(&region_buffer);
    var server: Server = undefined;
    var position: toml.Position = undefined;
    const root = document.root();
    const node = document.path_find(root, &.{"server"}) orelse return error.ServerMissing;

    toml.decode(Server, &region, &document.document, node, &server, .{
        .diagnostic = &position,
        .unknown_members = .refused,
    }) catch |err| {
        std.debug.print("{d}:{d}: {s}\n", .{ position.line, position.column, toml.message(err) });

        return err;
    };

    std.debug.print("{s}:{d} {t}, {d} replicas\n", .{
        server.host,
        server.port,
        server.mode,
        server.replicas.len,
    });

    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: toml.Writer = undefined;

    writer.init(&sink, .{ .layout = .vertical, .strings = .auto, .version = .v1_1 });

    try toml.encode(Server, &writer, &server);

    writer.finish();

    std.debug.print("{s}", .{sink.buffered()});
}
