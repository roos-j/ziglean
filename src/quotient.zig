const std = @import("std");
const environment = @import("environment.zig");
const Checker = @import("type_checker.zig").Checker;
const c = @import("common.zig");
pub fn check(self: *Checker, d: environment.Decl) c.Error!void {
    const m = self.expressions;
    const env = self.environment;
    const expected_name = env.named(switch (d.details.quot_kind) {
        .type => "Quot",
        .mk => "Quot.mk",
        .lift => "Quot.lift",
        .ind => "Quot.ind",
    });
    if (d.name != expected_name or d.params.len != (if (d.details.quot_kind == .lift) @as(usize, 2) else 1)) return error.TypeMismatch;
    for (d.params, 0..) |p, i| {
        if (std.mem.indexOfScalar(u32, d.params[0..i], p) != null) return error.UndeclaredUniverse;
    }
    self.params = d.params;
    const u = m.levels.param(d.params[0]);
    const su = m.sort(u);
    const prop = m.sort(0);
    const alpha = m.fvar(su);
    const a = m.fvar(alpha);
    const b = m.fvar(alpha);
    const rel = m.fvar(m.bind(.pi, &.{ a, b }, prop));
    const qr = m.apps(m.cnst(env.named("Quot"), m.list(&.{u})), &.{ alpha, rel });
    const eq = env.find(env.named("Eq")) orelse return error.TypeMismatch;
    if (eq.kind != .inductive or eq.params.len != 1 or eq.details.ctors.len != 1) return error.TypeMismatch;
    const eqt = m.substLevels(eq.ty, eq.params, &.{u});
    if (!try self.defeq(eqt, m.bind(.pi, &.{ alpha, a, b }, prop))) return error.TypeMismatch;
    const refl = env.find(eq.details.ctors[0]) orelse return error.TypeMismatch;
    if (refl.params.len != 1) return error.TypeMismatch;
    const reflt = m.substLevels(refl.ty, refl.params, &.{u});
    if (!try self.defeq(reflt, m.bind(.pi, &.{ alpha, a }, m.apps(m.cnst(eq.name, m.list(&.{u})), &.{ alpha, a, a })))) return error.TypeMismatch;
    const ty: u32 = switch (d.details.quot_kind) {
        .type => m.bind(.pi, &.{ alpha, rel }, su),
        .mk => m.bind(.pi, &.{ alpha, rel, a }, qr),
        .lift => blk: {
            const v = m.levels.param(d.params[1]);
            const beta = m.fvar(m.sort(v));
            const f = m.fvar(m.bind(.pi, &.{a}, beta));
            const h = m.fvar(m.apps(rel, &.{ a, b }));
            const eqfb = m.apps(m.cnst(eq.name, m.list(&.{v})), &.{ beta, m.app(f, a), m.app(f, b) });
            const sanity = m.fvar(m.bind(.pi, &.{ a, b, h }, eqfb));
            const q = m.fvar(qr);
            break :blk m.bind(.pi, &.{ alpha, rel, beta, f, sanity, q }, beta);
        },
        .ind => blk: {
            const q = m.fvar(qr);
            const beta = m.fvar(m.bind(.pi, &.{q}, prop));
            const qa = m.apps(m.cnst(env.named("Quot.mk"), m.list(&.{u})), &.{ alpha, rel, a });
            const minor = m.fvar(m.bind(.pi, &.{a}, m.app(beta, qa)));
            break :blk m.bind(.pi, &.{ alpha, rel, beta, minor, q }, m.app(beta, q));
        },
    };
    _ = try self.ensure(try self.infer(d.ty, true), .sort);
    if (!try self.defeq(d.ty, ty)) return error.TypeMismatch;
    try env.add(d);
}
