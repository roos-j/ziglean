// Derived from microlean, c5bd1904460a8536cf856661e6dc63ce8fd4abb0.
const std = @import("std");
pub const Name = u32;
pub const Expr = u32;
pub const Level = u32;
pub fn oom() noreturn {
    @panic("out of memory");
}
pub fn List(comptime T: type) type {
    return std.ArrayListUnmanaged(T);
}
pub const Error = error{ InvalidInput, UnknownConstant, DuplicateDeclaration, LooseVariable, UndeclaredUniverse, TypeMismatch, ExpectedSort, ExpectedPi, InvalidInductive, InvalidRecursor, InvalidProjection, Unsupported, ResourceLimit, UnsafeDeclaration, SpeculationLimit };
pub fn append(comptime T: type, list: anytype, a: std.mem.Allocator, x: T) void {
    list.append(a, x) catch oom();
}

/// Stack-backed scratch vector. Do not copy it after its first append.
pub fn SmallList(comptime T: type, comptime inline_capacity: usize) type {
    return struct {
        const Self = @This();
        items: []T = &.{},
        storage: [inline_capacity]T = undefined,
        capacity: usize = 0,

        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            if (self.capacity == 0) {
                self.items = self.storage[0..0];
                self.capacity = inline_capacity;
            }
            if (self.items.len == self.capacity) {
                const memory = try allocator.alloc(T, self.capacity * 2);
                @memcpy(memory[0..self.items.len], self.items);
                if (self.items.ptr != &self.storage) allocator.free(self.items.ptr[0..self.capacity]);
                self.items = memory[0..self.items.len];
                self.capacity = memory.len;
            }
            const length = self.items.len;
            self.items.len += 1;
            self.items[length] = value;
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.capacity != 0 and self.items.ptr != &self.storage) allocator.free(self.items.ptr[0..self.capacity]);
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.len = 0;
        }
    };
}
