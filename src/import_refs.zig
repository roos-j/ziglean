//! Exact external-to-internal expression IDs, compressed in affine pages.
//! Exported composites usually append one node each, so almost every page
//! needs only an offset. Irregular pages and sparse IDs retain exact mappings.
const std = @import("std");
const c = @import("common.zig");

pub const Refs = struct {
    const page_bits = 10;
    const page_size = 1 << page_bits;
    // A regular page stores its full-width wrapping delta shifted left once.
    // An irregular page stores an aligned array pointer with bit zero set.
    // One word per page keeps the common reference lookup to a single load.
    const Page = struct {
        bits: u64,

        inline fn regular(delta_value: u32) Page {
            return .{ .bits = @as(u64, delta_value) << 1 };
        }

        inline fn explicit(values_: *[page_size]u32) Page {
            const address = @intFromPtr(values_);
            std.debug.assert(address & 1 == 0);
            return .{ .bits = @as(u64, address) | 1 };
        }

        inline fn delta(self: Page) u32 {
            return @truncate(self.bits >> 1);
        }

        inline fn values(self: Page) ?*[page_size]u32 {
            return if (self.bits & 1 != 0) @ptrFromInt(@as(usize, @intCast(self.bits & ~@as(u64, 1)))) else null;
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Page) == 8);
    }

    pages: c.List(Page) = .{},
    dense_length: usize = 0,
    sparse: std.AutoHashMapUnmanaged(u32, u32) = .{},

    pub fn deinit(self: *Refs, allocator: std.mem.Allocator) void {
        for (self.pages.items) |page| if (page.values()) |values| allocator.destroy(values);
        self.pages.deinit(allocator);
        self.sparse.deinit(allocator);
    }

    pub fn count(self: *const Refs) usize {
        return self.dense_length + self.sparse.count();
    }

    pub fn add(self: *Refs, allocator: std.mem.Allocator, id: u32, value: u32) c.Error!void {
        if (id < self.dense_length or self.sparse.contains(id)) return error.InvalidInput;
        if (id != self.dense_length) {
            self.sparse.put(allocator, id, value) catch c.oom();
            return;
        }
        const offset = id & (page_size - 1);
        if (offset == 0) {
            c.append(Page, &self.pages, allocator, Page.regular(value -% id));
        } else {
            const page = &self.pages.items[id >> page_bits];
            if (page.values()) |values| {
                values[offset] = value;
            } else if (value != id +% page.delta()) {
                const values = allocator.create([page_size]u32) catch c.oom();
                const first = id - offset;
                for (values[0..offset], 0..) |*entry, index| entry.* = (first + @as(u32, @intCast(index))) +% page.delta();
                values[offset] = value;
                page.* = Page.explicit(values);
            }
        }
        self.dense_length += 1;
    }

    pub fn get(self: *const Refs, id: u32) c.Error!u32 {
        if (id >= self.dense_length) return self.sparse.get(id) orelse error.InvalidInput;
        const page = self.pages.items[id >> page_bits];
        return if (page.values()) |values| values[id & (page_size - 1)] else id +% page.delta();
    }
};

test "affine reference pages preserve exceptions, boundaries, sparse IDs and wraparound" {
    var refs: Refs = .{};
    defer refs.deinit(std.testing.allocator);
    var expected: [5000]u32 = undefined;
    var random = std.Random.DefaultPrng.init(592);
    for (&expected, 0..) |*value, index| {
        const id: u32 = @intCast(index);
        value.* = if (id < 1030) id +% 0xfffffff0 else if (id < 3075) id - 3 else random.random().int(u32);
        try refs.add(std.testing.allocator, id, value.*);
        try std.testing.expectEqual(value.*, try refs.get(id));
    }
    for (expected, 0..) |value, index| try std.testing.expectEqual(value, try refs.get(@intCast(index)));
    try refs.add(std.testing.allocator, 4_000_000_000, 17);
    try std.testing.expectEqual(@as(u32, 17), try refs.get(4_000_000_000));
    try std.testing.expectError(error.InvalidInput, refs.get(5000));
    try std.testing.expectError(error.InvalidInput, refs.add(std.testing.allocator, 1024, 0));
    try std.testing.expectError(error.InvalidInput, refs.add(std.testing.allocator, 4_000_000_000, 0));
    try std.testing.expectEqual(@as(usize, 5001), refs.count());
}

test "tagged reference pages preserve high delta bits and late exceptions" {
    var refs: Refs = .{};
    defer refs.deinit(std.testing.allocator);
    for (0..2048) |index| {
        const id: u32 = @intCast(index);
        const value = if (id == 1023) std.math.maxInt(u32) else id +% (if (id < 1024) @as(u32, 0x80000000) else std.math.maxInt(u32));
        try refs.add(std.testing.allocator, id, value);
    }
    for (0..2048) |index| {
        const id: u32 = @intCast(index);
        const expected = if (id == 1023) std.math.maxInt(u32) else id +% (if (id < 1024) @as(u32, 0x80000000) else std.math.maxInt(u32));
        try std.testing.expectEqual(expected, try refs.get(id));
    }
    try refs.add(std.testing.allocator, std.math.maxInt(u32), std.math.maxInt(u32));
    try std.testing.expectEqual(std.math.maxInt(u32), try refs.get(std.math.maxInt(u32)));
    try std.testing.expectError(error.InvalidInput, refs.add(std.testing.allocator, std.math.maxInt(u32), 0));
    try std.testing.expectError(error.InvalidInput, refs.get(2048));
}
