//! Definitional equality with proof irrelevance, eta, and bounded speculative congruence.
const std = @import("std");
const c = @import("common.zig");
const expr = @import("expr.zig");
const Expr = c.Expr;
const Error = c.Error;
const Checker = @import("type_checker.zig").Checker;

pub fn etaExpand(self: *Checker, e: Expr, ty: Expr) Error!?Expr {
    const m = self.expressions;
    var aa: c.SmallList(Expr, 16) = .{};
    defer aa.deinit(m.allocator);
    const h = m.get(m.unfoldApps(ty, &aa));
    if (h.kind != .cnst) return null;
    const d = self.environment.find(h.a) orelse return null;
    if (d.kind != .inductive or d.details.recursive or d.details.num_indices != 0 or d.details.ctors.len != 1 or aa.items.len != d.details.num_params) return null;
    const ctor = self.environment.find(d.details.ctors[0]).?;
    var r = m.apps(m.cnst(ctor.name, h.b), aa.items);
    for (0..ctor.details.num_fields) |i| r = m.app(r, m.mk(.proj, d.name, @intCast(i), e));
    return r;
}

fn sameConst(self: *Checker, a: expr.Node, b: expr.Node) bool {
    if (a.a != b.a) return false;
    var x = a.b;
    var y = b.b;
    while (x != 0 and y != 0) {
        const xx = self.expressions.listNode(x);
        const yy = self.expressions.listNode(y);
        if (!self.expressions.levels.equal(xx[0], yy[0])) return false;
        x = xx[1];
        y = yy[1];
    }
    return x == y;
}

fn structural(self: *Checker, a: Expr, b: Expr) Error!bool {
    const m = self.expressions;
    const x = m.get(a);
    const y = m.get(b);
    if (x.kind != y.kind) return false;
    return switch (x.kind) {
        .sort => m.levels.equal(x.a, y.a),
        .cnst => sameConst(self, x, y),
        .fvar, .bvar, .nat, .str => false,
        .app => compareApplications(self, a, b),
        .lam, .pi => compareBindings(self, a, b, x.kind),
        .proj => x.a == y.a and x.b == y.b and try compareProjections(self, x, y),
        .letE => false,
    };
}

fn compareBindings(self: *Checker, left: Expr, right: Expr, kind: expr.Kind) Error!bool {
    const m = self.expressions;
    const saved_depth = self.binder_depth;
    defer self.binder_depth = saved_depth;
    var variables: c.SmallList(Expr, 16) = .{};
    defer variables.deinit(m.allocator);
    var a = left;
    var b = right;
    while (m.kind(a) == kind and m.kind(b) == kind) {
        // Both bodies use the same substitution for the binders opened so far.
        // Identical remaining syntax needs neither instantiation nor inference.
        if (a == b) return true;
        const x = m.get(a);
        const y = m.get(b);
        const domain = m.instantiateReverse(x.a, variables.items);
        const other_domain = if (x.a == y.a) domain else m.instantiateReverse(y.a, variables.items);
        if (!try self.defeq(domain, other_domain)) return false;
        c.append(Expr, &variables, m.allocator, self.scopedVariable(domain));
        self.binder_depth += 1;
        a = x.b;
        b = y.b;
    }
    if (a == b) return true;
    return self.defeq(m.instantiateReverse(a, variables.items), m.instantiateReverse(b, variables.items));
}

fn compareApplications(self: *Checker, left: Expr, right: Expr) Error!bool {
    const m = self.expressions;
    var left_arguments: c.SmallList(Expr, 16) = .{};
    defer left_arguments.deinit(m.allocator);
    var right_arguments: c.SmallList(Expr, 16) = .{};
    defer right_arguments.deinit(m.allocator);
    const left_head = m.unfoldApps(left, &left_arguments);
    const right_head = m.unfoldApps(right, &right_arguments);
    if (left_arguments.items.len != right_arguments.items.len) return false;
    if (left_head != right_head) {
        const a = m.get(left_head);
        const b = m.get(right_head);
        // Comparing distinct named functions without their arguments can
        // open huge dependent telescopes. Let lazy delta unfold the complete
        // applications instead, preserving the supplied arguments.
        if (a.kind == .cnst and b.kind == .cnst) {
            if (!sameConst(self, a, b)) return false;
        } else if (!try self.defeq(left_head, right_head)) return false;
    }
    // Compare a whole spine instead of recursively comparing partially applied
    // functions and repeatedly inferring their large dependent function types.
    for (left_arguments.items, right_arguments.items) |a, b| {
        if (!try self.defeq(a, b)) return false;
    }
    return true;
}

/// Unfold structure bases together, selecting a field as soon as both bases
/// expose constructors. Comparing all fields first can evaluate arbitrarily
/// expensive data that these projections discard.
fn compareProjections(self: *Checker, left: expr.Node, right: expr.Node) Error!bool {
    const m = self.expressions;
    var x = left.c;
    var y = right.c;
    while (true) {
        if (x == y) return true;
        const projection_x = m.mk(.proj, left.a, left.b, x);
        const projection_y = m.mk(.proj, right.a, right.b, y);
        const px = try self.reduce(projection_x, false);
        const py = try self.reduce(projection_y, false);
        if (px != projection_x or py != projection_y) return self.defeq(px, py);
        if (try boundedCongruence(self, x, y, 512)) return true;
        if (!try deltaStep(self, &x, &y)) return self.defeq(x, y);
    }
}
/// Congruence is an optimization when a definition could instead unfold.
/// Bound that attempt: a definition may discard an expensive argument.
fn tryCongruence(self: *Checker, left: Expr, right: Expr) Error!bool {
    return boundedCongruence(self, left, right, 32768);
}

fn boundedCongruence(self: *Checker, left: Expr, right: Expr, budget: u64) Error!bool {
    const left_head = self.expressions.get(self.expressions.head(left));
    const right_head = self.expressions.get(self.expressions.head(right));
    const projection = isProjectionFunction(self, left_head) or isProjectionFunction(self, right_head);
    // A projection ignores every other field. Expose it before comparing the
    // structure argument, whose unrelated data fields need not be equal.
    if (projection) return false;
    if (self.speculation_limit != null and budget == 32768) return structural(self, left, right);
    const can_unfold = (left_head.kind == .cnst and (if (self.environment.find(left_head.a)) |d| d.kind == .definition else false)) or
        (right_head.kind == .cnst and (if (self.environment.find(right_head.a)) |d| d.kind == .definition else false));
    if (!can_unfold) return structural(self, left, right);
    const previous = self.speculation_limit;
    self.speculation_limit = @min(previous orelse std.math.maxInt(u64), self.ticks + budget);
    defer self.speculation_limit = previous;
    return structural(self, left, right) catch |err| switch (err) {
        error.SpeculationLimit => false,
        else => return err,
    };
}

fn isProjectionFunction(self: *Checker, head: expr.Node) bool {
    if (head.kind != .cnst) return false;
    const declaration = self.environment.find(head.a) orelse return false;
    return declaration.projection_function;
}

pub fn defeq(self: *Checker, a: Expr, b: Expr) Error!bool {
    if (a == b) return true;
    try self.tick();
    self.depth += 1;
    defer self.depth -= 1;
    const key = @as(u64, @min(a, b)) | (@as(u64, @max(a, b)) << 32);
    if (self.eq_cache.get(key)) |v| return v;
    const ok = defeqCore(self, a, b) catch |err| {
        if (err != error.SpeculationLimit and !self.reported) {
            self.reported = true;
            std.debug.print("conversion failed: {s}, depth={d}, steps={d}\n", .{ @errorName(err), self.depth, self.ticks });
            self.dump(a, 6);
            std.debug.print("\nvs\n", .{});
            self.dump(b, 6);
            std.debug.print("\n", .{});
        }
        return err;
    };
    self.eq_cache.put(self.expressions.allocator, key, ok) catch c.oom();
    return ok;
}

fn defeqCore(self: *Checker, a: Expr, b: Expr) Error!bool {
    const m = self.expressions;
    const initial_left = m.get(a);
    const initial_right = m.get(b);
    if (initial_left.kind == initial_right.kind) {
        switch (initial_left.kind) {
            .sort => return structural(self, a, b),
            .pi, .lam => return compareBindings(self, a, b, initial_left.kind),
            .nat, .str => return false,
            else => {},
        }
    }
    // Proofs by reflection compare a closed computation with Bool.true. Its
    // type is already fixed by the other side, so avoid inferring intermediate
    // dependent recursor types before evaluating the computation.
    if (initial_right.kind == .cnst and initial_right.a == self.environment.builtin("Bool.true") and (self.eager_reduce or !m.hasFreeVariables(a))) {
        if (try self.whnf(a) == b) return true;
    }
    // Proof irrelevance must precede evaluation of proof terms: proofs can
    // contain enormous computations that conversion has no reason to run.
    var original_type: ?Expr = null;
    if (!certainlyNotProof(self, a)) {
        original_type = try self.infer(a, false);
        if (try self.isProp(original_type.?)) return self.defeq(original_type.?, try self.infer(b, false));
    }
    var x = try self.reduce(a, false);
    var y = try self.reduce(b, false);
    if (x == y) return true;
    // The syntactic test avoids unfolding large definitions with equal arguments.
    if (try tryCongruence(self, x, y)) return true;
    while (try deltaStep(self, &x, &y)) {
        if (x == y or try tryCongruence(self, x, y)) return true;
    }
    // The cheap pass may have left projections blocked on definitions.
    // Force their bases only after congruence and lazy delta have failed.
    const full_x = try self.reduceProjections(x);
    const full_y = try self.reduceProjections(y);
    if (full_x != x or full_y != y) return self.defeq(full_x, full_y);
    const nx = m.get(x);
    const ny = m.get(y);
    if (nx.kind == .nat and ny.kind == .nat) return false;
    if (nx.kind == .str and ny.kind == .str) return false;
    const xn = @import("primitive.zig").number(self, x);
    const yn = @import("primitive.zig").number(self, y);
    if (xn != null and yn != null) return xn.? == yn.?;
    if (nx.kind == .lam or ny.kind == .lam) {
        const l = if (nx.kind == .lam) nx else ny;
        const other = if (nx.kind == .lam) y else x;
        const ot = m.get(try self.whnf(try self.infer(other, false)));
        if (ot.kind != .pi or !try self.defeq(l.a, ot.a)) return false;
        const v = self.scopedVariable(l.a);
        self.binder_depth += 1;
        defer self.binder_depth -= 1;
        return self.defeq(m.inst(l.b, v), m.app(other, v));
    }
    const ex = try @import("primitive.zig").expand(self, x);
    const ey = try @import("primitive.zig").expand(self, y);
    if (nx.kind == .str or ny.kind == .str) return self.defeq(try self.whnf(ex), try self.whnf(ey));
    if (ex != x or ey != y) return structural(self, ex, ey);
    const xt = original_type orelse try self.infer(a, false);
    const ty = try self.whnf(xt);
    const h1 = m.get(m.head(x));
    const h2 = m.get(m.head(y));
    const left_constructor = h1.kind == .cnst and (if (self.environment.find(h1.a)) |d| d.kind == .ctor else false);
    const right_constructor = h2.kind == .cnst and (if (self.environment.find(h2.a)) |d| d.kind == .ctor else false);
    // Constructor congruence has already failed. Eta-expanding a constructor
    // into its own projections here would repeat that failure forever.
    if (left_constructor and right_constructor) return false;
    if (left_constructor or right_constructor) {
        if (!try self.defeq(xt, try self.infer(y, false))) return false;
    }
    if (left_constructor) {
        if (try self.etaExpand(y, ty)) |ey_| return self.defeq(x, ey_);
    }
    if (right_constructor) {
        if (try self.etaExpand(x, ty)) |ex_| return self.defeq(ex_, y);
    }
    if (try self.etaExpand(x, ty)) |ex_| {
        const h = m.get(m.head(ex_));
        const ctor = self.environment.find(h.a).?;
        if (ctor.details.num_fields == 0) return self.defeq(xt, try self.infer(y, false));
    }
    return false;
}

fn certainlyNotProof(self: *Checker, expression: Expr) bool {
    const m = self.expressions;
    const head = m.get(m.head(expression));
    if (head.kind == .sort or head.kind == .pi) return true;
    if (head.kind == .fvar) {
        var result_type = head.a;
        while (m.kind(result_type) == .pi) result_type = m.get(result_type).b;
        if (m.kind(result_type) == .sort) return true;
        const result_head = m.get(m.head(result_type));
        var universe_type = switch (result_head.kind) {
            .cnst => (self.environment.find(result_head.a) orelse return false).ty,
            .fvar => result_head.a,
            // A result depending on a consumed type argument cannot be
            // classified without substitution. Retain ordinary inference.
            else => return false,
        };
        while (m.kind(universe_type) == .pi) universe_type = m.get(universe_type).b;
        const universe = m.get(universe_type);
        // A fixed positive final universe makes every enclosing Pi positive.
        // Bare parameters and Prop remain unknown, including after arguments
        // instantiate a polymorphic type to universe zero.
        return universe.kind == .sort and m.levels.nonzero(universe.a);
    }
    if (head.kind != .cnst) return false;
    const declaration = self.environment.find(head.a) orelse return false;
    // Derived from the type's syntax and strictly positive result universes.
    // Unknown or potentially zero universes retain the proof-irrelevance path.
    return declaration.nonproof_result;
}

fn deltaStep(self: *Checker, left: *Expr, right: *Expr) Error!bool {
    const x = left.*;
    const y = right.*;
    const hx = try unfoldHeight(self, x);
    const hy = try unfoldHeight(self, y);
    if (hx == null and hy == null) return false;
    // A projected function can conceal the very same definition on the other
    // side. Expose it before unfolding that definition into expensive recursion.
    if (hx == null and self.expressions.kind(self.expressions.head(x)) == .proj) {
        const exposed = try self.reduceProjections(x);
        if (exposed != x) {
            left.* = exposed;
            return true;
        }
    }
    if (hy == null and self.expressions.kind(self.expressions.head(y)) == .proj) {
        const exposed = try self.reduceProjections(y);
        if (exposed != y) {
            right.* = exposed;
            return true;
        }
    }
    // Determine priority before instantiating a definition's body. Unfolding
    // both sides speculatively can copy a large polymorphic body that is never
    // needed: reducing the higher-priority side may already make them equal.
    if (hx != null and (hy == null or hx.? >= hy.?)) left.* = try self.reduce((try self.unfold(x)).?, false);
    if (hy != null and (hx == null or hy.? >= hx.?)) right.* = try self.reduce((try self.unfold(y)).?, false);
    return true;
}

fn unfoldHeight(self: *Checker, e: Expr) Error!?u64 {
    const m = self.expressions;
    const h = m.get(m.head(e));
    if (h.kind == .fvar) return if (h.c != 0) 0 else null;
    if (h.kind == .cnst) {
        const d = self.environment.find(h.a) orelse return null;
        if (d.kind != .definition) return null;
        if (d.params.len != m.listLen(h.b)) return error.TypeMismatch;
        return switch (d.hint_kind) {
            .opaque_hint => 0,
            .regular => 1 + @as(u64, d.height),
            .abbrev => @as(u64, 1) << 33,
        };
    }
    return null;
}
