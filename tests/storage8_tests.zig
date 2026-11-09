const std = @import("std");
const expr = @import("../src/expr.zig");
const level = @import("../src/level.zig");

test "packed binary import reads flags and ranges from escaped children" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const domain = expressions.sort(levels.param(83));
    for ([_]u32{ 0, 1, 62, 63, 64, 255, std.math.maxInt(u32) }) |range| {
        expressions.importing = false;
        const variable = if (range == 0) domain else expressions.bvar(range - 1);
        const application = expressions.app(domain, variable);
        const escaped = expressions.mk(.proj, std.math.maxInt(u32), std.math.maxInt(u32), application);
        for ([_][2]expr.Expr{ .{ domain, escaped }, .{ escaped, domain }, .{ escaped, escaped } }) |operands| {
            inline for (.{ expr.Kind.app, expr.Kind.lam, expr.Kind.pi }) |kind| {
                expressions.importing = false;
                const expected = expressions.get(expressions.mk(kind, operands[0], operands[1], 0));
                expressions.importing = true;
                const actual = if (kind == .app) expressions.app(operands[0], operands[1]) else expressions.binder(kind, operands[0], operands[1]);
                try std.testing.expectEqualDeep(expected, expressions.get(actual));
            }
        }
    }
}

test "packed binder ranges cross the wide sentinel and become exactly closed" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    expressions.importing = true;
    const domain = expressions.sort(0);
    var body = expressions.bvar(130);
    for (0..131) |index| {
        body = expressions.binder(.lam, domain, body);
        try std.testing.expectEqual(@as(u32, @intCast(130 - index)), expressions.get(body).range);
    }
    try std.testing.expectEqual(body, expressions.instantiate(body, &.{domain}));
}
