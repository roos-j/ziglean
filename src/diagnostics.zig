//! Bounded expression rendering for kernel diagnostics.
const std = @import("std");
const c = @import("common.zig");
const Expr = c.Expr;
const Checker = @import("type_checker.zig").Checker;

pub fn dump(self: *Checker, e: Expr, depth: u32) void {
    if (depth == 0) {
        std.debug.print("...", .{});
        return;
    }
    const n = self.expressions.get(e);
    switch (n.kind) {
        .cnst => self.environment.printName(n.a),
        .bvar => std.debug.print("#{d}", .{n.a}),
        .fvar => std.debug.print("x{d}", .{n.b}),
        .sort => std.debug.print("Sort[{d}]", .{n.a}),
        .nat => std.debug.print("nat({d})", .{@as(u64, n.a) | (@as(u64, n.b) << 32)}),
        .str => std.debug.print("str", .{}),
        .app, .pi, .lam => {
            std.debug.print("({s} ", .{@tagName(n.kind)});
            self.dump(n.a, depth - 1);
            std.debug.print(" ", .{});
            self.dump(n.b, depth - 1);
            std.debug.print(")", .{});
        },
        else => std.debug.print("{s}", .{@tagName(n.kind)}),
    }
}
