const std = @import("std");

const codec_fuzz = @import("codec_fuzz.zig");
const document_fuzz = @import("document_fuzz.zig");
const fuzz_model = @import("fuzz_model.zig");
const parser_fuzz = @import("parser_fuzz.zig");
const splicer_fuzz = @import("splicer_fuzz.zig");
const writer_fuzz = @import("writer_fuzz.zig");

const assert = std.debug.assert;

const Fuzzer = enum {
    codec,
    document,
    model,
    mutation,
    smoke,
    splicer,
    writer,
};

const events_max_smoke: u32 = 512;
const seed_smoke: u64 = 0x5eed;
const usage_text = "usage: fuzz <codec|document|model|mutation|smoke|splicer|writer> [seed]\n";

comptime {
    assert(events_max_smoke < fuzz_model.events_full);
    assert(std.enums.values(Fuzzer).len == 7);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    assert(arguments.len > 0);

    if (arguments.len < 2) return usage();
    if (arguments.len > 3) return usage();

    const fuzzer = std.meta.stringToEnum(Fuzzer, arguments[1]) orelse return usage();
    const seed_text = if (arguments.len == 3) arguments[2] else "";

    if (fuzzer == .smoke) {
        if (seed_text.len > 0) return usage();

        for (std.enums.values(Fuzzer)) |each| {
            if (each == .smoke) continue;

            try run(init.gpa, each, .{ .events_max = events_max_smoke, .seed = seed_smoke });
        }

        return;
    }

    var seed: u64 = 0;

    if (seed_text.len == 0) {
        init.io.random(std.mem.asBytes(&seed));
    } else {
        seed = try seed_parse(seed_text);
    }

    try run(init.gpa, fuzzer, .{ .events_max = fuzz_model.events_full, .seed = seed });
}

fn usage() error{ArgumentsInvalid} {
    std.debug.print("{s}", .{usage_text});

    return error.ArgumentsInvalid;
}

fn seed_parse(text: []const u8) error{ArgumentsInvalid}!u64 {
    assert(text.len > 0);

    const result = std.fmt.parseInt(u64, text, 10) catch return usage();

    assert(std.fmt.count("{d}", .{result}) <= text.len);

    return result;
}

fn run(gpa: std.mem.Allocator, fuzzer: Fuzzer, options: fuzz_model.Options) !void {
    assert(fuzzer != .smoke);
    assert(options.events_max > 0);
    assert(options.events_max <= fuzz_model.events_full);

    std.debug.print("fuzz {t}: seed={d} events_max={d}\n", .{
        fuzzer,
        options.seed,
        options.events_max,
    });

    switch (fuzzer) {
        .codec => try codec_fuzz.main(gpa, options),
        .document => try document_fuzz.main(gpa, options),
        .model => try parser_fuzz.main(gpa, options, .model),
        .mutation => try parser_fuzz.main(gpa, options, .mutation),
        .smoke => unreachable,
        .splicer => try splicer_fuzz.main(gpa, options),
        .writer => try writer_fuzz.main(gpa, options),
    }
}
