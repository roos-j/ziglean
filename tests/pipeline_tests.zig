const std = @import("std");
const Environment = @import("../src/environment.zig").Environment;

test "concurrent environment snapshots share stable declarations but freeze visibility" {
    var base = Environment.init(std.testing.allocator);
    defer base.deinit();
    const first = base.named("First");
    const future = base.named("Future");
    try base.add(.{ .name = first, .kind = .axiom, .ty = 42 });
    base.enableConcurrentSnapshots();
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    const original = snapshot.find(first).?;
    try std.testing.expect(original == base.find(first).?);
    try base.add(.{ .name = future, .kind = .axiom, .ty = 99 });
    for (0..2048) |index| {
        var buffer: [32]u8 = undefined;
        const spelling = try std.fmt.bufPrint(&buffer, "Decl{d}", .{index});
        try base.add(.{ .name = base.named(spelling), .kind = .axiom, .ty = @intCast(index) });
    }
    try std.testing.expect(original == base.find(first).?);
    try std.testing.expectEqual(@as(u32, 42), original.ty);
    try std.testing.expectEqual(@as(usize, 1), snapshot.decls.items.len);
    try std.testing.expect(snapshot.find(future) == null);
    var worker = snapshot.fork();
    defer worker.deinit();
    worker.beginView(0);
    try worker.add(.{ .name = first, .kind = .axiom, .ty = 7 });
    worker.update(.{ .name = first, .kind = .axiom, .ty = 8 });
    try std.testing.expectEqual(@as(u32, 8), worker.find(first).?.ty);
    try std.testing.expectEqual(@as(u32, 42), snapshot.find(first).?.ty);
}

test "ordinary environment snapshots retain independent declaration copies" {
    var base = Environment.init(std.testing.allocator);
    defer base.deinit();
    const first = base.named("First");
    try base.add(.{ .name = first, .kind = .axiom, .ty = 42 });
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    base.update(.{ .name = first, .kind = .axiom, .ty = 99 });
    try std.testing.expectEqual(@as(u32, 42), snapshot.find(first).?.ty);
    try std.testing.expectEqual(@as(u32, 99), base.find(first).?.ty);
}

test "shared declaration slots preserve absence and independent snapshot clones" {
    var base = Environment.init(std.testing.allocator);
    defer base.deinit();
    // This name lies inside the map prefix, but has no declaration yet.
    const future = base.named("Future");
    const first = base.named("First");
    try base.add(.{ .name = first, .kind = .axiom, .ty = 42 });
    base.enableConcurrentSnapshots();
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    try std.testing.expect(snapshot.decl_map.items.ptr == base.decl_map.items.ptr);
    try std.testing.expect(future < snapshot.decl_map.items.len);
    try std.testing.expect(snapshot.find(future) == null);
    try base.add(.{ .name = future, .kind = .axiom, .ty = 99 });
    try std.testing.expect(snapshot.find(future) == null);
    try std.testing.expectEqual(@as(u32, 42), snapshot.find(first).?.ty);

    var independent = snapshot.snapshot();
    defer independent.deinit();
    try std.testing.expect(independent.decl_map.items.ptr != snapshot.decl_map.items.ptr);
    try std.testing.expect(independent.find(future) == null);
    try independent.add(.{ .name = future, .kind = .axiom, .ty = 101 });
    try std.testing.expectEqual(@as(u32, 101), independent.find(future).?.ty);
    try std.testing.expectEqual(@as(u32, 99), base.find(future).?.ty);
    try std.testing.expect(snapshot.find(future) == null);

    var worker = snapshot.fork();
    defer worker.deinit();
    worker.beginView(0);
    try std.testing.expect(worker.find(first) == null);
    try worker.add(.{ .name = future, .kind = .axiom, .ty = 7 });
    worker.update(.{ .name = future, .kind = .axiom, .ty = 8 });
    try std.testing.expectEqual(@as(u32, 8), worker.find(future).?.ty);
    worker.beginView(std.math.maxInt(u32));
    try std.testing.expect(worker.find(future) == null);
    try std.testing.expectEqual(@as(u32, 42), worker.find(first).?.ty);
}

test "snapshot readers ignore concurrently published declaration slots and growth" {
    const Reader = struct {
        snapshot: *const Environment,
        first: u32,
        future: []const u32,
        started: std.Thread.Semaphore = .{},
        done: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),
        iterations: usize = 0,
        fn run(self: *@This()) void {
            // Acknowledge completed reading, so the writer cannot finish
            // before this test has actually exercised a snapshot lookup.
            // Early failure must also wake the writer instead of deadlocking.
            defer if (self.iterations == 0) self.started.post();
            while (!self.done.load(.acquire)) {
                const first = self.snapshot.find(self.first) orelse {
                    self.failed.store(true, .release);
                    return;
                };
                if (first.ty != 42 or self.snapshot.find(self.future[self.iterations % self.future.len]) != null) {
                    self.failed.store(true, .release);
                    return;
                }
                self.iterations += 1;
                if (self.iterations == 1) self.started.post();
            }
        }
    };
    var base = Environment.init(std.testing.allocator);
    defer base.deinit();
    var future: [64]u32 = undefined;
    for (&future, 0..) |*name, index| {
        var buffer: [32]u8 = undefined;
        name.* = base.named(try std.fmt.bufPrint(&buffer, "Future{d}", .{index}));
    }
    const first = base.named("First");
    try base.add(.{ .name = first, .kind = .axiom, .ty = 42 });
    base.enableConcurrentSnapshots();
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    var reader: Reader = .{ .snapshot = &snapshot, .first = first, .future = &future };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var joined = false;
    defer if (!joined) {
        reader.done.store(true, .release);
        thread.join();
    };
    reader.started.wait();
    for (future, 0..) |name, index| {
        try base.add(.{ .name = name, .kind = .axiom, .ty = @intCast(index) });
    }
    for (0..20000) |index| {
        var buffer: [32]u8 = undefined;
        const name = base.named(try std.fmt.bufPrint(&buffer, "New{d}", .{index}));
        try base.add(.{ .name = name, .kind = .axiom, .ty = @intCast(index) });
    }
    reader.done.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(reader.iterations > 0);
    try std.testing.expect(!reader.failed.load(.acquire));
    try std.testing.expect(snapshot.decl_map.items.ptr == base.decl_map.items.ptr);
    for (future) |name| try std.testing.expect(snapshot.find(name) == null);
}
