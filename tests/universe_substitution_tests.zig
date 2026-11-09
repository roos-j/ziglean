const std = @import("std");
const expr = @import("../src/expr.zig");
const level = @import("../src/level.zig");

fn sharedBody(expressions: *expr.Pool, universes: u32) expr.Expr {
    var body = expressions.app(expressions.cnst(100, universes), expressions.bvar(0));
    for (101..133) |name| body = expressions.app(body, expressions.cnst(@intCast(name), universes));
    return body;
}

test "universe substitution shares lists across binder depths without changing bound indices" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const parameter = levels.param(23);
    const unknown = levels.param(29);
    const universes = expressions.list(&.{ parameter, levels.succ(parameter), unknown });
    const body = sharedBody(&expressions, universes);
    const original = expressions.app(body, expressions.binder(.lam, expressions.sort(parameter), body));
    const expected_universes = expressions.list(&.{ 0, levels.succ(0), unknown });
    const expected_body = sharedBody(&expressions, expected_universes);
    const expected = expressions.app(expected_body, expressions.binder(.lam, expressions.sort(0), expected_body));
    try std.testing.expectEqual(expected, expressions.substLevels(original, &.{23}, &.{0}));
    try std.testing.expectEqual(@as(u32, 1), expressions.get(expected).range);
}

test "universe substitution resets list memoization between parameter mappings" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const parameter = levels.param(41);
    const unknown = levels.param(43);
    const global = sharedBody(&expressions, expressions.list(&.{ parameter, unknown }));
    expressions.temporary = true;
    const local = expressions.app(global, expressions.cnst(211, expressions.list(&.{levels.succ(parameter)})));
    try std.testing.expect(!expr.Pool.isPermanent(local));
    for ([_]u32{ 0, levels.succ(0), levels.succ(unknown), 0 }) |replacement| {
        const body = sharedBody(&expressions, expressions.list(&.{ replacement, unknown }));
        const expected = expressions.app(body, expressions.cnst(211, expressions.list(&.{levels.succ(replacement)})));
        try std.testing.expectEqual(expected, expressions.substLevels(local, &.{41}, &.{replacement}));
    }
    // Identity substitutions and parameters absent from the mapping preserve
    // the original IDs, even after a cache held different substituted lists.
    try std.testing.expectEqual(local, expressions.substLevels(local, &.{41}, &.{parameter}));
    try std.testing.expectEqual(local, expressions.substLevels(local, &.{47}, &.{0}));
}

test "universe list substitution retains long lists and full-width list handles" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    // Model an overlay following a very large immutable prefix. Every handle
    // used below belongs to this overlay; its unused prefix needs no storage.
    expressions.universe_lists.base_length = 0x80000000;
    const parameter = levels.param(53);
    const unknown = levels.param(59);
    var original_levels: [24]u32 = undefined;
    var expected_levels: [24]u32 = undefined;
    for (&original_levels, &expected_levels, 0..) |*original, *expected, index| {
        const offset: u32 = @intCast(index);
        original.* = levels.max(levels.offset(parameter, offset), unknown);
        expected.* = levels.max(levels.offset(0, offset), unknown);
    }
    const universes = expressions.list(&original_levels);
    try std.testing.expect(universes >= 0x80000000);
    const original = sharedBody(&expressions, universes);
    expressions.temporary = true;
    const expected = sharedBody(&expressions, expressions.list(&expected_levels));
    try std.testing.expectEqual(expected, expressions.substLevels(original, &.{53}, &.{0}));
}
