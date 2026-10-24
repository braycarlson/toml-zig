const std = @import("std");

const toml = @import("toml");

const assert = std.debug.assert;

const Storage = toml.StorageType(.{
    .line_count_max = null,
    .node_count_max = 64,
    .text_bytes_max = 1024,
});

const StorageKept = toml.StorageType(.{
    .line_count_max = 64,
    .node_count_max = 64,
    .text_bytes_max = 1024,
});

const config =
    \\# The service listens here.
    \\[server]
    \\port = 0x1F90 # hex, as the ops team writes it
    \\debug = true
    \\
;

const overrides =
    \\[server]
    \\port = 9090
    \\tags = ["canary"]
    \\
;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(overrides.len <= toml.limits.source_bytes_max);

    const storage = try init.gpa.create(Storage);
    defer init.gpa.destroy(storage);

    var document: toml.Document = undefined;

    document.init(storage.storage());

    const root = document.root();
    const server = try document.set(root, "server", .{ .table = .header });
    const tags = try document.set(server, "tags", .{ .array = .inline_array });

    _ = try document.set(root, "name", .{ .string = "toml-zig" });
    _ = try document.set(server, "host", .{ .string = "localhost" });
    _ = try document.set(server, "port", .{ .integer = 8080 });
    _ = try document.set(server, "debug", .{ .boolean = true });
    _ = try document.append(tags, .{ .string = "stable" });

    document.remove(document.member(server, "debug") orelse return error.DebugMissing);

    const override_storage = try init.gpa.create(Storage);
    defer init.gpa.destroy(override_storage);

    var override: toml.Document = undefined;

    try override.parse(override_storage.storage(), overrides, .{ .version = .v1_1 });
    try document.merge(&override, .{ .arrays = .join });

    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write(&sink, .{ .layout = .compact, .strings = .auto, .version = .v1_1 });

    std.debug.print("{s}", .{sink.buffered()});

    const kept_storage = try init.gpa.create(StorageKept);
    defer init.gpa.destroy(kept_storage);

    var kept: toml.Document = undefined;

    try kept.parse(kept_storage.storage(), config, .{ .version = .v1_1 });

    const kept_server = kept.member(kept.root(), "server") orelse return error.ServerMissing;

    _ = try kept.set(kept_server, "port", .{ .integer = 9090 });

    kept.remove(kept.member(kept_server, "debug") orelse return error.DebugMissing);

    sink = .fixed(&buffer);

    try kept.write(&sink, .{ .version = .v1_1 });

    std.debug.print("\n{s}", .{sink.buffered()});
}
