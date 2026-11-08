//! Per-traversal memoization with reusable storage. Generation tags make a
//! reset constant time, including after a traversal with a large working set.
const std = @import("std");
const c = @import("common.zig");

const Entry = struct { key: u64 = 0, value: u32 = 0, epoch: u32 = 0 };
comptime {
    std.debug.assert(@sizeOf(Entry) == 16);
}
pub const Cache = struct {
    entries: []Entry = &.{},
    count: usize = 0,
    epoch: u32 = 1,

    fn bucket(key: u64, capacity: usize) usize {
        var hash = key *% 0x9e3779b185ebca87;
        hash ^= hash >> 32;
        return @intCast(hash & (capacity - 1));
    }
    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = .{};
    }
    pub fn reset(self: *Cache) void {
        self.count = 0;
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(self.entries, .{});
            self.epoch = 1;
        }
    }
    pub fn get(self: *const Cache, key: u64) ?u32 {
        if (self.entries.len == 0) return null;
        var index = bucket(key, self.entries.len);
        while (self.entries[index].epoch == self.epoch) {
            if (self.entries[index].key == key) return self.entries[index].value;
            index = (index + 1) & (self.entries.len - 1);
        }
        return null;
    }
    fn insert(self: *Cache, key: u64, value: u32) void {
        var index = bucket(key, self.entries.len);
        while (self.entries[index].epoch == self.epoch) {
            if (self.entries[index].key == key) {
                self.entries[index].value = value;
                return;
            }
            index = (index + 1) & (self.entries.len - 1);
        }
        self.entries[index] = .{ .key = key, .value = value, .epoch = self.epoch };
        self.count += 1;
    }
    pub fn put(self: *Cache, allocator: std.mem.Allocator, key: u64, value: u32) void {
        if ((self.count + 1) * 10 >= self.entries.len * 7) {
            const old = self.entries;
            self.entries = allocator.alloc(Entry, @max(32, old.len * 2)) catch c.oom();
            @memset(self.entries, .{});
            self.count = 0;
            for (old) |entry| if (entry.epoch == self.epoch) self.insert(entry.key, entry.value);
            allocator.free(old);
        }
        self.insert(key, value);
    }
};
