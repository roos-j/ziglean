//! Weak-head evaluation: beta, zeta, delta, projection, iota, and quotient reduction.
const std = @import("std");
const c = @import("common.zig");
const Expr = c.Expr;
const Error = c.Error;
const Checker = @import("type_checker.zig").Checker;

pub fn unfold(self: *Checker, e: Expr) Error!?Expr {
    const m = self.expressions;
    var args: c.SmallList(Expr, 16) = .{};
    defer args.deinit(m.allocator);
    const f = m.unfoldApps(e, &args);
    const n = m.get(f);
    if (n.kind == .fvar and n.c != 0) return m.apps(n.c - 1, args.items);
    if (n.kind != .cnst) return null;
    const d = self.environment.find(n.a) orelse return null;
    if (d.kind != .definition) return null;
    if (d.params.len != m.listLen(n.b)) return error.TypeMismatch;
    if (d.projection_function) {
        var body = d.value.?;
        var arity: usize = 0;
        while (m.kind(body) == .lam) {
            body = m.get(body).b;
            arity += 1;
        }
        const projection = m.get(body);
        const base = m.get(projection.c);
        if (base.kind == .bvar and base.a < arity and args.items.len >= arity) {
            // A projection wrapper's universes and binder types do not occur
            // in its result. Select the argument directly instead of building
            // and substituting a specialized copy of the whole lambda body.
            const value = m.mk(.proj, projection.a, projection.b, args.items[arity - 1 - base.a]);
            return m.apps(value, args.items[arity..]);
        }
    }
    if (d.params.len == 0) return m.apps(d.value.?, args.items);
    const value = self.unfold_cache.get(f) orelse blk: {
        const key = (@as(u64, n.a) << 32) | n.b;
        if (m.definition_values.get(key)) |result| {
            self.unfold_cache.put(m.allocator, f, result) catch c.oom();
            break :blk result;
        }
        var us: c.SmallList(u32, 8) = .{};
        defer us.deinit(m.allocator);
        m.listArray(n.b, &us);
        const previous_promote = m.promote;
        defer m.promote = previous_promote;
        m.promote = @import("expr.zig").Pool.isPermanent(d.value.?);
        const result = m.substLevels(d.value.?, d.params, us.items);
        if (@import("expr.zig").Pool.isPermanent(result) and m.definition_values.count < 262144) m.definition_values.put(m.allocator, key, result) catch c.oom();
        self.unfold_cache.put(m.allocator, f, result) catch c.oom();
        break :blk result;
    };
    return m.apps(value, args.items);
}

pub fn reduce(self: *Checker, e: Expr, comptime delta: bool) Error!Expr {
    return reduceWithProjection(self, e, delta, !delta);
}

/// Force projection bases while preserving symbolic head definitions for
/// conversion's next congruence attempt.
pub fn reduceProjections(self: *Checker, e: Expr) Error!Expr {
    return reduceWithProjection(self, e, false, false);
}

fn reduceWithProjection(self: *Checker, e: Expr, comptime delta: bool, comptime cheap_projection: bool) Error!Expr {
    try self.tick();
    self.depth += 1;
    defer self.depth -= 1;
    const m = self.expressions;
    const k = m.kind(e);
    if (k == .sort or k == .pi or k == .lam or k == .nat or k == .str) return e;
    if (!delta and k == .cnst) return e;
    if (k == .fvar and (!delta or m.get(e).c == 0)) return e;
    const ci: usize = @as(usize, if (delta) 1 else if (cheap_projection) 0 else 2) + (if (self.eager_reduce) @as(usize, 3) else 0);
    if (self.whnf_cache[ci].get(e)) |v| return v;
    var r = e;
    while (true) {
        try self.tick();
        const n = m.get(r);
        if (n.kind == .letE) {
            r = m.inst(n.c, n.b);
            continue;
        }
        if (n.kind == .proj) {
            // During conversion, compare projection bases before unfolding
            // large structure instances. Full reduction remains eager here.
            var s = if (cheap_projection) try self.reduce(n.c, false) else try self.whnf(n.c);
            if (m.kind(s) == .str) s = try self.whnf(try @import("primitive.zig").expand(self, s));
            var aa: c.SmallList(Expr, 16) = .{};
            defer aa.deinit(m.allocator);
            const h = m.get(m.unfoldApps(s, &aa));
            if (h.kind == .cnst) {
                if (self.environment.find(h.a)) |d| {
                    if (d.kind == .ctor and d.details.parent == n.a and aa.items.len == d.details.num_params + d.details.num_fields and n.b < d.details.num_fields) {
                        r = aa.items[d.details.num_params + n.b];
                        continue;
                    }
                }
            }
            r = m.mk(.proj, n.a, n.b, s);
            break;
        }
        if (n.kind == .app) {
            var args: c.SmallList(Expr, 16) = .{};
            defer args.deinit(m.allocator);
            const head = m.unfoldApps(r, &args);
            // Recognize kernel primitives before delta-unfolding their
            // ordinary Lean definitions (which can be exponentially slower).
            // Core conversion must not force open arithmetic arguments: e.g.
            // normalizing `x + 2^31` would expand billions of successors before
            // congruence can compare the same symbolic expression on both sides.
            if (delta or self.eager_reduce or !m.hasFreeVariables(r)) {
                if (try @import("primitive.zig").reduce(self, head, args.items)) |value| {
                    r = value;
                    continue;
                }
            }
            // Delta reduction belongs to the entire application, preserving
            // its argument spine through aliases and typeclass projections.
            var f = try reduceWithProjection(self, head, false, cheap_projection);
            var used: usize = 0;
            while (used < args.items.len and m.kind(f) == .lam) {
                f = m.get(f).b;
                used += 1;
            }
            if (used != 0) {
                // Substitute a whole lambda telescope in one traversal.
                // De Bruijn substitution consumes the innermost binder first.
                f = m.instantiateReverse(f, args.items[0..used]);
            }
            if (used != 0 or f != head) {
                r = m.apps(f, args.items[used..]);
                continue;
            }
            if (try reduceRecursor(self, f, args.items)) |v| {
                r = v;
                continue;
            }
        }
        if (delta) {
            if (try self.unfold(r)) |v| {
                r = v;
                continue;
            }
        }
        break;
    }
    self.whnf_cache[ci].put(m.allocator, e, r) catch c.oom();
    return r;
}

fn reduceRecursor(self: *Checker, f: Expr, args: []const Expr) Error!?Expr {
    const m = self.expressions;
    const n = m.get(f);
    if (n.kind != .cnst) return null;
    const d = self.environment.find(n.a) orelse return null;
    if (d.kind == .quotient) {
        const major: usize = switch (d.details.quot_kind) {
            .lift => 5,
            .ind => 4,
            else => return null,
        };
        if (args.len <= major) return null;
        const v = try self.whnf(args[major]);
        var aa: c.SmallList(Expr, 16) = .{};
        defer aa.deinit(m.allocator);
        const h = m.get(m.unfoldApps(v, &aa));
        if (h.kind == .cnst and h.a == self.environment.builtin("Quot.mk") and aa.items.len == 3) {
            // An ordinary axiom can have this name without being the quotient
            // constructor. Its arguments must not acquire primitive reduction.
            const constructor = self.environment.find(h.a) orelse return null;
            if (constructor.kind != .quotient or constructor.details.quot_kind != .mk) return null;
            return m.apps(m.app(args[3], aa.items[2]), args[major + 1 ..]);
        }
        return null;
    }
    if (d.kind != .recursor) return null;
    const major: usize = d.details.num_params + d.details.num_motives + d.details.num_minors + d.details.num_indices;
    if (args.len <= major) return null;
    var v = try self.whnf(args[major]);
    if (d.details.k and d.details.rules.len == 1) {
        const ty = try self.whnf(try self.infer(v, false));
        var aa: c.SmallList(Expr, 16) = .{};
        defer aa.deinit(m.allocator);
        const h = m.get(m.unfoldApps(ty, &aa));
        if (h.kind == .cnst and aa.items.len >= d.details.num_params) {
            const ctor = m.apps(m.cnst(d.details.rules[0].ctor, h.b), aa.items[0..d.details.num_params]);
            if (try self.defeq(try self.infer(ctor, false), ty)) v = ctor;
        }
    }
    const was_string = m.kind(v) == .str;
    v = try @import("primitive.zig").expand(self, v);
    if (was_string) v = try self.whnf(v);
    var aa: c.SmallList(Expr, 16) = .{};
    defer aa.deinit(m.allocator);
    var h = m.get(m.unfoldApps(v, &aa));
    if (h.kind != .cnst or (if (self.environment.find(h.a)) |ci| ci.kind != .ctor else true)) {
        const ty = try self.whnf(try self.infer(v, false));
        if (try self.etaExpand(v, ty)) |expanded| {
            aa.clearRetainingCapacity();
            h = m.get(m.unfoldApps(expanded, &aa));
        }
    }
    if (h.kind != .cnst) return null;
    for (d.details.rules) |rule| {
        if (rule.ctor == h.a) {
            const constructor = self.environment.find(rule.ctor) orelse return error.InvalidRecursor;
            if (aa.items.len != constructor.details.num_params + rule.fields) return null;
            if (m.listLen(n.b) != d.params.len) return error.TypeMismatch;
            const key = @as(u64, f) | (@as(u64, rule.ctor) << 32);
            var rhs = if (d.params.len == 0) rule.rhs else self.rule_cache.get(key) orelse blk: {
                var us: c.SmallList(u32, 8) = .{};
                defer us.deinit(m.allocator);
                m.listArray(n.b, &us);
                const result = m.substLevels(rule.rhs, d.params, us.items);
                self.rule_cache.put(m.allocator, key, result) catch c.oom();
                break :blk result;
            };
            rhs = m.apps(rhs, args[0 .. d.details.num_params + d.details.num_motives + d.details.num_minors]);
            rhs = m.apps(rhs, aa.items[constructor.details.num_params..]);
            return m.apps(rhs, args[major + 1 ..]);
        }
    }
    return null;
}
