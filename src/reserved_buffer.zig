//! Stable virtual addresses with physical memory committed only as needed.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Buffer = struct {
    const reservation = @as(usize, 1) << 36;
    granularity: usize = 4 * 1024 * 1024,
    pointer: ?[*]align(std.heap.page_size_min) u8 = null,
    committed: usize = 0,

    pub fn ensure(self: *Buffer, bytes: usize) !void {
        if (bytes <= self.committed) return;
        if (bytes > reservation) return error.OutOfMemory;
        if (self.pointer == null) {
            if (builtin.os.tag == .windows) {
                self.pointer = @ptrCast(@alignCast(try windows.VirtualAlloc(null, reservation, windows.MEM_RESERVE, windows.PAGE_NOACCESS)));
            } else {
                const memory = try std.posix.mmap(null, reservation, std.posix.PROT.NONE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
                self.pointer = memory.ptr;
            }
        }
        const capacity = std.mem.alignForward(usize, bytes, self.granularity);
        const tail = self.pointer.? + self.committed;
        if (builtin.os.tag == .windows) {
            _ = try windows.VirtualAlloc(@ptrCast(tail), capacity - self.committed, windows.MEM_COMMIT, windows.PAGE_READWRITE);
        } else {
            try std.posix.mprotect(@alignCast(tail[0 .. capacity - self.committed]), std.posix.PROT.READ | std.posix.PROT.WRITE);
        }
        self.committed = capacity;
    }
    pub fn deinit(self: *Buffer) void {
        if (self.pointer) |pointer| {
            if (builtin.os.tag == .windows) windows.VirtualFree(pointer, 0, windows.MEM_RELEASE) else std.posix.munmap(pointer[0..reservation]);
        }
        self.* = .{};
    }
};
