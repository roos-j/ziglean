const std = @import("std");
const check_cache = @import("../../src/check_cache.zig");
const expr = @import("../../src/expr.zig");
const level = @import("../../src/level.zig");

const map_limit = 64 * 1024;
const transform_limit = 64 * 1024;

// Exercise the retention boundary without constructing a huge proof or
// spending test time filling every slot. Subsequent puts use the real map.
fn allocateEntries(cache: anytype, length: usize) !void {
    std.debug.assert(cache.entries.len == 0);
    const Entry = @typeInfo(@TypeOf(cache.entries)).pointer.child;
    cache.entries = try std.testing.allocator.alloc(Entry, length);
    @memset(cache.entries, .{});
}

fn valueFor(comptime Value: type, index: usize) Value {
    return if (Value == bool) index % 2 != 0 else @intCast(index + 11);
}

fn checkMap(comptime Key: type, comptime Value: type) !void {
    var cache: check_cache.Map(Key, Value) = .{};
    defer cache.deinit(std.testing.allocator);
    const keys = [_]Key{ 0, 1, std.math.maxInt(Key) - 1, std.math.maxInt(Key) };
    try allocateEntries(&cache, map_limit);
    const retained = cache.entries.ptr;
    for (keys, 0..) |key, index| try cache.put(std.testing.allocator, key, valueFor(Value, index));
    cache.trim(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, map_limit), cache.entries.len);
    try std.testing.expectEqual(retained, cache.entries.ptr);
    for (keys, 0..) |key, index| try std.testing.expectEqual(valueFor(Value, index), cache.get(key).?);
    cache.clearRetainingCapacity();
    cache.trim(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, map_limit), cache.entries.len);
    for (keys) |key| try std.testing.expect(cache.get(key) == null);
    for (keys, 0..) |key, index| try cache.put(std.testing.allocator, key, valueFor(Value, index + 1));
    for (keys, 0..) |key, index| try std.testing.expectEqual(valueFor(Value, index + 1), cache.get(key).?);

    cache.deinit(std.testing.allocator);
    try allocateEntries(&cache, map_limit * 2);
    for (keys, 0..) |key, index| try cache.put(std.testing.allocator, key, valueFor(Value, index));
    for (keys, 0..) |key, index| try std.testing.expectEqual(valueFor(Value, index), cache.get(key).?);
    // Teardown may reclaim an oversized table before the next epoch reset.
    cache.trim(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.len);
    try std.testing.expectEqual(@as(usize, 0), cache.count);
    for (keys) |key| try std.testing.expect(cache.get(key) == null);
    for (0..129) |index| {
        const key = std.math.maxInt(Key) - @as(Key, @intCast(index));
        try cache.put(std.testing.allocator, key, valueFor(Value, index));
    }
    try std.testing.expect(cache.entries.len >= 256);
    for (0..129) |index| {
        const key = std.math.maxInt(Key) - @as(Key, @intCast(index));
        try std.testing.expectEqual(valueFor(Value, index), cache.get(key).?);
    }
}

test "judgment maps retain the exact slot boundary and reallocate after trimming oversized tables" {
    try checkMap(u32, u32);
    try checkMap(u64, u32);
    try checkMap(u64, bool);
}

test "trimming sparse expression caches preserves the 32K dense window" {
    var cache: check_cache.ExprMap(u32) = .{};
    defer cache.deinit(std.testing.allocator);
    const last_dense: u32 = 0x80000000 + 32 * 1024 - 1;
    try cache.put(std.testing.allocator, last_dense, 7);
    const dense_pointer = cache.dense.ptr;
    try std.testing.expectEqual(@as(usize, 32 * 1024), cache.dense.len);
    try allocateEntries(&cache.sparse, map_limit * 2);
    try cache.put(std.testing.allocator, last_dense + 1, 11);
    try cache.put(std.testing.allocator, 0xffffffff, 13);
    try cache.put(std.testing.allocator, 0, 17);
    cache.clearRetainingCapacity();
    cache.trim(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cache.sparse.entries.len);
    try std.testing.expectEqual(@as(usize, 32 * 1024), cache.dense.len);
    try std.testing.expectEqual(dense_pointer, cache.dense.ptr);
    for ([_]u32{ last_dense, last_dense + 1, 0xffffffff, 0 }) |key| try std.testing.expect(cache.get(key) == null);
    for ([_]u32{ last_dense, last_dense + 1, 0xffffffff, 0 }, 0..) |key, index| {
        const value: u32 = @intCast(index + 23);
        try cache.put(std.testing.allocator, key, value);
        try std.testing.expectEqual(value, cache.get(key).?);
    }
    try std.testing.expectEqual(dense_pointer, cache.dense.ptr);
}

test "expression resets trim each oversized transform cache and preserve boundary allocations" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    for (&expressions.transform_caches, 0..) |*cache, index| {
        const key = std.math.maxInt(u64) - @as(u64, @intCast(index));
        try allocateEntries(cache, transform_limit);
        const retained = cache.entries.ptr;
        cache.put(std.testing.allocator, key, 31);
        cache.reset();
        expressions.reset();
        try std.testing.expectEqual(@as(usize, transform_limit), cache.entries.len);
        try std.testing.expectEqual(retained, cache.entries.ptr);
        try std.testing.expect(cache.get(key) == null);
        cache.put(std.testing.allocator, key, 37);
        try std.testing.expectEqual(@as(?u32, 37), cache.get(key));

        cache.deinit(std.testing.allocator);
        try allocateEntries(cache, transform_limit * 2);
        cache.put(std.testing.allocator, key, 41);
        expressions.reset();
        try std.testing.expectEqual(@as(usize, 0), cache.entries.len);
        try std.testing.expectEqual(@as(usize, 0), cache.count);
        try std.testing.expect(cache.get(key) == null);
        for (0..129) |offset| cache.put(std.testing.allocator, key - @as(u64, @intCast(offset)), @intCast(offset + 43));
        try std.testing.expect(cache.entries.len >= 256);
        for (0..129) |offset| {
            try std.testing.expectEqual(@as(?u32, @intCast(offset + 43)), cache.get(key - @as(u64, @intCast(offset))));
        }
        cache.deinit(std.testing.allocator);
    }
}
