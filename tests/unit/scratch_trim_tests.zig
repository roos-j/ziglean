const std = @import("std");
const expr = @import("../../src/expr.zig");
const level = @import("../../src/level.zig");
const Environment = @import("../../src/environment.zig").Environment;
const Checker = @import("../../src/type_checker.zig").Checker;

const retained_nodes = 64 * 1024;

fn checkReset(comptime oversized: bool) !void {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var base = expr.Pool.init(std.testing.allocator, &levels);
    defer base.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const type_ = base.sort(levels.succ(0));
    try environment.add(.{ .name = environment.builtin("Nat"), .kind = .axiom, .ty = type_ });
    const natural = base.cnst(environment.builtin("Nat"), 0);
    const imported_count = base.global.nodes.items.len;
    var worker_levels = levels.view();
    defer worker_levels.deinit();
    var worker = base.fork(&worker_levels);
    defer worker.deinit();
    var checker = Checker.init(&worker, &environment);
    defer checker.deinit();
    checker.beginDeclaration();

    // Fill the real scratch interner with distinct, closed natural literals.
    // No list length, backing pointer, capacity, or hash state is fabricated.
    const first = worker.mk(.nat, 0, 0, 0);
    try std.testing.expectEqual(natural, try checker.infer(first, true));
    const count: u32 = retained_nodes + @as(u32, @intFromBool(oversized));
    for (1..count) |index| _ = worker.mk(.nat, @intCast(index), 0, 0);
    try std.testing.expectEqual(@as(usize, count), worker.local.nodes.items.len);
    if (oversized) {
        try std.testing.expect(worker.local.nodes.capacity > retained_nodes);
    } else {
        try std.testing.expectEqual(@as(usize, retained_nodes), worker.local.nodes.capacity);
    }
    try std.testing.expectEqual(first, worker.mk(.nat, 0, 0, 0));
    for ([_]u32{ 0, retained_nodes / 2, count - 1 }) |value| {
        const literal = worker.mk(.nat, value, 0, 0);
        try std.testing.expectEqual(@as(u32, 0x80000000) + value, literal);
        try std.testing.expectEqual(expr.Kind.nat, worker.get(literal).kind);
        try std.testing.expectEqual(value, worker.get(literal).a);
        try std.testing.expectEqual(natural, try checker.infer(literal, true));
    }
    const pointer = worker.local.nodes.items.ptr;
    const slot_count = worker.local.slots.len;
    const tag_count = worker.local.tags.len;
    worker.reset();
    try std.testing.expectEqual(@as(usize, 0), worker.local.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), worker.local.indexed_count);
    try std.testing.expectEqual(@as(usize, 0), worker.local.wide_ranges.count());
    if (oversized) {
        try std.testing.expectEqual(@as(usize, 0), worker.local.nodes.capacity);
        try std.testing.expectEqual(@as(usize, 0), worker.local.slots.len);
        try std.testing.expectEqual(@as(usize, 0), worker.local.tags.len);
        try std.testing.expectEqual(@as(usize, 0), worker.local.region.committed);
        try std.testing.expect(worker.local.region.pointer == null);
    } else {
        try std.testing.expectEqual(@as(usize, retained_nodes), worker.local.nodes.capacity);
        try std.testing.expectEqual(pointer, worker.local.nodes.items.ptr);
        try std.testing.expectEqual(slot_count, worker.local.slots.len);
        try std.testing.expectEqual(tag_count, worker.local.tags.len);
    }

    // The next declaration can reuse exactly the old literal handle for a
    // different expression. Its checked inference must not reuse the old Nat.
    checker.beginDeclaration();
    const universe = worker_levels.offset(0, 2);
    const replacement = worker.sort(universe);
    try std.testing.expectEqual(first, replacement);
    const replacement_type = try checker.infer(replacement, true);
    const inferred = worker.get(replacement_type);
    try std.testing.expectEqual(expr.Kind.sort, inferred.kind);
    try std.testing.expectEqual(worker_levels.succ(universe), inferred.a);
    try std.testing.expectEqual(replacement, worker.sort(universe));
    const new_literal = worker.mk(.nat, 0, 0, 0);
    try std.testing.expect(new_literal != replacement);
    try std.testing.expectEqual(new_literal, worker.mk(.nat, 0, 0, 0));
    try std.testing.expectEqual(natural, try checker.infer(new_literal, true));
    try std.testing.expectEqual(imported_count, base.global.nodes.items.len);
}

test "scratch reset retains the exact 64K capacity and clears canonical generations" {
    try checkReset(false);
}

test "scratch reset reclaims capacity above 64K and safely reuses local handles" {
    try checkReset(true);
}
