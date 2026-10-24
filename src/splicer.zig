const std = @import("std");

const document_module = @import("document.zig");
const scalar = @import("scalar.zig");
const serializer_module = @import("serializer.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const Line = storage_module.Line;
const Record = storage_module.Record;
const Serializer = serializer_module.Serializer;
const Writer = writer_module.Writer;

const Anchor = struct {
    line: u32,
    table: u32,
};

const Boundary = struct {
    header: u32,
    split: u32,
};

const Class = serializer_module.Line;

const Container = struct {
    node: u32,
    open: u32,
};

const Crlf = struct {
    buffer: [crlf_buffer_bytes]u8,
    interface: std.Io.Writer,
    sink: *std.Io.Writer,

    fn init(crlf: *Crlf, sink: *std.Io.Writer) void {
        assert(sink.end <= sink.buffer.len);
        assert(crlf_buffer_bytes >= 64);

        crlf.sink = sink;
        crlf.interface = .{ .buffer = &crlf.buffer, .vtable = &crlf_vtable };
    }

    fn drain(
        interface: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        assert(data.len > 0);
        assert(interface.end <= interface.buffer.len);
        assert(splat <= scalar.source_bytes_max);

        const crlf: *Crlf = @alignCast(@fieldParentPtr("interface", interface));

        try crlf.translate(interface.buffer[0..interface.end]);

        interface.end = 0;

        var total: u64 = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            try crlf.translate(bytes);

            total += bytes.len;
        }

        const last = data[data.len - 1];

        for (0..splat) |_| try crlf.translate(last);

        const written = total + last.len * splat;

        assert(splat > 0 or written == total);

        return @intCast(written);
    }

    fn translate(crlf: *Crlf, bytes: []const u8) std.Io.Writer.Error!void {
        assert(bytes.len <= scalar.source_bytes_max);
        assert(crlf.sink.end <= crlf.sink.buffer.len);

        var start: usize = 0;

        for (0..bytes.len + 1) |_| {
            const newline = std.mem.findScalarPos(u8, bytes, start, '\n') orelse {
                return crlf.sink.writeAll(bytes[start..]);
            };

            try crlf.sink.writeAll(bytes[start..newline]);
            try crlf.sink.writeAll("\r\n");

            start = newline + 1;
        }

        unreachable;
    }
};

const Element = struct {
    end: u32,
    leaf: u32,
    start: u32,
    value: u32,
};

const Emit = struct {
    indent: Span,
    node: u32,
    top: u32,
};

const KeySkip = struct {
    segments: u32,
    value: u32,
};

const PatchFrame = struct {
    appended: bool,
    close: u32,
    container: u32,
    copied: u32,
    cursor: u32,
    cut: bool,
    element: u32,
    held: Element,
    indent: Span,
    next: u32,
    open: u32,
    plan: Plan,
    range_end: u32,
    single_line: bool,
    table: bool,
};

const Plan = struct {
    appends: bool,
    count: u32,
    cut: bool,
    alone_last: bool,
    single_line: bool,
    survivor_last: u32,
    survivors: u32,
    trailing_comma: bool,
};

const Section = struct {
    header: u32,
    owner: u32,
};

const Span = struct {
    end: u32,
    start: u32,
};

const Splicer = struct {
    anchor_count: u32,
    anchors: [anchor_count_max]Anchor,
    array_cached: u32,
    array_writable: bool,
    blank_owed: bool,
    crlf: Crlf,
    crlf_used: bool,
    document: *const Document,
    emitted: bool,
    header_last: u32,
    newline_last: bool,
    output_empty: bool,
    patch_depth: u32,
    patch_frames: [depth_max]PatchFrame,
    sections_pending: bool,
    serializer: Serializer,
    sink: *std.Io.Writer,
    source: []const u8,
    version_single: bool,

    fn init(
        splicer: *Splicer,
        document: *const Document,
        sink: *std.Io.Writer,
        options: Writer.Options,
    ) void {
        assert(document.node_count > 0);
        assert(sink.end <= sink.buffer.len);
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);

        splicer.anchor_count = 0;
        splicer.array_cached = none;
        splicer.array_writable = false;
        splicer.blank_owed = false;
        splicer.crlf_used = crlf_detect(document.source);
        splicer.document = document;
        splicer.emitted = false;
        splicer.header_last = header_last_of(document);
        splicer.newline_last = true;
        splicer.output_empty = true;
        splicer.patch_depth = 0;
        splicer.sink = sink;
        splicer.source = document.source;
        splicer.version_single = options.version == .v1_0;

        splicer.crlf.init(sink);

        const out = if (splicer.crlf_used) &splicer.crlf.interface else sink;

        splicer.serializer.document = document;
        splicer.serializer.header_array = none;
        splicer.serializer.header_length = 0;

        splicer.serializer.writer.init(out, options);
        splicer.sections_pending = splicer.sections_pending_scan();
    }

    fn run(splicer: *Splicer) std.Io.Writer.Error!void {
        assert(splicer.output_empty);
        assert(splicer.patch_depth == 0);

        const lines = splicer.document.lines[0..splicer.document.line_count];
        const root: Section = .{ .header = none, .owner = root_index };

        var walk: Walk = .{
            .dropping = false,
            .gap_start = 0,
            .root_pairs = false,
            .section = root,
            .section_end = 0,
        };

        if (std.mem.startsWith(u8, splicer.source, byte_order_mark)) {
            try splicer.raw(.{ .end = byte_order_mark.len, .start = 0 });

            splicer.newline_last = true;
            splicer.output_empty = true;
            walk.gap_start = byte_order_mark.len;
        }

        splicer.section_begin(&walk, root, 0);
        walk.root_pairs = walk.section_end > 0;

        for (lines, 0..) |line, index| {
            const number: u32 = @intCast(index);

            if (splicer.header_is(line)) {
                try splicer.header_line(&walk, number);
            } else {
                try splicer.pair_line(&walk, number);
            }

            walk.gap_start = line.end;
        }

        try splicer.finish(&walk);
    }

    fn header_line(splicer: *Splicer, walk: *Walk, number: u32) std.Io.Writer.Error!void {
        assert(number < splicer.document.line_count);
        assert(walk.gap_start <= splicer.document.lines[number].start);

        const line = splicer.document.lines[number];
        const split = splicer.gap_split(.{ .end = line.start, .start = walk.gap_start });

        if (!walk.dropping) try splicer.raw(.{ .end = split, .start = walk.gap_start });

        try splicer.boundary_emit(walk, .{ .header = number, .split = split });

        const owner = line.node;
        const dropped = splicer.displaced(owner);

        if (!dropped) try splicer.raw(.{ .end = line.start, .start = split });

        walk.dropping = dropped;

        splicer.section_begin(walk, .{ .header = number, .owner = owner }, number + 1);

        if (dropped) return;

        try splicer.raw(.{ .end = line.end, .start = line.start });

        if (walk.section_end == number + 1) {
            const indent = indent_of(splicer.source, line.start);

            try splicer.members_emit(.{ .indent = indent, .node = owner, .top = owner });
        }
    }

    fn pair_line(splicer: *Splicer, walk: *Walk, number: u32) std.Io.Writer.Error!void {
        assert(number < splicer.document.line_count);
        assert(walk.gap_start <= splicer.document.lines[number].start);

        if (walk.dropping) return;

        const line = splicer.document.lines[number];

        if (splicer.displaced(line.node)) {
            const gap: Span = .{ .end = line.start, .start = walk.gap_start };

            try splicer.raw(.{ .end = splicer.head_start(gap), .start = gap.start });
        } else {
            try splicer.raw(.{ .end = line.start, .start = walk.gap_start });
            try splicer.pair_write(line);
        }

        const indent = indent_of(splicer.source, line.start);

        try splicer.anchors_emit(.{ .line = number, .table = walk.section.owner }, indent);

        if (number + 1 == walk.section_end) {
            const owner = walk.section.owner;

            try splicer.members_emit(.{ .indent = indent, .node = owner, .top = owner });
        }
    }

    fn finish(splicer: *Splicer, walk: *Walk) std.Io.Writer.Error!void {
        assert(walk.gap_start <= splicer.source.len);
        assert(splicer.patch_depth == 0);

        const end: u32 = @intCast(splicer.source.len);
        const split = splicer.gap_split(.{ .end = end, .start = walk.gap_start });

        if (!walk.dropping) try splicer.raw(.{ .end = split, .start = walk.gap_start });

        try splicer.boundary_emit(walk, .{ .header = none, .split = split });
        try splicer.raw(.{ .end = end, .start = split });
    }

    fn boundary_emit(
        splicer: *Splicer,
        walk: *const Walk,
        boundary: Boundary,
    ) std.Io.Writer.Error!void {
        assert(boundary.split <= splicer.source.len);
        assert(boundary.header == none or boundary.header < splicer.document.line_count);

        splicer.emitted = false;

        if (walk.section.header == none) {
            if (!walk.root_pairs) try splicer.members_emit(emit_root);
        }

        try splicer.sections_close(walk.section);

        if (boundary.header != none) try splicer.implicit_headers(boundary.header);

        if (splicer.emitted) splicer.blank_owed = true;
    }

    fn section_begin(splicer: *Splicer, walk: *Walk, section: Section, first: u32) void {
        assert(first <= splicer.document.line_count);
        assert(section.owner < splicer.document.node_count);

        const lines = splicer.document.lines[0..splicer.document.line_count];

        walk.section = section;
        walk.section_end = first;

        for (lines[first..]) |line| {
            if (splicer.header_is(line)) break;

            walk.section_end += 1;
        }

        splicer.anchors_fill(section.owner, .{ .end = walk.section_end, .start = first });
    }

    fn header_is(splicer: *const Splicer, line: Line) bool {
        assert(line.start < line.end);
        assert(line.end <= splicer.source.len);

        const first = scalar.whitespace_end(splicer.source, line.start);
        return first < line.end and splicer.source[first] == '[';
    }

    fn anchors_fill(splicer: *Splicer, table: u32, lines: Span) void {
        assert(table < splicer.document.node_count);
        assert(lines.start <= lines.end);
        assert(lines.end <= splicer.document.line_count);

        const document = splicer.document;

        splicer.anchor_count = 0;

        for (document.lines[lines.start..lines.end], lines.start..) |line, number| {
            var current = document.nodes[line.node].parent;

            for (0..depth_max + 1) |_| {
                if (current == table) break;

                splicer.anchor_set(.{ .line = @intCast(number), .table = current });
                current = document.nodes[current].parent;
            } else unreachable;
        }
    }

    fn anchor_set(splicer: *Splicer, anchor: Anchor) void {
        assert(anchor.table < splicer.document.node_count);
        assert(anchor.line < splicer.document.line_count);
        assert(splicer.anchor_count <= anchor_count_max);

        for (splicer.anchors[0..splicer.anchor_count]) |*existing| {
            if (existing.table == anchor.table) {
                existing.line = anchor.line;

                return;
            }
        }

        if (splicer.anchor_count == anchor_count_max) return;

        splicer.anchors[splicer.anchor_count] = anchor;
        splicer.anchor_count += 1;
    }

    fn anchor_line(splicer: *const Splicer, table: u32) u32 {
        assert(table < splicer.document.node_count);
        assert(splicer.anchor_count <= anchor_count_max);

        for (splicer.anchors[0..splicer.anchor_count]) |anchor| {
            if (anchor.table == table) return anchor.line;
        }

        return none;
    }

    fn anchors_emit(splicer: *Splicer, anchor: Anchor, indent: Span) std.Io.Writer.Error!void {
        assert(anchor.line < splicer.document.line_count);
        assert(anchor.table < splicer.document.node_count);
        assert(indent.start <= indent.end);

        const document = splicer.document;
        var current = document.nodes[document.lines[anchor.line].node].parent;

        for (0..depth_max + 1) |_| {
            if (current == anchor.table) return;

            if (splicer.anchor_line(current) == anchor.line) {
                if (!splicer.displaced(current)) {
                    const emit: Emit = .{ .indent = indent, .node = current, .top = anchor.table };

                    try splicer.members_emit(emit);
                }
            }

            current = document.nodes[current].parent;
        }

        unreachable;
    }

    fn members_emit(splicer: *Splicer, emit: Emit) std.Io.Writer.Error!void {
        assert(emit.node < splicer.document.node_count);
        assert(splicer.document.nodes[emit.node].kind == .table);
        assert(emit.top <= emit.node);
        assert(emit.indent.start <= emit.indent.end);

        const document = splicer.document;
        const table = emit.node;
        var parent = table;
        var cursor = document.nodes[table].child_first;

        for (0..2 * document.node_count + 1) |_| {
            if (cursor == none) {
                if (parent == table) return;

                cursor = document.nodes[parent].sibling_next;
                parent = document.nodes[parent].parent;

                continue;
            }

            const record = &document.nodes[cursor];
            const class = splicer.class_of(cursor);

            if (splicer.fresh(cursor)) {
                const child: Emit = .{ .indent = emit.indent, .node = cursor, .top = emit.top };

                switch (class) {
                    .dotted => try splicer.dotted_emit(child),
                    .line => try splicer.line_emit(child),
                    .section => {},
                }
            } else if (class == .dotted) {
                if (splicer.anchor_line(cursor) == none) {
                    parent = cursor;
                    cursor = record.child_first;

                    continue;
                }
            }

            cursor = record.sibling_next;
        }

        unreachable;
    }

    fn dotted_emit(splicer: *Splicer, emit: Emit) std.Io.Writer.Error!void {
        assert(emit.node < splicer.document.node_count);
        assert(emit.top < emit.node);
        assert(emit.indent.start <= emit.indent.end);

        const document = splicer.document;
        const table = emit.node;
        var parent = table;
        var cursor = document.nodes[table].child_first;

        for (0..2 * document.node_count + 1) |_| {
            if (cursor == none) {
                if (parent == table) return;

                cursor = document.nodes[parent].sibling_next;
                parent = document.nodes[parent].parent;

                continue;
            }

            const record = &document.nodes[cursor];

            switch (splicer.class_of(cursor)) {
                .dotted => {
                    parent = cursor;
                    cursor = record.child_first;

                    continue;
                },
                .line => {
                    const child: Emit = .{ .indent = emit.indent, .node = cursor, .top = emit.top };

                    try splicer.line_emit(child);
                },
                .section => {},
            }

            cursor = record.sibling_next;
        }

        unreachable;
    }

    fn line_emit(splicer: *Splicer, emit: Emit) std.Io.Writer.Error!void {
        assert(emit.node < splicer.document.node_count);
        assert(emit.top < emit.node);
        assert(emit.indent.start <= emit.indent.end);

        const indent = emit.indent;

        try splicer.line_begin();
        try splicer.raw(indent);

        const writer = &splicer.serializer.writer;

        writer_module.margin_set(writer, splicer.source[indent.start..indent.end]);

        try splicer.serializer.line_write(.{ .node = emit.node, .top = emit.top });

        writer_module.margin_set(writer, "");
        splicer.emitted = true;
        splicer.newline_last = true;
        splicer.output_empty = false;
    }

    fn sections_close(splicer: *Splicer, section: Section) std.Io.Writer.Error!void {
        assert(section.owner < splicer.document.node_count);
        assert(section.header == none or section.header < splicer.document.line_count);

        if (!splicer.sections_pending) return;

        const document = splicer.document;
        var current = section.owner;

        for (0..depth_max + 1) |_| {
            if (splicer.sections_owner_is(current)) {
                if (splicer.section_last_is(.{ .line = section.header, .table = current })) {
                    _ = try splicer.sections_walk(current, true);
                }
            }

            if (current == root_index) return;

            current = document.nodes[current].parent;
        }

        unreachable;
    }

    fn sections_owner_is(splicer: *Splicer, node: u32) bool {
        assert(node < splicer.document.node_count);
        assert(splicer.sections_pending);

        if (splicer.displaced(node)) return false;
        if (node == root_index) return true;
        if (splicer.document.nodes[node].kind == .array) return true;
        return splicer.class_of(node) != .dotted;
    }

    fn section_last_is(splicer: *const Splicer, anchor: Anchor) bool {
        assert(anchor.table < splicer.document.node_count);
        assert(anchor.line == none or anchor.line < splicer.document.line_count);

        const node = anchor.table;
        const header = anchor.line;
        if (node == root_index) return header == splicer.header_last;

        assert(header != none);

        const lines = splicer.document.lines[0..splicer.document.line_count];

        for (lines[header + 1 ..]) |line| {
            if (!splicer.header_is(line)) continue;
            if (chain_contains(splicer.document, .{ .node = line.node, .top = node })) return false;
        }

        return true;
    }

    fn sections_walk(splicer: *Splicer, top: u32, emit: bool) std.Io.Writer.Error!bool {
        assert(top < splicer.document.node_count);
        assert(splicer.sections_pending);

        const document = splicer.document;
        var found = false;
        var parent = top;
        var cursor = document.nodes[top].child_first;

        for (0..2 * document.node_count + 1) |_| {
            if (cursor == none) {
                if (parent == top) return found;

                cursor = document.nodes[parent].sibling_next;
                parent = document.nodes[parent].parent;

                continue;
            }

            const record = &document.nodes[cursor];

            if (splicer.section_candidate(cursor)) {
                found = true;

                if (!emit) return found;

                try splicer.section_emit(cursor);
            } else if (record.kind == .table) {
                if (splicer.class_of(cursor) == .dotted) {
                    parent = cursor;
                    cursor = record.child_first;

                    continue;
                }
            }

            cursor = record.sibling_next;
        }

        unreachable;
    }

    fn section_candidate(splicer: *Splicer, node: u32) bool {
        assert(node > root_index);
        assert(node < splicer.document.node_count);

        const document = splicer.document;
        const record = &document.nodes[node];

        if (untouched(document, node)) return false;
        if (!splicer.fresh(node)) return false;
        if (document.nodes[record.parent].kind == .array) return true;
        return splicer.class_of(node) == .section;
    }

    fn section_emit(splicer: *Splicer, node: u32) std.Io.Writer.Error!void {
        assert(node > root_index);
        assert(node < splicer.document.node_count);

        splicer.blank_owed = false;

        try splicer.line_begin();

        splicer.serializer.writer.written = !splicer.output_empty;

        try splicer.serializer.subtree_sections_write(node);

        splicer.emitted = true;
        splicer.newline_last = true;
        splicer.output_empty = false;
    }

    fn sections_pending_scan(splicer: *Splicer) bool {
        assert(splicer.document.node_count > 0);
        assert(splicer.document.node_count_parsed <= splicer.document.node_count);

        const document = splicer.document;

        for (1..document.node_count) |index| {
            const node: u32 = @intCast(index);
            const record = &document.nodes[node];
            if (record.flags.detached) continue;
            if (untouched(document, node)) continue;
            if (inline_context(document, node)) continue;
            if (splicer.section_candidate(node)) return true;
        }

        return false;
    }

    fn implicit_headers(splicer: *Splicer, header: u32) std.Io.Writer.Error!void {
        assert(header < splicer.document.line_count);
        assert(splicer.header_is(splicer.document.lines[header]));

        const document = splicer.document;
        var chain: [depth_max]u32 = undefined;
        var count: u32 = 0;
        var current = document.nodes[document.lines[header].node].parent;

        for (0..depth_max + 1) |_| {
            if (current == root_index) break;

            chain[count] = current;
            count += 1;
            current = document.nodes[current].parent;
        } else unreachable;

        for (0..count) |offset| {
            const table = chain[count - 1 - offset];
            if (!splicer.implicit_needs(table)) continue;
            if (!splicer.section_first_is(.{ .line = header, .table = table })) continue;

            splicer.blank_owed = false;

            try splicer.line_begin();

            splicer.serializer.writer.written = !splicer.output_empty;

            try splicer.serializer.table_header_write(table);
            try splicer.members_emit(.{ .indent = span_empty, .node = table, .top = table });

            splicer.emitted = true;
            splicer.newline_last = true;
            splicer.output_empty = false;
        }
    }

    fn implicit_needs(splicer: *Splicer, table: u32) bool {
        assert(table > root_index);
        assert(table < splicer.document.node_count);

        const document = splicer.document;
        const record = &document.nodes[table];

        if (table >= document.node_count_parsed) return false;
        if (record.flags.edited) return false;
        if (record.flags.detached) return false;
        if (record.kind != .table) return false;
        if (record.flags.closed) return false;
        if (record.flags.explicit) return false;
        if (record.section != none) return false;
        if (record.flags.owner != .none) return false;
        if (splicer.displaced(table)) return false;
        if (record.count == 0) return true;
        return splicer.members_any(table);
    }

    fn members_any(splicer: *Splicer, table: u32) bool {
        assert(table < splicer.document.node_count);
        assert(splicer.document.nodes[table].kind == .table);

        const document = splicer.document;
        var parent = table;
        var cursor = document.nodes[table].child_first;

        for (0..2 * document.node_count + 1) |_| {
            if (cursor == none) {
                if (parent == table) return false;

                cursor = document.nodes[parent].sibling_next;
                parent = document.nodes[parent].parent;

                continue;
            }

            const record = &document.nodes[cursor];

            switch (splicer.class_of(cursor)) {
                .dotted => if (splicer.fresh(cursor)) {
                    parent = cursor;
                    cursor = record.child_first;

                    continue;
                },
                .line => if (splicer.fresh(cursor)) return true,
                .section => {},
            }

            cursor = record.sibling_next;
        }

        unreachable;
    }

    fn section_first_is(splicer: *const Splicer, anchor: Anchor) bool {
        assert(anchor.table < splicer.document.node_count);
        assert(anchor.line < splicer.document.line_count);

        const table = anchor.table;
        const lines = splicer.document.lines[0..anchor.line];

        for (lines) |line| {
            if (!splicer.header_is(line)) continue;

            const chain: serializer_module.Chain = .{ .node = line.node, .top = table };
            if (chain_contains(splicer.document, chain)) return false;
        }

        return true;
    }

    fn displaced(splicer: *Splicer, node: u32) bool {
        assert(node < splicer.document.node_count);
        assert(splicer.document.node_count <= splicer.document.nodes.len);

        const document = splicer.document;
        var current = node;

        for (0..depth_max + 2) |_| {
            const record = &document.nodes[current];
            if (record.flags.detached) return true;
            if (current == root_index) return false;
            if (splicer.fresh(current)) return true;

            current = record.parent;
        }

        unreachable;
    }

    fn fresh(splicer: *Splicer, node: u32) bool {
        assert(node > root_index);
        assert(node < splicer.document.node_count);

        const document = splicer.document;
        const record = &document.nodes[node];

        if (node >= document.node_count_parsed) return true;
        if (document.nodes[record.parent].kind == .array) return false;

        if (record.flags.edited) {
            return switch (record.flags.owner) {
                .header => record.kind != .table or
                    !record.flags.explicit or
                    splicer.class_of(node) != .section,
                .none => true,
                .pair => splicer.class_of(node) != .line,
            };
        }

        switch (record.kind) {
            .array => {
                if (!record.flags.array_of_tables) return false;
                return splicer.class_of(node) != .section;
            },
            .table => {
                if (record.flags.closed) return false;
                if (record.flags.explicit) return false;
                if (record.section == none) return false;
                return record.count == 0;
            },
            .boolean, .datetime, .float, .integer, .string => return false,
        }
    }

    fn class_of(splicer: *Splicer, node: u32) Class {
        assert(node > root_index);
        assert(node < splicer.document.node_count);

        const document = splicer.document;
        const record = &document.nodes[node];
        if (record.kind != .array) return serializer_module.line_kind_of(document, node);

        if (splicer.array_cached != node) {
            splicer.array_cached = node;
            splicer.array_writable = serializer_module.array_of_tables_writable(document, record);
        }

        return if (splicer.array_writable) .section else .line;
    }

    fn pair_write(splicer: *Splicer, line: Line) std.Io.Writer.Error!void {
        assert(line.start < line.end);
        assert(!splicer.header_is(line));

        const record = &splicer.document.nodes[line.node];
        const indent = indent_of(splicer.source, line.start);
        const value = key_skip(splicer.source, indent.end).value;

        if (record.flags.edited) {
            const value_end = scalar.value_skip(splicer.source, value);

            try splicer.raw(.{ .end = value, .start = line.start });

            try splicer.value_render(line.node, .{
                .margin = splicer.source[indent.start..indent.end],
                .single_line = false,
            });

            return splicer.raw(.{ .end = line.end, .start = value_end });
        }

        if (!inline_dirty(splicer.document, line.node)) {
            return splicer.raw(.{ .end = line.end, .start = line.start });
        }

        try splicer.raw(.{ .end = value, .start = line.start });

        const value_end = try splicer.patch(.{ .node = line.node, .open = value });

        try splicer.raw(.{ .end = line.end, .start = value_end });
    }

    fn value_render(
        splicer: *Splicer,
        node: u32,
        splice_options: writer_module.Splice,
    ) std.Io.Writer.Error!void {
        assert(node > root_index);
        assert(node < splicer.document.node_count);
        assert(splice_options.margin.len <= splicer.source.len);

        const writer = &splicer.serializer.writer;
        const record = &splicer.document.nodes[node];

        writer_module.splice_open(writer, splice_options);

        switch (record.kind) {
            .array, .table => try splicer.serializer.inline_write(node),
            .boolean, .datetime, .float, .integer, .string => {
                try splicer.serializer.scalar_write(record);
            },
        }

        writer_module.splice_close(writer);

        splicer.newline_last = false;
        splicer.output_empty = false;
    }

    fn patch(splicer: *Splicer, top: Container) std.Io.Writer.Error!u32 {
        assert(splicer.patch_depth == 0);
        assert(top.open < splicer.source.len);
        assert(top.node < splicer.document.node_count_parsed);

        try splicer.patch_push(top, false);

        for (0..splicer.source.len + splicer.document.node_count + 2) |_| {
            const frame = &splicer.patch_frames[splicer.patch_depth - 1];

            switch (try splicer.patch_step(frame)) {
                .advanced => {},
                .descend => |element| {
                    const single = frame.single_line or (frame.table and splicer.version_single);
                    const child: Container = .{ .node = element.leaf, .open = element.value };

                    try splicer.patch_push(child, single);
                },
                .finished => |end| {
                    splicer.patch_depth -= 1;

                    if (splicer.patch_depth == 0) return end;

                    const parent = &splicer.patch_frames[splicer.patch_depth - 1];

                    parent.copied = end;

                    try splicer.element_finish(parent, parent.held);
                },
            }
        }

        unreachable;
    }

    fn patch_push(
        splicer: *Splicer,
        top: Container,
        context_single: bool,
    ) std.Io.Writer.Error!void {
        assert(splicer.patch_depth < depth_max);
        assert(splicer.source[top.open] == '[' or splicer.source[top.open] == '{');

        const container = top.node;
        const open = top.open;
        const source = splicer.source;
        const end = scalar.value_skip(source, open);
        const close = end - 1;
        const frame = &splicer.patch_frames[splicer.patch_depth];

        splicer.patch_depth += 1;

        frame.* = .{
            .appended = false,
            .close = close,
            .container = container,
            .copied = open,
            .cursor = open + 1,
            .cut = false,
            .element = 0,
            .held = undefined,
            .indent = indent_of(source, line_start_of(source, open)),
            .next = container + 1,
            .open = open,
            .plan = undefined,
            .range_end = subtree_end(splicer.document, container),
            .single_line = true,
            .table = splicer.document.nodes[container].kind == .table,
        };

        frame.plan = splicer.plan_of(frame);
        frame.single_line = frame.plan.single_line;

        if (frame.plan.survivors > 0) return;

        try splicer.value_render(container, .{
            .margin = source[frame.indent.start..frame.indent.end],
            .single_line = context_single,
        });

        frame.appended = true;
        frame.copied = end;
        frame.cursor = close;
    }

    fn patch_step(splicer: *Splicer, frame: *PatchFrame) std.Io.Writer.Error!Outcome {
        assert(frame.cursor <= frame.close);
        assert(frame.copied <= frame.close + 1);

        const position = element_seek(splicer.source, frame.cursor);

        if (position == frame.close) {
            try splicer.patch_close(frame);

            return .{ .finished = frame.close + 1 };
        }

        const element = element_at(splicer.document, frame.*, position);

        frame.cursor = element.end;
        frame.element += 1;
        frame.next = subtree_end(splicer.document, element.leaf);

        const record = &splicer.document.nodes[element.leaf];

        if (frame.cut) {
            frame.copied = element.end;

            return .advanced;
        }

        if (element_gone(splicer.document, element.leaf)) {
            try splicer.element_remove(frame, element);

            return .advanced;
        }

        if (record.flags.edited) {
            try splicer.raw(.{ .end = element.value, .start = frame.copied });
            try splicer.value_render(element.leaf, splicer.splice_of(frame, element.value));

            frame.copied = element.end;
        } else if (inline_dirty(splicer.document, element.leaf)) {
            try splicer.raw(.{ .end = element.value, .start = frame.copied });

            frame.copied = element.value;
            frame.held = element;

            return .{ .descend = element };
        }

        try splicer.element_finish(frame, element);

        return .advanced;
    }

    fn patch_close(splicer: *Splicer, frame: *PatchFrame) std.Io.Writer.Error!void {
        assert(frame.copied <= frame.close + 1);
        assert(frame.close < splicer.source.len);

        if (frame.plan.appends) {
            if (!frame.appended) try splicer.appends_close(frame);
        }

        if (frame.copied <= frame.close) {
            try splicer.raw(.{ .end = frame.close + 1, .start = frame.copied });
        }
    }

    fn appends_close(splicer: *Splicer, frame: *PatchFrame) std.Io.Writer.Error!void {
        assert(frame.plan.appends);
        assert(!frame.appended);
        assert(!frame.single_line);

        const source = splicer.source;
        const close_line = line_start_of(source, frame.close);

        const alone = close_line > frame.open and
            scalar.whitespace_end(source, close_line) == frame.close;

        if (alone) {
            try splicer.raw(.{ .end = close_line, .start = frame.copied });
            frame.copied = close_line;

            try splicer.appends_write(frame, .lines_after);
        } else {
            try splicer.raw(.{ .end = frame.close, .start = frame.copied });
            frame.copied = frame.close;

            try splicer.appends_write(frame, .lines_before);
        }

        frame.appended = true;
    }

    fn element_finish(
        splicer: *Splicer,
        frame: *PatchFrame,
        element: Element,
    ) std.Io.Writer.Error!void {
        assert(frame.element > 0);
        assert(element.end <= frame.close);

        if (frame.element - 1 != frame.plan.survivor_last) return;

        try splicer.raw(.{ .end = element.end, .start = frame.copied });

        frame.copied = element.end;

        if (frame.plan.appends) try splicer.appends_after(frame, element);
        if (frame.plan.cut) frame.cut = true;
    }

    fn appends_after(
        splicer: *Splicer,
        frame: *PatchFrame,
        element: Element,
    ) std.Io.Writer.Error!void {
        assert(frame.plan.appends);
        assert(frame.copied == element.end);

        const comma = comma_after(splicer.source, .{ .end = frame.close, .start = element.end });
        const comma_kept = comma != none and !frame.plan.cut;

        if (!frame.single_line) {
            frame.indent = indent_of(splicer.source, line_start_of(splicer.source, element.start));

            if (!comma_kept) try splicer.text_write(",");

            return;
        }

        if (comma_kept) {
            try splicer.raw(.{ .end = comma + 1, .start = frame.copied });

            frame.copied = comma + 1;

            try splicer.appends_write(frame, .trailing);
        } else {
            try splicer.appends_write(frame, .leading);
        }

        frame.appended = true;
    }

    fn element_remove(
        splicer: *Splicer,
        frame: *PatchFrame,
        element: Element,
    ) std.Io.Writer.Error!void {
        assert(element.start >= frame.copied);
        assert(element.end <= frame.close);

        const source = splicer.source;

        if (!frame.single_line) {
            if (alone_with_comma(source, frame, element)) {
                const start = line_start_of(source, element.start);

                assert(start >= frame.copied);

                try splicer.raw(.{ .end = start, .start = frame.copied });

                frame.copied = line_end_after(source, element.end);

                return;
            }
        }

        const comma = comma_after(source, .{ .end = frame.close, .start = element.end });

        assert(comma != none);

        try splicer.raw(.{ .end = element.start, .start = frame.copied });

        frame.copied = scalar.whitespace_end(source, comma + 1);
    }

    fn appends_write(splicer: *Splicer, frame: *PatchFrame, style: Style) std.Io.Writer.Error!void {
        assert(frame.plan.appends);
        assert(frame.container < splicer.document.node_count);

        const total = splicer.appends_count(frame);

        var walk: AppendWalk = .{
            .cursor = splicer.document.nodes[frame.container].child_first,
            .parent = frame.container,
        };

        for (0..total) |index| {
            const node = splicer.append_next(frame, &walk);

            assert(node != none);

            try splicer.append_write(frame, node, style, index + 1 == total);
        }

        assert(splicer.append_next(frame, &walk) == none);
    }

    fn appends_count(splicer: *Splicer, frame: *const PatchFrame) u32 {
        assert(frame.container < splicer.document.node_count);
        assert(splicer.document.node_count <= splicer.document.nodes.len);

        var count: u32 = 0;

        var walk: AppendWalk = .{
            .cursor = splicer.document.nodes[frame.container].child_first,
            .parent = frame.container,
        };

        for (0..splicer.document.node_count + 1) |_| {
            if (splicer.append_next(frame, &walk) == none) return count;

            count += 1;
        }

        unreachable;
    }

    fn append_next(splicer: *Splicer, frame: *const PatchFrame, walk: *AppendWalk) u32 {
        assert(walk.parent < splicer.document.node_count);
        assert(frame.container < splicer.document.node_count);

        const document = splicer.document;

        for (0..2 * document.node_count + 1) |_| {
            if (walk.cursor == none) {
                if (walk.parent == frame.container) return none;

                walk.cursor = document.nodes[walk.parent].sibling_next;
                walk.parent = document.nodes[walk.parent].parent;

                continue;
            }

            const node = walk.cursor;
            const record = &document.nodes[node];

            switch (splicer.append_kind(frame, node)) {
                .descend => {
                    walk.parent = node;
                    walk.cursor = record.child_first;
                },
                .element => {
                    walk.cursor = record.sibling_next;

                    return node;
                },
                .skip => walk.cursor = record.sibling_next,
            }
        }

        unreachable;
    }

    fn append_kind(splicer: *Splicer, frame: *const PatchFrame, node: u32) AppendKind {
        assert(node > frame.container);
        assert(node < splicer.document.node_count);

        const document = splicer.document;
        const record = &document.nodes[node];
        const parsed = node < document.node_count_parsed;
        const flattened = serializer_module.flattened(document, node);

        const moved = record.flags.edited and
            (flattened or !element_leaf_is(document, frame.*, node));

        if (!parsed) return if (flattened) .descend else .element;
        if (moved) return if (flattened) .descend else .element;
        if (record.flags.edited) return .skip;
        if (record.kind != .table) return .skip;
        if (record.flags.closed) return .skip;
        if (record.section == none) return .skip;
        if (record.count == 0) return .element;
        return .descend;
    }

    fn append_write(
        splicer: *Splicer,
        frame: *PatchFrame,
        node: u32,
        style: Style,
        last: bool,
    ) std.Io.Writer.Error!void {
        assert(node < splicer.document.node_count);
        assert(frame.plan.appends);

        const comma = !last or frame.plan.trailing_comma;

        switch (style) {
            .leading => try splicer.text_write(", "),
            .lines_after => try splicer.raw(frame.indent),
            .lines_before => {
                try splicer.text_write("\n");
                try splicer.raw(frame.indent);
            },
            .trailing => try splicer.text_write(" "),
        }

        if (frame.table) {
            const chain: serializer_module.Chain = .{ .node = node, .top = frame.container };
            const path = splicer.serializer.chain_collect(chain);

            try writer_module.key_path_write(splicer.serializer.writer.out, path);
            try splicer.text_write(" = ");
        }

        try splicer.value_render(node, .{
            .margin = splicer.source[frame.indent.start..frame.indent.end],
            .single_line = frame.single_line or (frame.table and splicer.version_single),
        });

        switch (style) {
            .leading => {},
            .lines_after => {
                if (comma) try splicer.text_write(",");

                try splicer.text_write("\n");
            },
            .lines_before => if (comma) try splicer.text_write(","),
            .trailing => try splicer.text_write(","),
        }
    }

    fn plan_of(splicer: *Splicer, frame: *const PatchFrame) Plan {
        assert(frame.copied == frame.open);
        assert(frame.close < splicer.source.len);

        const document = splicer.document;
        const source = splicer.source;

        var plan: Plan = .{
            .appends = false,
            .count = 0,
            .cut = false,
            .alone_last = false,
            .single_line = true,
            .survivor_last = none,
            .survivors = 0,
            .trailing_comma = false,
        };

        var scan = frame.*;
        var last: Element = undefined;

        for (0..source.len) |_| {
            const position = element_seek(source, scan.cursor);

            if (std.mem.findScalar(u8, source[scan.cursor..position], '\n') != null) {
                plan.single_line = false;
            }

            if (position == scan.close) break;

            last = element_at(document, scan, position);
            scan.cursor = last.end;
            scan.next = subtree_end(document, last.leaf);

            if (!element_gone(document, last.leaf)) {
                plan.survivors += 1;
                plan.survivor_last = plan.count;
            }

            plan.count += 1;
        } else unreachable;

        if (plan.count > 0) {
            const gap: Span = .{ .end = frame.close, .start = last.end };

            plan.trailing_comma = comma_after(source, gap) != none;
            plan.alone_last = !plan.single_line and alone_with_comma(source, frame, last);
        }

        if (plan.survivors > 0) {
            if (plan.survivor_last + 1 < plan.count) {
                plan.cut = !plan.trailing_comma and !plan.alone_last;
            }
        }

        if (plan.survivors > 0) plan.appends = splicer.appends_count(frame) > 0;

        return plan;
    }

    fn splice_of(
        splicer: *const Splicer,
        frame: *const PatchFrame,
        position: u32,
    ) writer_module.Splice {
        assert(position <= frame.close);
        assert(frame.open < position);

        const indent = indent_of(splicer.source, line_start_of(splicer.source, position));

        return .{
            .margin = splicer.source[indent.start..indent.end],
            .single_line = frame.single_line or (frame.table and splicer.version_single),
        };
    }

    fn raw(splicer: *Splicer, span: Span) std.Io.Writer.Error!void {
        assert(span.start <= span.end);
        assert(span.end <= splicer.source.len);

        if (span.start == span.end) return;

        if (splicer.blank_owed) {
            splicer.blank_owed = false;

            if (!blank_at(splicer.source, span.start)) try splicer.text_write("\n");
        }

        try splicer.text_flush();
        try splicer.sink.writeAll(splicer.source[span.start..span.end]);

        splicer.newline_last = splicer.source[span.end - 1] == '\n';
        splicer.output_empty = false;
    }

    fn text_write(splicer: *Splicer, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len > 0);
        assert(text.len <= 8);

        try splicer.serializer.writer.out.writeAll(text);

        splicer.newline_last = text[text.len - 1] == '\n';
        splicer.output_empty = false;
    }

    fn text_flush(splicer: *Splicer) std.Io.Writer.Error!void {
        assert(splicer.crlf.interface.end <= crlf_buffer_bytes);
        assert(splicer.sink.end <= splicer.sink.buffer.len);

        if (splicer.crlf_used) try splicer.crlf.interface.flush();
    }

    fn line_begin(splicer: *Splicer) std.Io.Writer.Error!void {
        assert(splicer.patch_depth == 0);
        assert(splicer.serializer.writer.depth == 0);

        if (!splicer.output_empty) {
            if (!splicer.newline_last) try splicer.text_write("\n");
        }

        if (splicer.blank_owed) {
            splicer.blank_owed = false;

            try splicer.text_write("\n");
        }
    }

    fn gap_split(splicer: *const Splicer, gap: Span) u32 {
        assert(gap.start <= gap.end);
        assert(gap.end <= splicer.source.len);

        const source = splicer.source;
        var result = gap.start;
        var blank_previous = false;
        var cursor = gap.start;

        for (0..gap.end - gap.start + 1) |_| {
            if (cursor >= gap.end) return result;

            const blank = blank_at(source, cursor);

            if (blank) {
                if (!blank_previous) result = cursor;
            }

            blank_previous = blank;
            cursor = line_end_of(source, .{ .end = gap.end, .start = cursor });
        }

        unreachable;
    }

    fn head_start(splicer: *const Splicer, gap: Span) u32 {
        assert(gap.start <= gap.end);
        assert(gap.end <= splicer.source.len);

        const source = splicer.source;
        var result: u32 = none;
        var cursor = gap.start;

        for (0..gap.end - gap.start + 1) |_| {
            if (cursor >= gap.end) return if (result == none) gap.end else result;

            if (blank_at(source, cursor)) {
                result = none;
            } else if (result == none) {
                result = cursor;
            }

            cursor = line_end_of(source, .{ .end = gap.end, .start = cursor });
        }

        unreachable;
    }
};

const AppendWalk = struct {
    cursor: u32,
    parent: u32,
};

const AppendKind = enum {
    descend,
    element,
    skip,
};

const Outcome = union(enum) {
    advanced,
    descend: Element,
    finished: u32,
};

const Style = enum {
    leading,
    lines_after,
    lines_before,
    trailing,
};

const Walk = struct {
    dropping: bool,
    gap_start: u32,
    root_pairs: bool,
    section: Section,
    section_end: u32,
};

const anchor_count_max: u32 = 64;
const byte_order_mark = "\xef\xbb\xbf";
const crlf_buffer_bytes: u32 = 256;
const depth_max = document_module.depth_max;
const emit_root: Emit = .{ .indent = span_empty, .node = root_index, .top = root_index };
const none = storage_module.none;
const root_index: u32 = 0;
const span_empty: Span = .{ .end = 0, .start = 0 };
const crlf_vtable: std.Io.Writer.VTable = .{ .drain = Crlf.drain };

comptime {
    assert(anchor_count_max >= 16);
    assert(root_index < none);
    assert(depth_max <= std.math.maxInt(u8));
}

pub fn write(
    document: *const Document,
    sink: *std.Io.Writer,
    options: Writer.Options,
) std.Io.Writer.Error!void {
    assert(document.lines.len > 0);
    assert(document.line_count <= document.lines.len);
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    if (!document.nodes[root_index].flags.edited) return sink.writeAll(document.source);
    return splice(document, sink, options);
}

pub fn splice(
    document: *const Document,
    sink: *std.Io.Writer,
    options: Writer.Options,
) std.Io.Writer.Error!void {
    assert(document.line_count <= document.lines.len);
    assert(document.node_count_parsed <= document.node_count);
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    var splicer: Splicer = undefined;

    splicer.init(document, sink, options);

    try splicer.run();
    try splicer.text_flush();

    assert(splicer.patch_depth == 0);
}

fn crlf_detect(source: []const u8) bool {
    assert(source.len <= scalar.source_bytes_max);
    assert(source.len < none);

    const newline = std.mem.findScalar(u8, source, '\n') orelse return false;
    return newline > 0 and source[newline - 1] == '\r';
}

fn header_last_of(document: *const Document) u32 {
    assert(document.line_count <= document.lines.len);
    assert(document.source.len <= scalar.source_bytes_max);

    const lines = document.lines[0..document.line_count];

    for (0..lines.len) |offset| {
        const number: u32 = @intCast(lines.len - 1 - offset);
        const first = scalar.whitespace_end(document.source, lines[number].start);
        if (document.source[first] != '[') continue;

        assert(number < document.line_count);

        return number;
    }

    return none;
}

fn blank_at(source: []const u8, position: u32) bool {
    assert(position <= source.len);
    assert(source.len <= scalar.source_bytes_max);

    const first = scalar.whitespace_end(source, position);
    if (first == source.len) return true;
    return source[first] == '\n' or source[first] == '\r';
}

fn indent_of(source: []const u8, start: u32) Span {
    assert(start <= source.len);
    assert(source.len <= scalar.source_bytes_max);

    return .{ .end = scalar.whitespace_end(source, start), .start = start };
}

fn line_start_of(source: []const u8, position: u32) u32 {
    assert(position <= source.len);
    assert(source.len <= scalar.source_bytes_max);

    const newline = std.mem.findScalarLast(u8, source[0..position], '\n') orelse return 0;
    const start: u32 = @intCast(newline + 1);

    assert(start <= position);

    return start;
}

fn line_end_of(source: []const u8, region: Span) u32 {
    assert(region.start < region.end);
    assert(region.end <= source.len);

    const newline = std.mem.findScalarPos(u8, source[0..region.end], region.start, '\n') orelse {
        return region.end;
    };

    const end: u32 = @intCast(newline + 1);

    assert(end <= region.end);

    return end;
}

fn line_end_after(source: []const u8, end: u32) u32 {
    assert(end <= source.len);
    assert(source.len <= scalar.source_bytes_max);

    const index = comma_skip(source, scalar.whitespace_end(source, end));
    const newline = std.mem.findScalarPos(u8, source, index, '\n') orelse source.len;
    const line_end: u32 = @intCast(newline + 1);

    assert(line_end > end);

    return line_end;
}

fn comma_skip(source: []const u8, index: u32) u32 {
    assert(index <= source.len);
    assert(source.len <= scalar.source_bytes_max);

    if (index == source.len) return index;
    if (source[index] != ',') return index;

    const after = scalar.whitespace_end(source, index + 1);

    assert(after > index);

    return after;
}

fn untouched(document: *const Document, node: u32) bool {
    assert(node > root_index);
    assert(node < document.node_count);

    if (node >= document.node_count_parsed) return false;
    return !document.nodes[node].flags.edited;
}

fn element_gone(document: *const Document, leaf: u32) bool {
    assert(leaf > root_index);
    assert(leaf < document.node_count_parsed);

    const record = &document.nodes[leaf];
    if (record.flags.detached) return true;
    if (!record.flags.edited) return false;
    return serializer_module.flattened(document, leaf);
}

fn alone_with_comma(source: []const u8, frame: *const PatchFrame, element: Element) bool {
    assert(frame.open < element.start);
    assert(element.end <= frame.close);
    assert(frame.close < source.len);

    if (!alone_on_line(source, frame.open, element)) return false;

    const comma = comma_after(source, .{ .end = frame.close, .start = element.end });
    if (comma == none) return true;
    return std.mem.findScalar(u8, source[element.end..comma], '\n') == null;
}

fn alone_on_line(source: []const u8, open: u32, element: Element) bool {
    assert(open < element.start);
    assert(element.end <= source.len);

    const start = line_start_of(source, element.start);
    if (start <= open) return false;
    if (scalar.whitespace_end(source, start) != element.start) return false;

    const index = comma_skip(source, scalar.whitespace_end(source, element.end));
    if (index == source.len) return false;

    return switch (source[index]) {
        '\n', '\r', '#' => true,
        else => false,
    };
}

fn comma_after(source: []const u8, gap: Span) u32 {
    assert(gap.start <= gap.end);
    assert(gap.end < source.len);

    const position = gap_skip(source, gap.start, false);

    assert(position <= gap.end);

    return if (source[position] == ',') position else none;
}

fn element_seek(source: []const u8, cursor: u32) u32 {
    assert(cursor < source.len);
    assert(source.len <= scalar.source_bytes_max);

    return gap_skip(source, cursor, true);
}

fn gap_skip(source: []const u8, start: u32, commas: bool) u32 {
    assert(start <= source.len);
    assert(source.len <= scalar.source_bytes_max);

    var index = start;

    for (0..source.len - start + 1) |_| {
        if (index == source.len) return index;

        switch (source[index]) {
            ' ', '\t', '\r', '\n' => index += 1,
            ',' => if (commas) {
                index += 1;
            } else {
                return index;
            },
            '#' => {
                const newline = std.mem.findScalarPos(u8, source, index, '\n') orelse source.len;

                index = @intCast(newline);
            },
            else => return index,
        }
    }

    unreachable;
}

fn element_at(document: *const Document, frame: PatchFrame, position: u32) Element {
    assert(position < frame.close);
    assert(frame.next <= frame.range_end);

    const source = document.source;
    var value = position;
    var segments: u32 = 1;

    if (frame.table) {
        const key = key_skip(source, position);

        value = key.value;
        segments = key.segments;
    }

    const end = scalar.value_skip(source, value);
    const leaf = leaf_find(document, frame, segments);

    return .{ .end = end, .leaf = leaf, .start = position, .value = value };
}

fn leaf_find(document: *const Document, frame: PatchFrame, segments: u32) u32 {
    assert(segments > 0);
    assert(frame.next < frame.range_end);

    for (frame.next..frame.range_end) |index| {
        const node: u32 = @intCast(index);
        const chain: serializer_module.Chain = .{ .node = node, .top = frame.container };
        if (depth_below(document, chain) != segments) continue;

        assert(node < frame.range_end);

        return node;
    }

    unreachable;
}

fn depth_below(document: *const Document, chain: serializer_module.Chain) u32 {
    assert(chain.top < chain.node);
    assert(chain.node < document.node_count);

    var depth: u32 = 0;
    var current = chain.node;

    for (0..depth_max + 1) |_| {
        if (current == chain.top) return depth;

        current = document.nodes[current].parent;
        depth += 1;
    }

    unreachable;
}

fn element_leaf_is(document: *const Document, frame: PatchFrame, node: u32) bool {
    assert(node > frame.container);
    assert(frame.open < frame.close);

    var scan = frame;

    scan.cursor = frame.open + 1;
    scan.next = frame.container + 1;

    for (0..document.source.len) |_| {
        const position = element_seek(document.source, scan.cursor);
        if (position == scan.close) return false;

        const element = element_at(document, scan, position);
        if (element.leaf == node) return true;

        scan.cursor = element.end;
        scan.next = subtree_end(document, element.leaf);
    }

    unreachable;
}

fn key_skip(source: []const u8, start: u32) KeySkip {
    assert(start < source.len);
    assert(source.len <= scalar.source_bytes_max);

    var index = start;
    var segments: u32 = 0;

    for (0..source.len - start) |_| {
        segments += 1;

        index = switch (source[index]) {
            '"', '\'' => scalar.string_end_of(source, index) orelse unreachable,
            else => bare_end(source, index),
        };

        index = scalar.whitespace_end(source, index);

        if (source[index] == '.') {
            index = scalar.whitespace_end(source, index + 1);

            continue;
        }

        assert(source[index] == '=');

        return .{ .segments = segments, .value = scalar.whitespace_end(source, index + 1) };
    }

    unreachable;
}

fn bare_end(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source.len <= scalar.source_bytes_max);

    var index = start;

    for (source[start..]) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => index += 1,
            else => break,
        }
    }

    assert(index > start);

    return index;
}

fn chain_contains(document: *const Document, chain: serializer_module.Chain) bool {
    assert(chain.node < document.node_count);
    assert(chain.top < document.node_count);

    var current = chain.node;

    for (0..depth_max + 2) |_| {
        if (current == chain.top) return true;
        if (current == none) return false;
        if (current < chain.top) return false;

        current = document.nodes[current].parent;
    }

    unreachable;
}

fn inline_context(document: *const Document, node: u32) bool {
    assert(node > root_index);
    assert(node < document.node_count);

    var current = document.nodes[node].parent;

    for (0..depth_max + 1) |_| {
        if (current == root_index) return false;
        if (document.nodes[current].flags.closed) return true;

        current = document.nodes[current].parent;
    }

    unreachable;
}

fn inline_dirty(document: *const Document, node: u32) bool {
    assert(node > root_index);
    assert(node < document.node_count_parsed);

    const record = &document.nodes[node];

    switch (record.kind) {
        .array, .table => {},
        .boolean, .datetime, .float, .integer, .string => return false,
    }

    if (child_appended(document, node)) return true;

    for (node + 1..subtree_end(document, node)) |index| {
        const below = &document.nodes[index];
        if (below.flags.detached) return true;
        if (below.flags.edited) return true;
        if (child_appended(document, @intCast(index))) return true;
    }

    return false;
}

fn child_appended(document: *const Document, node: u32) bool {
    assert(node < document.node_count_parsed);
    assert(document.node_count_parsed <= document.node_count);

    const last = document.nodes[node].child_last;
    if (last == none) return false;
    return last >= document.node_count_parsed;
}

fn subtree_end(document: *const Document, node: u32) u32 {
    assert(node < document.node_count_parsed);
    assert(document.node_count_parsed <= document.node_count);

    var index = node + 1;

    for (node + 1..document.node_count_parsed) |_| {
        const parent = document.nodes[index].parent;
        if (parent == none) break;
        if (parent < node) break;

        index += 1;
    }

    assert(index <= document.node_count_parsed);

    return index;
}
