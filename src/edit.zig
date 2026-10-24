const std = @import("std");

const datetime_module = @import("datetime.zig");
const document_module = @import("document.zig");
const hash_index = @import("hash_index.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const CapacityError = document_module.CapacityError;
const Datetime = datetime_module.Datetime;
const Document = document_module.Document;
const Kind = document_module.Kind;
const Node = document_module.Node;
const Record = storage_module.Record;
const Storage = storage_module.Storage;
const ValueError = writer_module.Writer.ValueError;

pub const ArrayForm = enum {
    array_of_tables,
    inline_array,
};

pub const Content = union(Kind) {
    array: ArrayForm,
    boolean: bool,
    datetime: Datetime,
    float: f64,
    integer: i64,
    string: []const u8,
    table: TableForm,
};

pub const EditError = CapacityError || ValueError;

pub const Merge = struct {
    arrays: Arrays,

    pub const Arrays = enum {
        join,
        replace,
    };
};

pub const TableForm = enum {
    dotted,
    header,
    implicit,
    inline_table,
};

const Copy = struct {
    depth: u32,
    source: u32,
    target: u32,
};

const FormsCopy = struct {
    source: *const Record,
    target: u32,
};

const Need = struct {
    depth: u32,
    node_count: u32,
    text_bytes: u64,
};

const Pair = struct {
    entry: *const Record,
    existing: u32,
};

const Placement = struct {
    depth: u32,
    parent: u32,
};

const Step = struct {
    depth: u32,
    entry: u32,
    existing: u32,
    options: Merge,
    table: u32,
};

const depth_max = document_module.depth_max;
const none = storage_module.none;
const root_index: u32 = 0;
const source_bytes_max = document_module.source_bytes_max;

const flags_inserted: storage_module.Flags = .{
    .array_of_tables = false,
    .closed = false,
    .detached = false,
    .edited = false,
    .explicit = false,
    .indexed = false,
    .owner = .none,
};

comptime {
    assert(root_index < none);
    assert(@sizeOf(Content) <= 32);
}

pub fn init(document: *Document, storage: Storage) void {
    assert(storage.nodes.len > 0);
    assert(storage.nodes.len <= storage_module.node_count_limit);
    assert(std.math.isPowerOfTwo(storage.buckets.len));
    assert(storage.buckets.len >= storage.nodes.len * 2);

    document.* = .{
        .bucket_count = 0,
        .buckets = storage.buckets,
        .diagnostic = document_module.position_none,
        .hash_seed = storage.hash_seed,
        .indexed_count = 0,
        .indexed_first = none,
        .line_count = 0,
        .lines = &.{},
        .node_count = 1,
        .node_count_parsed = 0,
        .nodes = storage.nodes,
        .source = "",
        .text = storage.text,
        .text_used = 0,
    };

    const root = &document.nodes[root_index];

    record_clear(root, .{ .depth = 0, .parent = none });
    root.flags.explicit = true;

    assert(root.kind == .table);
    assert(document.position_of(document.root()) == null);
}

pub fn set(document: *Document, table: Node, key: []const u8, content: Content) EditError!Node {
    assert(@backingInt(table) < document.node_count);
    assert(key.len <= source_bytes_max);
    assert(content_text_bytes(&content) <= source_bytes_max);

    const index = @backingInt(table);

    assert(document.nodes[index].kind == .table);
    assert(!document.nodes[index].flags.detached);

    document.diagnostic = document_module.position_none;

    try content_validate(&content);

    if (!std.unicode.utf8ValidateSlice(key)) return error.Utf8Invalid;

    const depth = depth_of(document, index) + 1;
    const string_bytes = content_text_bytes(&content);

    if (hash_index.member_find(document, index, key)) |member| {
        const need: Need = .{ .depth = depth, .node_count = 0, .text_bytes = string_bytes };

        try capacity_check(document, need);

        member_vacate(document, member);
        content_store(document, member, &content);
        edited_mark(document, member);

        assert(document.nodes[member].kind == std.meta.activeTag(content));

        return @fromBackingInt(member);
    }

    const need: Need = .{ .depth = depth, .node_count = 1, .text_bytes = string_bytes + key.len };

    try capacity_check(document, need);

    const created = record_append(document, .{ .depth = depth, .parent = index });

    document.nodes[created].key = text_copy(document, key);

    content_store(document, created, &content);
    hash_index.insert(document, created);
    edited_mark(document, root_index);

    assert(hash_index.member_find(document, index, key) == created);

    return @fromBackingInt(created);
}

pub fn append(document: *Document, array: Node, content: Content) EditError!Node {
    assert(@backingInt(array) < document.node_count);
    assert(content_text_bytes(&content) <= source_bytes_max);

    const index = @backingInt(array);

    assert(document.nodes[index].kind == .array);
    assert(!document.nodes[index].flags.detached);

    document.diagnostic = document_module.position_none;

    try content_validate(&content);

    const depth = depth_of(document, index) + 1;
    const string_bytes = content_text_bytes(&content);

    try capacity_check(document, .{ .depth = depth, .node_count = 1, .text_bytes = string_bytes });

    const created = record_append(document, .{ .depth = depth, .parent = index });

    content_store(document, created, &content);
    edited_mark(document, root_index);

    assert(document.nodes[index].child_last == created);

    return @fromBackingInt(created);
}

pub fn remove(document: *Document, node: Node) void {
    assert(@backingInt(node) > root_index);
    assert(@backingInt(node) < document.node_count);

    const index = @backingInt(node);

    assert(!document.nodes[index].flags.detached);

    const parent = document.nodes[index].parent;

    child_unlink(document, index);
    edited_mark(document, root_index);

    document.nodes[index].flags.detached = true;

    const indexed_below = children_detach(document, index);
    const rebuild_needed = indexed_below or document.nodes[index].flags.indexed;

    if (rebuild_needed) {
        hash_index.rebuild(document);
    } else {
        if (document.nodes[parent].flags.indexed) hash_index.remove(document, index);
    }

    assert(document.nodes[index].flags.detached);
}

pub fn merge(document: *Document, source: *const Document, options: Merge) CapacityError!void {
    assert(source != document);
    assert(source.node_count > 0);
    assert(document.node_count > 0);
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    document.diagnostic = document_module.position_none;

    var source_table: u32 = root_index;
    var target_table: u32 = root_index;
    var depth: u32 = 0;
    var cursor = source.nodes[root_index].child_first;

    for (0..2 * source.node_count + 1) |_| {
        if (cursor == none) {
            if (source_table == root_index) return;

            cursor = source.nodes[source_table].sibling_next;
            source_table = source.nodes[source_table].parent;
            target_table = document.nodes[target_table].parent;
            depth -= 1;

            continue;
        }

        const entry = &source.nodes[cursor];
        const existing = hash_index.member_find(document, target_table, entry.key) orelse none;

        if (descend_is(document, .{ .entry = entry, .existing = existing })) {
            source_table = cursor;
            target_table = existing;
            depth += 1;
            cursor = entry.child_first;

            continue;
        }

        try entry_merge(document, source, .{
            .depth = depth + 1,
            .entry = cursor,
            .existing = existing,
            .options = options,
            .table = target_table,
        });

        cursor = entry.sibling_next;
    }

    unreachable;
}

fn descend_is(document: *const Document, pair: Pair) bool {
    assert(pair.existing == none or pair.existing < document.node_count);
    assert(!pair.entry.flags.detached);

    if (pair.existing == none) return false;
    if (document.nodes[pair.existing].kind != .table) return false;
    return pair.entry.kind == .table;
}

fn entry_merge(document: *Document, source: *const Document, step: Step) CapacityError!void {
    assert(step.entry < source.node_count);
    assert(step.table < document.node_count);
    assert(step.depth > 0);

    if (step.existing == none) {
        const placement: Placement = .{ .depth = step.depth, .parent = step.table };
        const created = try record_copy(document, source, placement, step.entry);

        return children_copy(document, source, .{
            .depth = step.depth,
            .source = step.entry,
            .target = created,
        });
    }

    const copy: Copy = .{ .depth = step.depth, .source = step.entry, .target = step.existing };

    try existing_merge(document, source, copy, step.options);
}

fn existing_merge(
    document: *Document,
    source: *const Document,
    copy: Copy,
    options: Merge,
) CapacityError!void {
    assert(copy.source < source.node_count);
    assert(copy.target < document.node_count);
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    const entry = &source.nodes[copy.source];

    if (document.nodes[copy.target].kind == .array) {
        if (entry.kind == .array) {
            if (options.arrays == .join) return elements_join(document, source, copy);
        }
    }

    const string_bytes = record_text_bytes(entry);
    const need: Need = .{ .depth = copy.depth, .node_count = 0, .text_bytes = string_bytes };

    capacity_check(document, need) catch |err| {
        document.diagnostic = source.position_of(@fromBackingInt(copy.source)) orelse
            document_module.position_none;

        return err;
    };

    member_vacate(document, copy.target);
    record_forms_copy(document, .{ .source = entry, .target = copy.target });
    edited_mark(document, copy.target);

    try children_copy(document, source, copy);

    assert(document.nodes[copy.target].kind == entry.kind);
}

fn elements_join(document: *Document, source: *const Document, copy: Copy) CapacityError!void {
    assert(source.nodes[copy.source].kind == .array);
    assert(document.nodes[copy.target].kind == .array);

    var element = source.nodes[copy.source].child_first;

    for (0..source.nodes[copy.source].count) |_| {
        const placement: Placement = .{ .depth = copy.depth + 1, .parent = copy.target };
        const created = try record_copy(document, source, placement, element);

        try children_copy(document, source, .{
            .depth = copy.depth + 1,
            .source = element,
            .target = created,
        });

        element = source.nodes[element].sibling_next;
    }

    assert(element == none);
}

fn children_copy(document: *Document, source: *const Document, copy: Copy) CapacityError!void {
    assert(copy.source < source.node_count);
    assert(copy.target < document.node_count);
    assert(document.nodes[copy.target].count == 0);

    var source_parent = copy.source;
    var target_parent = copy.target;
    var depth = copy.depth;
    var cursor = source.nodes[copy.source].child_first;

    for (0..2 * source.node_count + 1) |_| {
        if (cursor == none) {
            if (source_parent == copy.source) return;

            cursor = source.nodes[source_parent].sibling_next;
            source_parent = source.nodes[source_parent].parent;
            target_parent = document.nodes[target_parent].parent;
            depth -= 1;

            continue;
        }

        const placement: Placement = .{ .depth = depth + 1, .parent = target_parent };
        const created = try record_copy(document, source, placement, cursor);

        if (source.nodes[cursor].child_first == none) {
            cursor = source.nodes[cursor].sibling_next;

            continue;
        }

        source_parent = cursor;
        target_parent = created;
        depth += 1;
        cursor = source.nodes[cursor].child_first;
    }

    unreachable;
}

fn record_copy(
    document: *Document,
    source: *const Document,
    placement: Placement,
    original: u32,
) CapacityError!u32 {
    assert(original < source.node_count);
    assert(placement.parent < document.node_count);

    const entry = &source.nodes[original];
    const text_bytes = record_text_bytes(entry) + entry.key.len;
    const need: Need = .{ .depth = placement.depth, .node_count = 1, .text_bytes = text_bytes };

    capacity_check(document, need) catch |err| {
        document.diagnostic = source.position_of(@fromBackingInt(original)) orelse
            document_module.position_none;

        return err;
    };

    const created = record_append(document, placement);

    document.nodes[created].key = text_copy(document, entry.key);

    record_forms_copy(document, .{ .source = entry, .target = created });
    edited_mark(document, root_index);

    if (document.nodes[placement.parent].kind == .table) hash_index.insert(document, created);

    assert(document.nodes[created].kind == entry.kind);

    return created;
}

fn record_forms_copy(document: *Document, forms: FormsCopy) void {
    assert(forms.target < document.node_count);
    assert(document.nodes[forms.target].count == 0);

    const entry = forms.source;
    const record = &document.nodes[forms.target];

    record.kind = entry.kind;
    record.flags.array_of_tables = entry.flags.array_of_tables;
    record.flags.closed = entry.flags.closed;
    record.flags.explicit = entry.flags.explicit;
    record.section = if (entry.section == none) none else 0;

    record.payload = switch (entry.kind) {
        .array, .table => .{ .none = {} },
        .boolean => .{ .boolean = entry.payload.boolean },
        .datetime => .{ .datetime = entry.payload.datetime },
        .float => .{ .float = entry.payload.float },
        .integer => .{ .integer = entry.payload.integer },
        .string => .{ .string = text_copy(document, entry.payload.string) },
    };

    assert(record.kind == entry.kind);
}

fn record_text_bytes(record: *const Record) u64 {
    assert(record.key.len <= source_bytes_max);
    assert(!record.flags.detached);

    const result: u64 = switch (record.kind) {
        .string => record.payload.string.len,
        .array, .boolean, .datetime, .float, .integer, .table => 0,
    };

    assert(result <= source_bytes_max);

    return result;
}

fn content_validate(content: *const Content) ValueError!void {
    assert(content_text_bytes(content) <= source_bytes_max);

    switch (content.*) {
        .datetime => |*datetime| {
            if (!datetime_module.valid(datetime)) return error.DatetimeInvalid;
        },
        .string => |text| {
            if (!std.unicode.utf8ValidateSlice(text)) return error.Utf8Invalid;
        },
        .array, .boolean, .float, .integer, .table => {},
    }
}

fn content_text_bytes(content: *const Content) u64 {
    const result: u64 = switch (content.*) {
        .string => |text| text.len,
        .array, .boolean, .datetime, .float, .integer, .table => 0,
    };

    assert(result <= source_bytes_max);

    if (result > 0) assert(content.* == .string);

    return result;
}

fn capacity_check(document: *const Document, need: Need) CapacityError!void {
    assert(need.node_count <= 1);
    assert(document.node_count <= document.nodes.len);
    assert(document.text_used <= document.text.len);

    if (need.node_count > document.nodes.len - document.node_count) return error.NodesExhausted;
    if (need.text_bytes > document.text.len - document.text_used) return error.TextExhausted;
    if (need.depth > depth_max) return error.DepthExceeded;
}

fn depth_of(document: *const Document, node: u32) u32 {
    assert(node < document.node_count);
    assert(document.node_count <= document.nodes.len);

    var depth: u32 = 0;
    var current = node;

    for (0..document.node_count) |_| {
        if (current == root_index) return depth;

        assert(document.nodes[current].parent < current);

        current = document.nodes[current].parent;
        depth += 1;
    }

    unreachable;
}

fn record_append(document: *Document, placement: Placement) u32 {
    assert(document.node_count < document.nodes.len);
    assert(placement.parent < document.node_count);
    assert(placement.depth <= depth_max);

    const created = document.node_count;

    record_clear(&document.nodes[created], placement);

    document.node_count += 1;

    hash_index.child_link(document, .{ .child = created, .parent = placement.parent });

    assert(document.nodes[placement.parent].child_last == created);

    return created;
}

fn record_clear(record: *Record, placement: Placement) void {
    assert(placement.depth <= depth_max);
    assert(placement.parent == none or placement.depth > 0);

    record.* = .{
        .child_first = none,
        .child_last = none,
        .count = 0,
        .flags = flags_inserted,
        .indexed_next = none,
        .key = "",
        .kind = .table,
        .parent = placement.parent,
        .payload = .{ .none = {} },
        .section = none,
        .sibling_next = none,
    };
}

fn content_store(document: *Document, node: u32, content: *const Content) void {
    assert(node < document.node_count);
    assert(document.nodes[node].count == 0);

    const record = &document.nodes[node];

    record.kind = std.meta.activeTag(content.*);
    record.flags.array_of_tables = false;
    record.flags.closed = false;
    record.flags.explicit = false;
    record.section = none;

    switch (content.*) {
        .array => |form| {
            record.payload = .{ .none = {} };

            switch (form) {
                .array_of_tables => record.flags.array_of_tables = true,
                .inline_array => record.flags.closed = true,
            }
        },
        .boolean => |value| record.payload = .{ .boolean = value },
        .datetime => |value| record.payload = .{ .datetime = value },
        .float => |value| record.payload = .{ .float = value },
        .integer => |value| record.payload = .{ .integer = value },
        .string => |text| record.payload = .{ .string = text_copy(document, text) },
        .table => |form| table_form_store(record, form),
    }

    assert(record.kind == std.meta.activeTag(content.*));
}

fn table_form_store(record: *Record, form: TableForm) void {
    assert(record.kind == .table);
    assert(record.section == none);

    record.payload = .{ .none = {} };

    switch (form) {
        .dotted => record.section = 0,
        .header => record.flags.explicit = true,
        .implicit => {},
        .inline_table => record.flags.closed = true,
    }
}

fn edited_mark(document: *Document, node: u32) void {
    assert(node < document.node_count);
    assert(!document.nodes[node].flags.detached);

    document.nodes[node].flags.edited = true;
    document.nodes[root_index].flags.edited = true;
}

fn member_vacate(document: *Document, member: u32) void {
    assert(member > root_index);
    assert(member < document.node_count);

    const record = &document.nodes[member];
    const indexed_below = children_detach(document, member);
    const rebuild_needed = indexed_below or record.flags.indexed;

    record.flags.indexed = false;
    record.child_first = none;
    record.child_last = none;
    record.count = 0;

    if (rebuild_needed) hash_index.rebuild(document);

    assert(!record.flags.indexed);
}

fn children_detach(document: *Document, top: u32) bool {
    assert(top < document.node_count);
    assert(document.node_count <= document.nodes.len);

    var indexed = false;
    var parent = top;
    var cursor = document.nodes[top].child_first;

    for (0..2 * document.node_count + 1) |_| {
        if (cursor == none) {
            if (parent == top) return indexed;

            cursor = document.nodes[parent].sibling_next;
            parent = document.nodes[parent].parent;

            continue;
        }

        const record = &document.nodes[cursor];

        record.flags.detached = true;

        if (record.flags.indexed) indexed = true;

        if (record.child_first != none) {
            parent = cursor;
            cursor = record.child_first;

            continue;
        }

        cursor = record.sibling_next;
    }

    unreachable;
}

fn child_unlink(document: *Document, child: u32) void {
    assert(child > root_index);
    assert(child < document.node_count);

    const record = &document.nodes[child];
    const container = &document.nodes[record.parent];

    var previous: u32 = none;
    var cursor = container.child_first;

    for (0..container.count) |_| {
        if (cursor == child) break;

        previous = cursor;
        cursor = document.nodes[cursor].sibling_next;
    }

    assert(cursor == child);

    if (previous == none) {
        container.child_first = record.sibling_next;
    } else {
        document.nodes[previous].sibling_next = record.sibling_next;
    }

    if (container.child_last == child) container.child_last = previous;

    container.count -= 1;
    record.sibling_next = none;

    if (container.count == 0) assert(container.child_first == none);
}

fn text_copy(document: *Document, text: []const u8) []const u8 {
    assert(text.len <= document.text.len - document.text_used);
    assert(document.text_used <= document.text.len);

    if (text.len == 0) return "";

    const start = document.text_used;

    @memcpy(document.text[start..][0..text.len], text);

    document.text_used += @intCast(text.len);

    const result = document.text[start..document.text_used];

    assert(std.mem.eql(u8, result, text));

    return result;
}
