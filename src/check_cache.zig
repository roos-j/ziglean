//! Reusable per-declaration memo tables with inexpensive integer hashing.
const std = @import("std");

/// Scratch expression IDs are dense and recycled together. Direct indexing
/// removes hashing on this hot path; sparse imported IDs use the ordinary map.
pub fn ExprMap(comptime Value: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { value: Value = undefined, epoch: u32 = 0 };
        const limit = 16 * 1024;
        dense: []Entry = &.{},
        epoch: u32 = 1,
        sparse: Map(u32, Value) = .{},

        pub fn get(self: *const Self, key: u32) ?Value {
            const index = key ^ 0x80000000;
            if (index >= limit) return self.sparse.get(key);
            if (index >= self.dense.len or self.dense[index].epoch != self.epoch) return null;
            return self.dense[index].value;
        }
        pub fn put(self: *Self, allocator: std.mem.Allocator, key: u32, value: Value) !void {
            const index = key ^ 0x80000000;
            if (index >= limit) return self.sparse.put(allocator, key, value);
            if (index >= self.dense.len) {
                const length = std.math.ceilPowerOfTwo(usize, @max(64, @as(usize, index) + 1)) catch unreachable;
                const memory = try allocator.alloc(Entry, length);
                @memcpy(memory[0..self.dense.len], self.dense);
                @memset(memory[self.dense.len..], .{});
                allocator.free(self.dense);
                self.dense = memory;
            }
            self.dense[index] = .{ .value = value, .epoch = self.epoch };
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.sparse.clearRetainingCapacity();
            self.epoch +%= 1;
            if (self.epoch == 0) {
                @memset(self.dense, .{});
                self.epoch = 1;
            }
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.sparse.deinit(allocator);
            allocator.free(self.dense);
            self.* = .{};
        }
        pub fn trim(self: *Self, allocator: std.mem.Allocator) void {
            self.sparse.trim(allocator);
        }
    };
}

pub fn Map(comptime Key: type, comptime Value: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { key: Key = 0, value: Value = undefined, epoch: u32 = 0 };
        entries: []Entry = &.{},
        count: usize = 0,
        epoch: u32 = 1,

        inline fn bucket(key: Key, mask: usize) usize {
            var hash = @as(u64, key) *% 0x9e3779b185ebca87;
            hash ^= hash >> 32;
            return @as(usize, @truncate(hash)) & mask;
        }
        pub fn get(self: *const Self, key: Key) ?Value {
            if (self.entries.len == 0) return null;
            const mask = self.entries.len - 1;
            var slot = bucket(key, mask);
            while (self.entries[slot].epoch == self.epoch) : (slot = (slot + 1) & mask) {
                if (self.entries[slot].key == key) return self.entries[slot].value;
            }
            return null;
        }
        pub fn put(self: *Self, allocator: std.mem.Allocator, key: Key, value: Value) !void {
            if ((self.count + 1) * 10 >= self.entries.len * 7) try self.grow(allocator);
            self.insert(key, value);
        }
        fn insert(self: *Self, key: Key, value: Value) void {
            const mask = self.entries.len - 1;
            var slot = bucket(key, mask);
            while (self.entries[slot].epoch == self.epoch) : (slot = (slot + 1) & mask) {
                if (self.entries[slot].key == key) {
                    self.entries[slot].value = value;
                    return;
                }
            }
            self.entries[slot] = .{ .key = key, .value = value, .epoch = self.epoch };
            self.count += 1;
        }
        fn grow(self: *Self, allocator: std.mem.Allocator) !void {
            const old = self.entries;
            const memory = try allocator.alloc(Entry, @max(32, old.len * 2));
            @memset(memory, .{});
            self.entries = memory;
            self.count = 0;
            for (old) |entry| if (entry.epoch == self.epoch) self.insert(entry.key, entry.value);
            allocator.free(old);
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.count = 0;
            self.epoch +%= 1;
            if (self.epoch == 0) {
                @memset(self.entries, .{});
                self.epoch = 1;
            }
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.entries);
            self.* = .{};
        }
        pub fn trim(self: *Self, allocator: std.mem.Allocator) void {
            if (self.entries.len > 256 * 1024) self.deinit(allocator);
        }
    };
}
