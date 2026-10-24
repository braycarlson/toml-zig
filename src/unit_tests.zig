const std = @import("std");

const assert = std.debug.assert;

comptime {
    _ = @import("bounded.zig");
    _ = @import("codec.zig");
    _ = @import("datetime.zig");
    _ = @import("document.zig");
    _ = @import("document_tests.zig");
    _ = @import("edit.zig");
    _ = @import("hash_index.zig");
    _ = @import("parser.zig");
    _ = @import("region.zig");
    _ = @import("scalar.zig");
    _ = @import("serializer.zig");
    _ = @import("splicer.zig");
    _ = @import("splicer_tests.zig");
    _ = @import("storage.zig");
    _ = @import("tidy.zig");
    _ = @import("toml.zig");
    _ = @import("writer.zig");
}

test "every public declaration compiles" {
    const toml = @import("toml.zig");

    const Document = toml.DocumentType(.{
        .line_count_max = null,
        .node_count_max = 64,
        .text_bytes_max = 1024,
    });

    comptime assert(@hasDecl(toml, "DocumentType"));
    comptime assert(@hasDecl(toml, "Document"));

    std.testing.refAllDecls(toml);
    std.testing.refAllDecls(toml.Datetime);
    std.testing.refAllDecls(toml.Document);
    std.testing.refAllDecls(toml.Entries);
    std.testing.refAllDecls(toml.Items);
    std.testing.refAllDecls(toml.Region);
    std.testing.refAllDecls(toml.Storage);
    std.testing.refAllDecls(toml.Writer);
    std.testing.refAllDecls(toml.limits);
    std.testing.refAllDecls(Document);
}
