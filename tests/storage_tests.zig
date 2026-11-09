const std = @import("std");
const expr = @import("../src/expr.zig");
const level = @import("../src/level.zig");

test "compact global nodes retain every payload and large loose-variable range" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const high_index = std.math.maxInt(u32) - 1;
    const variable = expressions.bvar(high_index);
    try std.testing.expectEqual(std.math.maxInt(u32), expressions.get(variable).range);
    const prop = expressions.sort(0);
    const domain = expressions.sort(levels.param(23));
    const application = expressions.app(variable, domain);
    const telescope = expressions.binder(.pi, prop, application);
    try std.testing.expectEqual(high_index, expressions.get(telescope).range);
    try std.testing.expectEqual(@as(u8, 1), expressions.get(telescope).flags);

    const projection = expressions.mk(.proj, 413, 7, application);
    const node = expressions.get(projection);
    try std.testing.expectEqual(expr.Kind.proj, node.kind);
    try std.testing.expectEqual(@as(u32, 413), node.a);
    try std.testing.expectEqual(@as(u32, 7), node.b);
    try std.testing.expectEqual(application, node.c);
    try std.testing.expectEqual(std.math.maxInt(u32), node.range);
    try std.testing.expectEqual(projection, expressions.mk(.proj, 413, 7, application));
    const literal = expressions.mk(.nat, 0x12345678, 0xfedcba98, 0);
    try std.testing.expectEqual(@as(u32, 0xfedcba98), expressions.get(literal).b);
    try std.testing.expectEqual(@as(u32, 0), expressions.get(literal).c);
    const large_literal = expressions.mk(.nat, 17, 0, 1);
    try std.testing.expectEqual(@as(u32, 1), expressions.get(large_literal).c);
    try std.testing.expectEqual(@as(u32, 0), expressions.get(large_literal).b);

    expressions.temporary = true;
    const local = expressions.fvar(domain);
    const local_projection = expressions.mk(.proj, 413, 7, local);
    try std.testing.expectEqual(local, expressions.get(local_projection).c);
    try std.testing.expect(expressions.hasFreeVariables(local_projection));
}

test "compact snapshots retain stable auxiliary payloads and independent range maps" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    expressions.global.virtual = true;
    expressions.importing = true;
    _ = expressions.sort(0);
    const variable = expressions.bvar(1 << 26);
    const projection = expressions.mk(.proj, 11, 13, variable);
    var snapshot_levels = levels.fork();
    defer snapshot_levels.deinit();
    var snapshot = expressions.snapshot(&snapshot_levels);
    defer snapshot.deinit();

    // Grow the parent's payload allocation and overflow hash table after taking
    // the snapshot. The snapshot must still address its original prefix.
    for (0..10000) |index| {
        const v = expressions.bvar(@as(u32, @intCast(index)) + (1 << 26));
        _ = expressions.mk(.proj, 11, @intCast(index), v);
    }
    try std.testing.expectEqual(@as(u32, 13), snapshot.get(projection).b);
    try std.testing.expectEqual(variable, snapshot.get(projection).c);
    try std.testing.expectEqual(@as(u32, (1 << 26) + 1), snapshot.get(projection).range);
}

test "ordinary compact node reads survive both backing arrays growing" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    expressions.importing = true;
    _ = expressions.sort(0);
    const domain = expressions.sort(levels.param(53));
    const projection = expressions.mk(.proj, 23, 29, domain);
    const before = expressions.get(projection);
    for (0..10000) |index| _ = expressions.mk(.proj, 23, @intCast(index), domain);
    try std.testing.expectEqual(expr.Kind.proj, before.kind);
    try std.testing.expectEqual(@as(u32, 23), before.a);
    try std.testing.expectEqual(@as(u32, 29), before.b);
    try std.testing.expectEqual(domain, before.c);
    try std.testing.expectEqual(@as(u8, 1), before.flags);
}

test "direct binary import preserves generic metadata and temporary-node isolation" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const domain = expressions.sort(levels.param(53));
    const ranges = [_]u32{ 0, 1, 17, 61, 62, 63, 64, 65, 254, 255, 256, 257, (1 << 24) - 1, 1 << 24, std.math.maxInt(u32) };
    for (ranges) |range| {
        expressions.importing = false;
        const value = if (range == 0) domain else expressions.bvar(range - 1);
        const left = expressions.app(value, domain);
        for ([_][2]expr.Expr{ .{ domain, value }, .{ left, value }, .{ left, domain } }) |operands| {
            inline for (.{ expr.Kind.app, expr.Kind.lam, expr.Kind.pi }) |kind| {
                expressions.importing = false;
                const generic = expressions.mk(kind, operands[0], operands[1], 0);
                const expected = expressions.get(generic);
                expressions.importing = true;
                const direct = if (kind == .app) expressions.app(operands[0], operands[1]) else expressions.binder(kind, operands[0], operands[1]);
                try std.testing.expectEqualDeep(expected, expressions.get(direct));
            }
        }
    }
    expressions.temporary = true;
    const local = expressions.fvar(domain);
    const application = expressions.app(domain, local);
    try std.testing.expect(!expr.Pool.isPermanent(application));
    try std.testing.expect(expressions.hasFreeVariables(application));
}

test "compact scratch overflow metadata and interning survive generation resets" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const domain = expressions.sort(levels.param(71));
    for (0..600) |generation| {
        expressions.temporary = true;
        const range: u32 = if (generation % 2 == 0) std.math.maxInt(u32) else @intCast(generation + 1);
        const variable = expressions.bvar(range - 1);
        const local = expressions.fvar(domain);
        const application = expressions.app(local, variable);
        const binding = expressions.binder(.lam, domain, application);
        try std.testing.expect(!expr.Pool.isPermanent(variable));
        try std.testing.expectEqual(range, expressions.get(application).range);
        try std.testing.expectEqual(range - 1, expressions.get(binding).range);
        try std.testing.expectEqual(@as(u8, 3), expressions.get(application).flags);
        try std.testing.expectEqual(application, expressions.app(local, variable));
        expressions.reset();
        try std.testing.expectEqual(@as(usize, 0), expressions.local.wide_ranges.count());
    }
}

test "compact global range overflow preserves the 63 sentinel independently of scratch" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const domain = expressions.sort(levels.param(83));
    const below = expressions.bvar(61);
    try std.testing.expectEqual(@as(usize, 0), expressions.global.wide_ranges.count());
    const above = expressions.bvar(62);
    try std.testing.expectEqual(@as(usize, 0), expressions.global.wide_ranges.count());
    try std.testing.expectEqual(@as(u32, 62), expressions.get(below).range);
    try std.testing.expectEqual(@as(u32, 63), expressions.get(above).range);

    expressions.importing = true;
    const binding = expressions.binder(.pi, domain, above);
    const application = expressions.app(domain, above);
    const projection = expressions.mk(.proj, 17, 19, application);
    try std.testing.expectEqual(@as(u32, 62), expressions.get(binding).range);
    try std.testing.expectEqual(@as(u32, 63), expressions.get(application).range);
    try std.testing.expectEqual(@as(u32, 63), expressions.get(projection).range);
    try std.testing.expectEqual(@as(u32, 19), expressions.get(projection).b);
    try std.testing.expectEqual(application, expressions.get(projection).c);
    try std.testing.expectEqual(@as(u8, 1), expressions.get(projection).flags);

    expressions.temporary = true;
    const local = expressions.fvar(domain);
    const scratch = expressions.app(local, above);
    try std.testing.expectEqual(@as(u32, 63), expressions.get(scratch).range);
    try std.testing.expectEqual(@as(u8, 3), expressions.get(scratch).flags);
    try std.testing.expectEqual(@as(usize, 0), expressions.local.wide_ranges.count());
}
