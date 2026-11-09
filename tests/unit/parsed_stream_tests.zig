const std = @import("std");
const parsed_stream = @import("../../src/parsed_stream.zig");
const Importer = @import("../../src/import.zig").Importer;
const Environment = @import("../../src/environment.zig").Environment;
const ExprPool = @import("../../src/expr.zig").Pool;
const LevelPool = @import("../../src/level.zig").Pool;

const ChunkReader = struct {
    bytes: []const u8,
    position: usize = 0,
    chunk: usize = 3,
    fail_at_end: bool = false,

    fn read(self: *@This(), output: []u8) error{InjectedReadFailure}!usize {
        if (self.position == self.bytes.len and self.fail_at_end) return error.InjectedReadFailure;
        const count = @min(self.chunk, @min(output.len, self.bytes.len - self.position));
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
    fn reader(self: *@This()) std.io.Reader(*@This(), error{InjectedReadFailure}, read) {
        return .{ .context = self };
    }
};

fn apply(importer: *Importer, allocator: std.mem.Allocator, item: parsed_stream.Item) @import("../../src/common.zig").Error!void {
    return switch (item) {
        .scanned => |value| importer.scanned(value.record(), value.text()),
        .json => |value| importer.line(value.*),
        .raw => |value| importer.lineBytes(allocator, value),
        .invalid => error.InvalidInput,
    };
}

test "parsed batches retain names and JSON through slot reuse and a partial last line" {
    const source =
        "{\"meta\":{\"format\":{\"version\":\"3.0.0\"}}}\n" ++
        "  \r\t\n" ++
        "{\"in\":1,\"str\":{\"pre\":0,\"str\":\"λ\"}}\n" ++
        "{ \"str\" : { \"str\" : \"escaped\\nname\", \"pre\" : 0 }, \"in\" : 2 }\n" ++
        "{\"ie\":1,\"sort\":0}\n" ++
        "{\"axiom\":{\"name\":1,\"levelParams\":[],\"type\":1}}\n" ++
        "{\"in\":3,\"str\":{\"pre\":0,\"str\":\"last\"}}";
    var input: ChunkReader = .{ .bytes = source, .chunk = 1 };
    const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 1, .arena_bytes = 4096 });
    defer stream.deinit();
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = ExprPool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var importer = Importer.init(&expressions, &environment);
    defer importer.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var count: usize = 0;
    while (true) {
        const batch = stream.next();
        defer stream.release(batch);
        var items = batch.iterator();
        while (items.next()) |item| {
            try apply(&importer, arena.allocator(), item);
            count += 1;
        }
        if (batch.io_error) |err| return err;
        if (batch.finished) break;
    }
    try importer.finish();
    try std.testing.expectEqual(@as(usize, 6), count);
    try std.testing.expectEqual(@as(u64, 6), importer.lines);
    try std.testing.expectEqual(@as(u64, 1), importer.declarations);
    try std.testing.expectEqualStrings("λ", environment.getString(environment.names.items[try importer.names.get(1)].atom));
    try std.testing.expectEqualStrings("escaped\nname", environment.getString(environment.names.items[try importer.names.get(2)].atom));
    try std.testing.expectEqualStrings("last", environment.getString(environment.names.items[try importer.names.get(3)].atom));
}

test "parsed stream preserves earlier rejection before later malformed JSON" {
    var input: ChunkReader = .{ .bytes = "{\"meta\":{\"format\":{\"version\":\"99.0\"}}}\n{invalid}\n", .chunk = 4096 };
    const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 8, .arena_bytes = 4096 });
    defer stream.deinit();
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = ExprPool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var importer = Importer.init(&expressions, &environment);
    defer importer.deinit();
    const batch = stream.next();
    defer stream.release(batch);
    try std.testing.expectEqual(@as(usize, 2), batch.length);
    try std.testing.expectError(error.Unsupported, apply(&importer, std.testing.allocator, batch.get(0)));
    try std.testing.expect(batch.get(1) == .invalid);
    try std.testing.expect(batch.finished);
}

test "parsed stream publishes complete records before a read error" {
    var input: ChunkReader = .{ .bytes = "{\"bvar\":0,\"ie\":1}\n", .fail_at_end = true };
    const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 8, .arena_bytes = 1024 });
    defer stream.deinit();
    const batch = stream.next();
    defer stream.release(batch);
    try std.testing.expectEqual(@as(usize, 1), batch.length);
    try std.testing.expectEqual(@as(u32, 1), batch.get(0).scanned.record().id);
    try std.testing.expectEqual(error.InjectedReadFailure, batch.io_error.?);
}

test "parsed stream arena exhaustion retains one raw line then resumes" {
    var input: ChunkReader = .{ .bytes = "{\"meta\":{\"format\":{\"version\":\"3.0\"}}}\n{\"bvar\":0,\"ie\":1}\n", .chunk = 4096 };
    const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 8, .arena_bytes = 8, .profile = true });
    defer stream.deinit();
    const first = stream.next();
    try std.testing.expectEqual(@as(usize, 1), first.length);
    try std.testing.expect(first.get(0) == .raw);
    try std.testing.expectEqualStrings("{\"meta\":{\"format\":{\"version\":\"3.0\"}}}", first.get(0).raw);
    stream.release(first);
    {
        const second = stream.next();
        defer stream.release(second);
        try std.testing.expectEqual(@as(usize, 1), second.length);
        try std.testing.expect(second.get(0) == .scanned);
        try std.testing.expect(second.finished);
    }
    const profile = stream.finish();
    try std.testing.expectEqual(@as(u64, 2), profile.batches);
    try std.testing.expectEqual(@as(u64, 1), profile.oversized_fallbacks);
}

test "parsed stream cancellation wakes a full queue and an oversized record wait" {
    {
        const source = "{\"bvar\":0,\"ie\":1}\n" ** 32;
        var input: ChunkReader = .{ .bytes = source, .chunk = 4096 };
        const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 1, .arena_bytes = 16 });
        defer stream.deinit();
        const batch = stream.next();
        try std.testing.expectEqual(@as(usize, 1), batch.length);
    }
    {
        var oversized: ChunkReader = .{ .bytes = "{\"meta\":{\"format\":{\"version\":\"3.0\"}}}\n" };
        const other = try parsed_stream.Stream(@TypeOf(oversized.reader())).create(std.testing.allocator, oversized.reader(), .{ .records_per_batch = 1, .arena_bytes = 8 });
        defer other.deinit();
        try std.testing.expect(other.next().get(0) == .raw);
    }
}

test "parsed stream keeps the existing line limit" {
    var input: ChunkReader = .{ .bytes = "123456789\n", .chunk = 1 };
    const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 1, .arena_bytes = 16, .line_limit = 8 });
    defer stream.deinit();
    const batch = stream.next();
    defer stream.release(batch);
    try std.testing.expectEqual(@as(usize, 0), batch.length);
    try std.testing.expectEqual(error.StreamTooLong, batch.io_error.?);
}

test "parsed stream handles empty input and exact batch boundary EOF" {
    for ([_][]const u8{ "", " \r\t\n\n\t", "{\"bvar\":0,\"ie\":1}\n{\"bvar\":1,\"ie\":2}\n" }, 0..) |source, index| {
        var input: ChunkReader = .{ .bytes = source };
        const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 2, .arena_bytes = 16 });
        defer stream.deinit();
        const first = stream.next();
        if (index < 2) {
            try std.testing.expectEqual(@as(usize, 0), first.length);
            try std.testing.expect(first.finished);
            stream.release(first);
        } else {
            try std.testing.expectEqual(@as(usize, 2), first.length);
            try std.testing.expect(!first.finished);
            stream.release(first);
            const last = stream.next();
            defer stream.release(last);
            try std.testing.expectEqual(@as(usize, 0), last.length);
            try std.testing.expect(last.finished);
        }
    }
}

test "parsed stream rejects truncated final JSON after earlier records" {
    var input: ChunkReader = .{ .bytes = "{\"bvar\":0,\"ie\":1}\n{\"bvar\":" };
    const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 8, .arena_bytes = 4096 });
    defer stream.deinit();
    const batch = stream.next();
    defer stream.release(batch);
    try std.testing.expectEqual(@as(usize, 2), batch.length);
    try std.testing.expect(batch.get(0) == .scanned);
    try std.testing.expect(batch.get(1) == .invalid);
    try std.testing.expect(batch.finished);
}

test "compact parsed records preserve every scanner kind and full integer fields" {
    const lines = [_][]const u8{
        "{\"app\":{\"arg\":4294967294,\"fn\":4294967293},\"ie\":4294967295}",
        "{\"bvar\":4294967294,\"ie\":4294967295}",
        "{\"ie\":4294967295,\"sort\":4294967294}",
        "{\"const\":{\"name\":4294967294,\"us\":[]},\"ie\":4294967295}",
        "{\"lam\":{\"binderInfo\":\"implicit\",\"body\":4294967291,\"name\":4294967292,\"type\":4294967293},\"ie\":4294967295}",
        "{\"forallE\":{\"binderInfo\":\"default\",\"body\":4294967291,\"name\":4294967292,\"type\":4294967293},\"ie\":4294967295}",
        "{\"ie\":4294967295,\"letE\":{\"body\":4294967291,\"name\":4294967292,\"nondep\":false,\"type\":4294967293,\"value\":4294967294}}",
        "{\"ie\":4294967295,\"proj\":{\"idx\":4294967291,\"struct\":4294967292,\"typeName\":4294967293}}",
        "{\"il\":4294967295,\"succ\":4294967294}",
        "{\"il\":4294967295,\"max\":[4294967293,4294967294]}",
        "{\"il\":4294967295,\"imax\":[4294967293,4294967294]}",
        "{\"il\":4294967295,\"param\":4294967294}",
        "{\"in\":4294967295,\"str\":{\"pre\":4294967294,\"str\":\"名字λ\"}}",
        "{\"in\":4294967295,\"num\":{\"i\":4294967293,\"pre\":4294967294}}",
    };
    for (lines) |line| {
        var input: ChunkReader = .{ .bytes = line };
        const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 2, .arena_bytes = 1024 });
        defer stream.deinit();
        const batch = stream.next();
        defer stream.release(batch);
        try std.testing.expectEqual(@as(usize, 1), batch.length);
        try std.testing.expect(batch.get(0) == .scanned);
        const expected = @import("../../src/scan.zig").scan(line).?;
        const compact = batch.get(0).scanned;
        const actual = compact.record();
        try std.testing.expectEqual(expected.kind, actual.kind);
        try std.testing.expectEqual(expected.id, actual.id);
        try std.testing.expectEqual(expected.a, actual.a);
        try std.testing.expectEqual(expected.d, actual.d);
        try std.testing.expectEqual(expected.universe_count, actual.universe_count);
        if (expected.kind == .name_str) {
            try std.testing.expectEqual(@as(u32, 0), actual.b);
            try std.testing.expectEqual(@as(usize, actual.c), compact.text().len);
            try std.testing.expectEqualStrings(line[expected.b..expected.c], compact.text());
        } else {
            try std.testing.expectEqual(expected.b, actual.b);
            try std.testing.expectEqual(expected.c, actual.c);
            try std.testing.expectEqual(@as(usize, 0), compact.text().len);
        }
    }
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 40), @sizeOf(parsed_stream.Scanned));
        try std.testing.expectEqual(@as(usize, 48), @sizeOf(parsed_stream.Item));
    }
}

test "compact parsed constants retain sixteen universes and use JSON above that" {
    const source =
        "{\"const\":{\"name\":1,\"us\":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,4294967295]},\"ie\":1}\n" ++
        "{\"const\":{\"name\":2,\"us\":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]},\"ie\":2}\n";
    var input: ChunkReader = .{ .bytes = source, .chunk = 1 };
    const stream = try parsed_stream.Stream(@TypeOf(input.reader())).create(std.testing.allocator, input.reader(), .{ .records_per_batch = 8, .arena_bytes = 16 * 1024 });
    defer stream.deinit();
    const batch = stream.next();
    defer stream.release(batch);
    try std.testing.expectEqual(@as(usize, 2), batch.length);
    const first = batch.get(0).scanned.record();
    try std.testing.expectEqual(@as(u8, 16), first.universe_count);
    for (first.universes[0..15], 0..) |value, index| try std.testing.expectEqual(@as(u32, @intCast(index)), value);
    try std.testing.expectEqual(std.math.maxInt(u32), first.universes[15]);
    try std.testing.expect(batch.get(1) == .json);
    const universes = batch.get(1).json.object.get("const").?.object.get("us").?.array.items;
    try std.testing.expectEqual(@as(usize, 17), universes.len);
    try std.testing.expectEqualStrings("16", universes[16].number_string);
}
