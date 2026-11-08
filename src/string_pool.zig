//! Interned, immutable byte strings with explicit pool lifetime.
const std = @import("std");
const common = @import("common.zig");

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    strings: std.ArrayListUnmanaged([]const u8) = .{},
    indices: std.StringHashMapUnmanaged(u32) = .{},

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *StringPool) void {
        self.strings.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn clear(self: *StringPool) void {
        self.indices.clearRetainingCapacity();
        self.strings.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn find(self: *const StringPool, bytes: []const u8) ?u32 {
        return self.indices.get(bytes);
    }

    pub fn intern(self: *StringPool, bytes: []const u8) u32 {
        if (self.find(bytes)) |index| return index;
        const owned = self.arena.allocator().dupe(u8, bytes) catch common.oom();
        const index: u32 = @intCast(self.strings.items.len);
        self.strings.append(self.allocator, owned) catch common.oom();
        self.indices.put(self.allocator, owned, index) catch common.oom();
        return index;
    }

    pub fn get(self: *const StringPool, index: u32) []const u8 {
        return self.strings.items[index];
    }
};
