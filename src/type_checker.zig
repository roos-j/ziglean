// microlean's infer/whnf/defeq architecture with closed local variables,
// context-safe memoization, primitive reductions and lazy delta conversion.
const std = @import("std");
const c = @import("common.zig");
const expr = @import("expr.zig");
const environment = @import("environment.zig");
const Expr = c.Expr;
const Error = c.Error;
const Cache = @import("check_cache.zig").Map;
const ExprCache = @import("check_cache.zig").ExprMap(Expr);
pub const Checker = struct {
    expressions: *expr.Pool,
    environment: *environment.Environment,
    params: []const u32 = &.{},
    infer_cache: [2]ExprCache = .{ .{}, .{} },
    whnf_cache: [6]ExprCache = .{ExprCache{}} ** 6,
    eq_cache: Cache(u64, bool) = .{},
    constant_type_cache: Cache(Expr, Expr) = .{},
    unfold_cache: Cache(Expr, Expr) = .{},
    rule_cache: Cache(u64, Expr) = .{},
    scoped_locals: Cache(u64, Expr) = .{},
    substitution_profile: @import("substitution_profile.zig").Profile = .{},
    binder_depth: u32 = 0,
    ticks: u64 = 0,
    max_ticks: u64 = 100_000_000,
    max_temporary_nodes: u32 = 64_000_000,
    node_start: usize = 0,
    depth: u32 = 0,
    speculation_limit: ?u64 = null,
    reported: bool = false,
    eager_reduce: bool = false,
    pub fn init(m: *expr.Pool, env: *environment.Environment) Checker {
        m.temporary = true;
        return .{ .expressions = m, .environment = env };
    }
    pub fn deinit(self: *Checker) void {
        for (&self.infer_cache) |*x| x.deinit(self.expressions.allocator);
        for (&self.whnf_cache) |*x| x.deinit(self.expressions.allocator);
        self.eq_cache.deinit(self.expressions.allocator);
        self.constant_type_cache.deinit(self.expressions.allocator);
        self.unfold_cache.deinit(self.expressions.allocator);
        self.rule_cache.deinit(self.expressions.allocator);
        self.scoped_locals.deinit(self.expressions.allocator);
        self.substitution_profile.deinit(self.expressions.allocator);
    }
    pub fn clearCaches(self: *Checker) void {
        for (&self.infer_cache) |*x| x.clearRetainingCapacity();
        for (&self.whnf_cache) |*x| x.clearRetainingCapacity();
        self.eq_cache.clearRetainingCapacity();
        self.constant_type_cache.clearRetainingCapacity();
        self.unfold_cache.clearRetainingCapacity();
        self.rule_cache.clearRetainingCapacity();
        self.scoped_locals.clearRetainingCapacity();
    }
    pub fn beginDeclaration(self: *Checker) void {
        self.clearCaches();
        self.substitution_profile.beginDeclaration();
        self.params = &.{};
        self.ticks = 0;
        self.depth = 0;
        self.binder_depth = 0;
        self.speculation_limit = null;
        self.reported = false;
        self.eager_reduce = false;
        self.expressions.temporary = true;
        self.node_start = self.expressions.local.nodes.items.len;
    }
    pub fn trimCaches(self: *Checker) void {
        const allocator = self.expressions.allocator;
        for (&self.infer_cache) |*cache| cache.trim(allocator);
        for (&self.whnf_cache) |*cache| cache.trim(allocator);
        self.eq_cache.trim(allocator);
        self.constant_type_cache.trim(allocator);
        self.unfold_cache.trim(allocator);
        self.rule_cache.trim(allocator);
        self.scoped_locals.trim(allocator);
    }
    /// Sibling inference/conversion scopes may share an identical typed local.
    /// The caller advances binder_depth while the local is in scope, restores
    /// it on exit, and abstracts the local from any returned expression. This
    /// prevents nested binders from aliasing and keeps memoized terms closed
    /// with respect to the scopes through which their results escape.
    /// Let-bound values use unique locals because type alone is insufficient.
    pub fn scopedVariable(self: *Checker, domain: Expr) Expr {
        const key = (@as(u64, self.binder_depth) << 32) | domain;
        if (self.scoped_locals.get(key)) |variable| return variable;
        const variable = self.expressions.fvar(domain);
        self.scoped_locals.put(self.expressions.allocator, key, variable) catch c.oom();
        return variable;
    }
    pub inline fn tick(self: *Checker) Error!void {
        self.ticks += 1;
        if (self.ticks > self.max_ticks or self.depth > 60000 or self.expressions.local.nodes.items.len - self.node_start > self.max_temporary_nodes) {
            @branchHint(.unlikely);
            std.debug.print("budget exceeded: depth={d}, steps={d}, temporary nodes={d}\n", .{ self.depth, self.ticks, self.expressions.local.nodes.items.len });
            return error.ResourceLimit;
        }
        if (self.speculation_limit) |limit| {
            if (self.ticks > limit) return error.SpeculationLimit;
        }
    }
    pub fn whnf(self: *Checker, e: Expr) Error!Expr {
        return self.reduce(e, true);
    }
    pub fn checkDecl(self: *Checker, d: environment.Decl) Error!void {
        self.params = d.params;
        self.clearCaches();
        for (d.params, 0..) |p, i| {
            if (std.mem.indexOfScalar(u32, d.params[0..i], p) != null) return error.UndeclaredUniverse;
        }
        if (d.unsafe_) return error.TypeMismatch;
        const ty = try self.ensure(try self.infer(d.ty, true), .sort);
        if (d.kind == .theorem and !self.expressions.levels.equal(self.expressions.get(ty).a, 0)) return error.TypeMismatch;
        if (d.value) |v| {
            try @import("inference.zig").checkAgainst(self, v, d.ty);
        }
        try self.environment.add(d);
    }

    pub fn constType(self: *Checker, expression: Expr) Error!Expr {
        return @import("inference.zig").constType(self, expression);
    }
    pub fn ensure(self: *Checker, expression: Expr, kind: expr.Kind) Error!Expr {
        return @import("inference.zig").ensure(self, expression, kind);
    }
    pub fn infer(self: *Checker, expression: Expr, comptime check: bool) Error!Expr {
        return @import("inference.zig").infer(self, expression, check);
    }
    pub fn isProp(self: *Checker, expression: Expr) Error!bool {
        return @import("inference.zig").isProp(self, expression);
    }
    pub fn unfold(self: *Checker, expression: Expr) Error!?Expr {
        return @import("reduction.zig").unfold(self, expression);
    }
    pub fn reduce(self: *Checker, expression: Expr, comptime delta: bool) Error!Expr {
        return @import("reduction.zig").reduce(self, expression, delta);
    }
    pub fn reduceProjections(self: *Checker, expression: Expr) Error!Expr {
        return @import("reduction.zig").reduceProjections(self, expression);
    }
    pub fn defeq(self: *Checker, left: Expr, right: Expr) Error!bool {
        return @import("conversion.zig").defeq(self, left, right);
    }
    pub fn etaExpand(self: *Checker, expression: Expr, type_: Expr) Error!?Expr {
        return @import("conversion.zig").etaExpand(self, expression, type_);
    }
    pub fn dump(self: *Checker, expression: Expr, depth: u32) void {
        @import("diagnostics.zig").dump(self, expression, depth);
    }
};
