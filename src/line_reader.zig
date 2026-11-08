//! Buffered newline scanning: common records borrow the input buffer directly.
const std = @import("std");

pub fn LineReader(comptime Reader: type, comptime buffer_size: usize) type {
    return struct {
        const Self = @This();
        reader: Reader,
        buffer: [buffer_size]u8 = undefined,
        start: usize = 0,
        end: usize = 0,
        spill: std.ArrayList(u8),
        limit: usize,

        pub fn init(reader: Reader, allocator: std.mem.Allocator, limit: usize) Self {
            return .{ .reader = reader, .spill = std.ArrayList(u8).init(allocator), .limit = limit };
        }
        pub fn deinit(self: *Self) void {
            self.spill.deinit();
        }
        /// The returned slice is valid until the next call.
        pub fn next(self: *Self) !?[]const u8 {
            self.spill.clearRetainingCapacity();
            while (true) {
                const remaining = self.buffer[self.start..self.end];
                if (std.mem.indexOfScalar(u8, remaining, '\n')) |offset| {
                    if (offset > self.limit - self.spill.items.len) return error.StreamTooLong;
                    self.start += offset + 1;
                    if (self.spill.items.len == 0) return remaining[0..offset];
                    try self.spill.appendSlice(remaining[0..offset]);
                    return self.spill.items;
                }
                if (remaining.len > self.limit - self.spill.items.len) return error.StreamTooLong;
                try self.spill.appendSlice(remaining);
                self.end = try self.reader.read(&self.buffer);
                self.start = 0;
                if (self.end == 0) return if (self.spill.items.len == 0) null else self.spill.items;
            }
        }
    };
}
