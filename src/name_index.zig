//! Append-only indices into immutable key vectors. Each slot stores a 32-bit
//! hash and an encoded key index, avoiding duplicate names or string slices.
//! One writer may append while snapshots read frozen prefixes of the vectors.
const std = @import("std");

pub fn Index(comptime Key: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const Slot = std.atomic.Value(u64);
        const Table = struct {
            references: std.atomic.Value(usize) = .init(1),
            slots: []Slot,
        };

        table: ?*Table = null,
        entries: usize = 0,
        read_only: bool = false,

        pub const Entry = struct {
            found_existing: bool,
            id: u32 = undefined,
            slot: ?*Slot = null,
            hash: u32 = 0,

            /// Store the key in its vector before publishing its index. A
            /// pending insertion must be published before another mutation.
            pub fn publish(self: Entry, id: u32) void {
                std.debug.assert(!self.found_existing);
                const encoded = std.math.add(u32, id, 1) catch @panic("name index overflow");
                self.slot.?.store((@as(u64, self.hash) << 32) | encoded, .release);
            }
        };

        pub fn capacity(self: Self) usize {
            return if (self.table) |table| table.slots.len else 0;
        }

        pub fn count(self: Self) usize {
            return self.entries;
        }

        pub fn storageId(self: Self) usize {
            return if (self.table) |table| @intFromPtr(table) else 0;
        }

        pub fn allocatedBytes(self: Self) usize {
            return if (self.table) |table| @sizeOf(Table) + table.slots.len * @sizeOf(Slot) else 0;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.table) |table| release(allocator, table);
            self.* = .{};
        }

        /// Retain the current table while the writer may append or replace its
        /// own table. Readers must pass their frozen key-vector prefix to get.
        /// Copying/sharing a writer's Self value is serialized with its writes.
        pub fn share(self: Self) Self {
            if (self.table) |table| _ = table.references.fetchAdd(1, .monotonic);
            var result = self;
            result.read_only = true;
            return result;
        }

        /// Independent, mutable copy for ordinary nonconcurrent snapshots.
        /// A shared source may contain later slots, so retain only visible IDs.
        pub fn clone(self: Self, allocator: std.mem.Allocator, visible_count: usize) !Self {
            const old = self.table orelse return .{};
            const table = try allocate(allocator, old.slots.len);
            var entries: usize = 0;
            for (old.slots) |*source| {
                const value = source.load(.acquire);
                if (value == 0 or @as(u32, @truncate(value)) - 1 >= visible_count) continue;
                insertStored(table, value);
                entries += 1;
            }
            return .{ .table = table, .entries = entries };
        }

        pub fn get(self: Self, key: Key, keys: []const Key) ?u32 {
            return self.getHashed(key, keys, Context.hash(key));
        }

        fn getHashed(self: Self, key: Key, keys: []const Key, hash: u32) ?u32 {
            const table = self.table orelse return null;
            const mask = table.slots.len - 1;
            var position = @as(usize, hash) & mask;
            while (true) : (position = (position + 1) & mask) {
                const value = table.slots[position].load(.acquire);
                if (value == 0) return null;
                if (@as(u32, @truncate(value >> 32)) != hash) continue;
                const id = @as(u32, @truncate(value)) - 1;
                // A concurrent insertion may refer to a later imported key.
                // Filter before dereferencing; other colliding keys can follow.
                if (id < keys.len and Context.eql(keys[id], key)) return id;
            }
        }

        /// Single-writer operation; snapshots call get only. Publishing a new
        /// entry changes no earlier slot, and growth never mutates old tables.
        pub fn getOrPut(self: *Self, allocator: std.mem.Allocator, key: Key, keys: []const Key) !Entry {
            std.debug.assert(!self.read_only);
            const hash = Context.hash(key);
            if (self.entries + 1 > self.capacity() / 5 * 4) {
                if (self.getHashed(key, keys, hash)) |id| return .{ .found_existing = true, .id = id };
                try self.grow(allocator);
            }
            const table = self.table.?;
            const mask = table.slots.len - 1;
            var position = @as(usize, hash) & mask;
            while (true) : (position = (position + 1) & mask) {
                const slot = &table.slots[position];
                const value = slot.load(.acquire);
                if (value == 0) {
                    self.entries += 1;
                    return .{ .found_existing = false, .slot = slot, .hash = hash };
                }
                if (@as(u32, @truncate(value >> 32)) != hash) continue;
                const id = @as(u32, @truncate(value)) - 1;
                if (id < keys.len and Context.eql(keys[id], key)) return .{ .found_existing = true, .id = id };
            }
        }

        fn allocate(allocator: std.mem.Allocator, length: usize) !*Table {
            const table = try allocator.create(Table);
            errdefer allocator.destroy(table);
            const slots = try allocator.alloc(Slot, length);
            @memset(slots, Slot.init(0));
            table.* = .{ .slots = slots };
            return table;
        }

        fn release(allocator: std.mem.Allocator, table: *Table) void {
            if (table.references.fetchSub(1, .acq_rel) == 1) {
                allocator.free(table.slots);
                allocator.destroy(table);
            }
        }

        fn grow(self: *Self, allocator: std.mem.Allocator) !void {
            const capacity_ = std.math.mul(usize, @max(8, self.capacity()), 2) catch return error.OutOfMemory;
            const table = try allocate(allocator, capacity_);
            if (self.table) |old| {
                for (old.slots) |*slot| {
                    const value = slot.load(.acquire);
                    if (value == 0) continue;
                    insertStored(table, value);
                }
                release(allocator, old);
            }
            self.table = table;
        }

        fn insertStored(table: *Table, value: u64) void {
            const mask = table.slots.len - 1;
            var position = @as(usize, @intCast(value >> 32)) & mask;
            while (table.slots[position].raw != 0) position = (position + 1) & mask;
            table.slots[position].raw = value;
        }
    };
}

const CollisionContext = struct {
    fn hash(_: u32) u32 {
        return 7;
    }
    fn eql(a: u32, b: u32) bool {
        return a == b;
    }
};

test "indexed maps distinguish equal hashes and preserve snapshots across resize" {
    const Map = Index(u32, CollisionContext);
    var map: Map = .{};
    defer map.deinit(std.testing.allocator);
    var keys: [256]u32 = undefined;
    for (&keys, 0..) |*key, index| key.* = @intCast(index * 3);
    for (0..8) |index| {
        const entry = try map.getOrPut(std.testing.allocator, keys[index], keys[0..index]);
        try std.testing.expect(!entry.found_existing);
        entry.publish(@intCast(index));
    }
    var snapshot = map.share();
    defer snapshot.deinit(std.testing.allocator);
    var independent = try map.clone(std.testing.allocator, 8);
    defer independent.deinit(std.testing.allocator);
    for (8..keys.len) |index| {
        const entry = try map.getOrPut(std.testing.allocator, keys[index], keys[0..index]);
        entry.publish(@intCast(index));
    }
    try std.testing.expect(map.capacity() > snapshot.capacity());
    for (0..8) |index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), snapshot.get(keys[index], keys[0..8]).?);
        try std.testing.expectEqual(@as(u32, @intCast(index)), independent.get(keys[index], keys[0..8]).?);
    }
    // The retained table did receive some later slots before resizing. They
    // must be skipped without indexing outside the snapshot's key prefix.
    try std.testing.expect(snapshot.get(keys[9], keys[0..8]) == null);
    try std.testing.expect(independent.get(keys[9], keys[0..8]) == null);
    var cloned_view = try snapshot.clone(std.testing.allocator, 8);
    defer cloned_view.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), cloned_view.count());
    const new_entry = try cloned_view.getOrPut(std.testing.allocator, 9999, keys[0..8]);
    try std.testing.expect(!new_entry.found_existing);
    var cloned_keys: [9]u32 = undefined;
    @memcpy(cloned_keys[0..8], keys[0..8]);
    cloned_keys[8] = 9999;
    new_entry.publish(8);
    try std.testing.expectEqual(@as(u32, 8), cloned_view.get(9999, &cloned_keys).?);
    try std.testing.expect(cloned_view.get(keys[9], &cloned_keys) == null);
    for (0..8) |index| try std.testing.expectEqual(@as(u32, @intCast(index)), cloned_view.get(keys[index], &cloned_keys).?);
    const existing = try map.getOrPut(std.testing.allocator, keys[3], &keys);
    try std.testing.expect(existing.found_existing);
    try std.testing.expectEqual(@as(u32, 3), existing.id);
    map.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), snapshot.get(keys[3], keys[0..8]).?);
}

test "snapshot readers coexist with indexed-map insertion and growth" {
    const Map = Index(u32, CollisionContext);
    const Reader = struct {
        map: Map,
        keys: []const u32,
        started: std.Thread.Semaphore = .{},
        failed: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.started.post();
            for (0..10000) |index| {
                const id: u32 = @intCast(index % self.keys.len);
                if (self.map.get(self.keys[id], self.keys) != id or self.map.get(9999, self.keys) != null) {
                    self.failed.store(true, .release);
                    return;
                }
            }
        }
    };
    var map: Map = .{};
    defer map.deinit(std.testing.allocator);
    var keys: [512]u32 = undefined;
    for (0..32) |index| {
        keys[index] = @intCast(index);
        const entry = try map.getOrPut(std.testing.allocator, keys[index], keys[0..index]);
        entry.publish(@intCast(index));
    }
    var reader: Reader = .{ .map = map.share(), .keys = keys[0..32] };
    defer reader.map.deinit(std.testing.allocator);
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var joined = false;
    defer if (!joined) thread.join();
    reader.started.wait();
    for (32..keys.len) |index| {
        keys[index] = @intCast(index);
        const entry = try map.getOrPut(std.testing.allocator, keys[index], keys[0..index]);
        entry.publish(@intCast(index));
        if (index % 32 == 0) std.Thread.yield() catch {};
    }
    thread.join();
    joined = true;
    try std.testing.expect(!reader.failed.load(.acquire));
}
