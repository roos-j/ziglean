const std = @import("std");
const Environment = @import("../../src/environment.zig").Environment;

test "concurrent snapshots share stable names and strings with private worker additions" {
    var base = Environment.init(std.testing.allocator);
    defer base.deinit();
    const parent = base.named("Parent");
    const child = base.child(parent, "Child");
    const atom = base.names.items[child].atom;
    base.enableConcurrentSnapshots();
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    const names_pointer = snapshot.names.items.ptr;
    const strings_pointer = snapshot.strings.items.ptr;
    const name_count = snapshot.names.items.len;
    const string_count = snapshot.strings.items.len;
    try std.testing.expect(names_pointer == base.names.items.ptr);
    try std.testing.expect(strings_pointer == base.strings.items.ptr);
    for (0..10000) |index| {
        var buffer: [32]u8 = undefined;
        _ = base.child(parent, try std.fmt.bufPrint(&buffer, "Generated{d}", .{index}));
    }
    try std.testing.expect(names_pointer == base.names.items.ptr);
    try std.testing.expect(strings_pointer == base.strings.items.ptr);
    try std.testing.expectEqual(name_count, snapshot.names.items.len);
    try std.testing.expectEqual(string_count, snapshot.strings.items.len);
    try std.testing.expectEqual(parent, snapshot.names.items[child].pre);
    try std.testing.expectEqualStrings("Child", snapshot.getString(atom));
    var worker = snapshot.fork();
    defer worker.deinit();
    try std.testing.expectEqual(child, worker.child(parent, "Child"));
    const generated = worker.child(parent, "Generated9999");
    try std.testing.expect(generated & 0x80000000 != 0);
    try std.testing.expectEqual(generated, worker.child(parent, "Generated9999"));
    try std.testing.expect(generated != base.child(parent, "Generated9999"));
    const local_atom = worker.extra_names.items[generated & 0x7fffffff].atom;
    try std.testing.expectEqualStrings("Generated9999", worker.getString(local_atom));
    try std.testing.expectEqual(@as(usize, 0), snapshot.extra_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extra_strings.items.len);
}

test "ordinary snapshots own independent name and string vectors" {
    var base = Environment.init(std.testing.allocator);
    defer base.deinit();
    const original = base.named("Original");
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    try std.testing.expect(base.names.items.ptr != snapshot.names.items.ptr);
    try std.testing.expect(base.strings.items.ptr != snapshot.strings.items.ptr);
    const count = snapshot.names.items.len;
    _ = base.named("Subsequent");
    try std.testing.expectEqual(count, snapshot.names.items.len);
    try std.testing.expectEqual(original, snapshot.named("Original"));
}
