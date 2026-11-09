//! Interned universe-list tails. Workers share an immutable imported prefix
//! and own only the additional tails constructed while checking declarations.
const std = @import("std");
const c = @import("common.zig");

pub const Pool = struct {
    allocator: std.mem.Allocator,
    nodes: c.List([2]u32) = .{},
    map: std.AutoHashMapUnmanaged([2]u32, u32) = .{},
    parent: ?*const Pool = null,
    base_length: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Pool {
        var self: Pool = .{ .allocator = allocator };
        c.append([2]u32, &self.nodes, allocator, .{ 0, 0 });
        return self;
    }

    pub fn deinit(self: *Pool) void {
        self.nodes.deinit(self.allocator);
        self.map.deinit(self.allocator);
    }

    /// The parent must remain immutable and outlive this view.
    pub fn view(self: *const Pool) Pool {
        std.debug.assert(self.parent == null);
        return .{ .allocator = self.allocator, .parent = self, .base_length = @intCast(self.nodes.items.len) };
    }

    /// Freeze an independent root for jobs that overlap further importing.
    pub fn snapshot(self: *const Pool) Pool {
        std.debug.assert(self.parent == null);
        return .{
            .allocator = self.allocator,
            .nodes = .fromOwnedSlice(self.allocator.dupe([2]u32, self.nodes.items) catch c.oom()),
            .map = self.map.clone(self.allocator) catch c.oom(),
        };
    }

    pub inline fn get(self: *const Pool, id: u32) [2]u32 {
        if (id < self.base_length) return self.parent.?.nodes.items[id];
        return self.nodes.items[id - self.base_length];
    }

    pub fn cons(self: *Pool, first: u32, tail: u32) u32 {
        const key = [2]u32{ first, tail };
        if (self.parent) |base| {
            if (tail < self.base_length) {
                if (base.map.get(key)) |id| return id;
            }
        }
        const entry = self.map.getOrPut(self.allocator, key) catch c.oom();
        if (entry.found_existing) return entry.value_ptr.*;
        const id = std.math.add(u32, self.base_length, @intCast(self.nodes.items.len)) catch c.oom();
        entry.value_ptr.* = id;
        c.append([2]u32, &self.nodes, self.allocator, key);
        return id;
    }
};

test "universe-list views share canonical tails and isolate derived lists" {
    var base = Pool.init(std.testing.allocator);
    defer base.deinit();
    const tail = base.cons(3, 0);
    const prefix = base.cons(2, tail);
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    var first = snapshot.view();
    defer first.deinit();
    var second = snapshot.view();
    defer second.deinit();
    try std.testing.expectEqual(prefix, first.cons(2, tail));
    try std.testing.expectEqual(@as(usize, 0), first.nodes.items.len);
    const left = first.cons(7, prefix);
    const right = second.cons(9, prefix);
    try std.testing.expectEqual([2]u32{ 7, prefix }, first.get(left));
    try std.testing.expectEqual([2]u32{ 9, prefix }, second.get(right));
    try std.testing.expectEqual([2]u32{ 3, 0 }, first.get(tail));
    const extension = first.cons(11, left);
    try std.testing.expectEqual([2]u32{ 11, left }, first.get(extension));
    _ = base.cons(13, prefix);
    try std.testing.expectEqual(@as(usize, 3), snapshot.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 4), base.nodes.items.len);
}
