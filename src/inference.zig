//! Type inference and validation of closed expressions with explicit local variables.
const std = @import("std");
const c = @import("common.zig");
const expr = @import("expr.zig");
const Expr = c.Expr;
const Error = c.Error;
const Checker = @import("type_checker.zig").Checker;

/// The expected type must already be well formed in the current environment.
/// Check lambdas against their expected Pi telescope directly. This avoids
/// constructing an inferred telescope only to reopen it during conversion.
pub fn checkAgainst(self: *Checker, expression: Expr, expected: Expr) Error!void {
    const m = self.expressions;
    if (m.kind(expression) != .lam) {
        if (!try self.defeq(expected, try self.infer(expression, true))) return error.TypeMismatch;
        return;
    }
    if (self.infer_cache[1].get(expression)) |inferred| {
        if (!try self.defeq(expected, inferred)) return error.TypeMismatch;
        return;
    }
    try self.tick();
    self.depth += 1;
    defer self.depth -= 1;
    var body = expression;
    var type_body = try self.ensure(expected, .pi);
    var variables: c.SmallList(Expr, 16) = .{};
    defer variables.deinit(m.allocator);
    while (m.kind(body) == .lam and m.kind(type_body) == .pi) {
        const term = m.get(body);
        const type_ = m.get(type_body);
        const domain = m.instantiateReverse(term.a, variables.items);
        const expected_domain = if (term.a == type_.a) domain else m.instantiateReverse(type_.a, variables.items);
        if (domain != expected_domain) {
            _ = try self.ensure(try self.infer(domain, true), .sort);
            if (!try self.defeq(domain, expected_domain)) return error.TypeMismatch;
        }
        c.append(Expr, &variables, m.allocator, m.fvar(domain));
        body = term.b;
        type_body = type_.b;
    }
    try checkAgainst(self, m.instantiateReverse(body, variables.items), m.instantiateReverse(type_body, variables.items));
    self.infer_cache[1].put(m.allocator, expression, expected) catch c.oom();
}

pub fn constType(self: *Checker, e: Expr) Error!Expr {
    if (self.constant_type_cache.get(e)) |result| return result;
    const n = self.expressions.get(e);
    const d = self.environment.find(n.a) orelse return error.UnknownConstant;
    if (d.unsafe_) return error.TypeMismatch;
    if (d.params.len != self.expressions.listLen(n.b)) return error.TypeMismatch;
    const m = self.expressions;
    const key = (@as(u64, n.a) << 32) | n.b;
    // Generated recursors temporarily replace their exported signatures while
    // being checked. Those signatures must never enter this persistent cache.
    const persistent = expr.Pool.isPermanent(d.ty);
    if (persistent) {
        if (m.constant_types.get(key)) |result| {
            self.constant_type_cache.put(m.allocator, e, result) catch c.oom();
            return result;
        }
    }
    var us: c.SmallList(u32, 8) = .{};
    defer us.deinit(self.expressions.allocator);
    self.expressions.listArray(n.b, &us);
    const previous_promote = m.promote;
    defer m.promote = previous_promote;
    m.promote = persistent;
    const result = m.substLevels(d.ty, d.params, us.items);
    if (persistent and expr.Pool.isPermanent(result) and m.constant_types.count < 262144) m.constant_types.put(m.allocator, key, result) catch c.oom();
    self.constant_type_cache.put(self.expressions.allocator, e, result) catch c.oom();
    return result;
}

pub fn ensure(self: *Checker, e: Expr, kind: expr.Kind) Error!Expr {
    const r = try self.whnf(e);
    if (self.expressions.kind(r) != kind) return if (kind == .sort) error.ExpectedSort else error.ExpectedPi;
    return r;
}

pub fn infer(self: *Checker, e: Expr, comptime check: bool) Error!Expr {
    try self.tick();
    self.depth += 1;
    defer self.depth -= 1;
    const m = self.expressions;
    const n = m.get(e);
    if (n.range != 0) return error.LooseVariable;
    if (n.kind == .fvar) return n.a;
    const ci: usize = if (check) 1 else 0;
    if (self.infer_cache[ci].get(e)) |ty| return ty;
    const r: Expr = switch (n.kind) {
        .bvar => return error.LooseVariable,
        .fvar => n.a,
        .sort => blk: {
            if (check and !m.levels.valid(n.a, self.params)) return error.UndeclaredUniverse;
            break :blk m.sort(m.levels.succ(n.a));
        },
        .cnst => blk: {
            if (check) {
                var p = n.b;
                while (p != 0) : (p = m.lists.items[p][1]) {
                    if (!m.levels.valid(m.lists.items[p][0], self.params)) return error.UndeclaredUniverse;
                }
            }
            break :blk try self.constType(e);
        },
        .app => try inferApplication(self, e, check),
        .lam, .pi => blk: {
            if (m.kind(n.b) == n.kind) break :blk try inferBindings(self, e, check);
            const dt = if (check) try self.infer(n.a, true) else 0;
            if (check) _ = try self.ensure(dt, .sort);
            const x = m.fvar(n.a);
            const bt = try self.infer(m.inst(n.b, x), check);
            if (n.kind == .lam) break :blk m.binder(.pi, n.a, m.abstract(bt, &.{x}));
            const bs = m.get(try self.ensure(bt, .sort));
            // Unchecked inference assumes the term is well formed. For a
            // propositional codomain, imax(_, 0) is zero independently of
            // the domain universe. Checked inference still validates it.
            if (!check and m.levels.equal(bs.a, 0)) break :blk m.sort(0);
            const ds = m.get(try self.ensure(if (check) dt else try self.infer(n.a, false), .sort));
            break :blk m.sort(m.levels.imax(ds.a, bs.a));
        },
        .letE => blk: {
            if (check) {
                _ = try self.ensure(try self.infer(n.a, true), .sort);
                if (!try self.defeq(n.a, try self.infer(n.b, true))) return error.TypeMismatch;
            }
            const variable = m.letVariable(n.a, n.b);
            const body_type = try self.infer(m.inst(n.c, variable), check);
            break :blk m.inst(m.abstract(body_type, &.{variable}), n.b);
        },
        .proj => try inferProj(self, n, check),
        .nat => try literalType(self, "Nat"),
        .str => try literalType(self, "String"),
    };
    self.infer_cache[ci].put(m.allocator, e, r) catch c.oom();
    return r;
}

/// Instantiate a dependent result type once per exposed Pi telescope, rather
/// than rebuilding the remaining function type after every application.
fn inferApplication(self: *Checker, expression: Expr, comptime check: bool) Error!Expr {
    const m = self.expressions;
    var arguments: c.SmallList(Expr, 16) = .{};
    defer arguments.deinit(m.allocator);
    const head = m.unfoldApps(expression, &arguments);
    var result = try self.infer(head, check);
    var start: usize = 0;
    for (arguments.items, 0..) |argument, index| {
        if (m.kind(result) != .pi) {
            result = m.instantiateReverse(result, arguments.items[start..index]);
            result = try self.ensure(result, .pi);
            start = index;
        }
        const function_type = m.get(result);
        if (check) {
            const domain = m.instantiateReverse(function_type.a, arguments.items[start..index]);
            if (m.kind(argument) == .lam) {
                try checkAgainst(self, argument, domain);
                result = function_type.b;
                continue;
            }
            const argument_type = try self.infer(argument, true);
            const previous_eager = self.eager_reduce;
            defer self.eager_reduce = previous_eager;
            const node = m.get(argument);
            if (node.kind == .app) {
                const function = m.get(node.a);
                if (function.kind == .app) {
                    const annotation = m.get(function.a);
                    if (annotation.kind == .cnst and annotation.a == self.environment.builtin("eagerReduce")) self.eager_reduce = true;
                }
            }
            if (!try self.defeq(domain, argument_type)) return error.TypeMismatch;
        }
        result = function_type.b;
    }
    return m.instantiateReverse(result, arguments.items[start..]);
}

fn literalType(self: *Checker, name: []const u8) Error!Expr {
    const id = self.environment.named(name);
    if (self.environment.find(id) == null) return error.UnknownConstant;
    return self.expressions.cnst(id, 0);
}

fn inferProj(self: *Checker, n: expr.Node, comptime check: bool) Error!Expr {
    const ty = try self.whnf(try self.infer(n.c, check));
    return projectionType(self, n, ty);
}

pub fn projectionType(self: *Checker, n: expr.Node, ty: Expr) Error!Expr {
    const m = self.expressions;
    var aa: c.SmallList(Expr, 16) = .{};
    defer aa.deinit(m.allocator);
    const h = m.get(m.unfoldApps(ty, &aa));
    if (h.kind != .cnst or h.a != n.a) return error.InvalidProjection;
    const d = self.environment.find(h.a) orelse return error.UnknownConstant;
    if (d.kind != .inductive or d.ctors.len != 1) return error.InvalidProjection;
    const ctor = self.environment.find(d.ctors[0]).?;
    if (n.b >= ctor.num_fields or aa.items.len != d.num_params + d.num_indices) return error.InvalidProjection;
    var ct = try self.constType(m.cnst(ctor.name, h.b));
    for (aa.items[0..d.num_params]) |a| {
        const p = m.get(try self.ensure(ct, .pi));
        ct = m.inst(p.b, a);
    }
    const is_prop = try self.isProp(ty);
    for (0..n.b) |i| {
        const p = m.get(try self.ensure(ct, .pi));
        if (m.get(p.b).range > 0 and is_prop and !try self.isProp(p.a)) return error.InvalidProjection;
        ct = m.inst(p.b, m.mk(.proj, n.a, @intCast(i), n.c));
    }
    const field = m.get(try self.ensure(ct, .pi)).a;
    if (try self.isProp(ty) and !try self.isProp(field)) return error.InvalidProjection;
    return field;
}

pub fn isProp(self: *Checker, e: Expr) Error!bool {
    const ty = self.expressions.get(try self.whnf(try self.infer(e, false)));
    return ty.kind == .sort and self.expressions.levels.equal(ty.a, 0);
}

/// Open a consecutive binder telescope once, rather than copying a large
/// body once per binder. Original domains retain the correct bound indices
/// when rebuilding the inferred function type.
fn inferBindings(self: *Checker, expression: Expr, comptime check: bool) Error!Expr {
    const m = self.expressions;
    const kind = m.kind(expression);
    var domains: c.SmallList(Expr, 16) = .{};
    defer domains.deinit(m.allocator);
    var variables: c.SmallList(Expr, 16) = .{};
    defer variables.deinit(m.allocator);
    var levels: c.SmallList(u32, 8) = .{};
    defer levels.deinit(m.allocator);
    var body = expression;
    while (m.kind(body) == kind) {
        const node = m.get(body);
        const domain = m.instantiateReverse(node.a, variables.items);
        if (check) {
            const sort = m.get(try self.ensure(try self.infer(domain, true), .sort));
            c.append(u32, &levels, m.allocator, sort.a);
        }
        c.append(Expr, &domains, m.allocator, node.a);
        c.append(Expr, &variables, m.allocator, m.fvar(domain));
        body = node.b;
    }
    var result = try self.infer(m.instantiateReverse(body, variables.items), check);
    if (kind == .lam) {
        result = m.abstract(result, variables.items);
        var i = domains.items.len;
        while (i > 0) {
            i -= 1;
            result = m.binder(.pi, domains.items[i], result);
        }
        return result;
    }
    var level = m.get(try self.ensure(result, .sort)).a;
    if (!check) {
        if (m.levels.equal(level, 0)) return m.sort(0);
        var index = variables.items.len;
        while (index > 0) {
            index -= 1;
            const domain = m.get(variables.items[index]).a;
            const sort = m.get(try self.ensure(try self.infer(domain, false), .sort));
            level = m.levels.imax(sort.a, level);
        }
        return m.sort(level);
    }
    var i = levels.items.len;
    while (i > 0) {
        i -= 1;
        level = m.levels.imax(levels.items[i], level);
    }
    return m.sort(level);
}
