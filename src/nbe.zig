//! Lazy normalization by evaluation for expensive WHNF requests. Environments
//! share arguments instead of substituting into syntax at every beta/zeta step.
//! Readback substitutes only into the final weak-head value; conversion, typing,
//! proof irrelevance and the uncommon recursor rules remain in the main kernel.
const std = @import("std");
const c = @import("common.zig");
const Checker = @import("type_checker.zig").Checker;
const Expr = c.Expr;
const Id = u32;
const missing = std.math.maxInt(Id);
const Failure = c.Error || error{Fallback};
const Node = struct {
    kind: enum { closure, app, proj, erased, free },
    a: u32,
    b: u32 = 0,
    c: u32 = 0,
    // Core WHNF, full WHNF, and beta/let evaluation have separate memos.
    result: [3]Id = .{ missing, missing, missing },
    quoted: Expr = missing,
    marked: bool = false,
};

const Binding = struct { parent: Id, value: Id, length: u32, marked: bool = false };
const QuoteKey = struct { expression: Expr, environment: Id, depth: u32 };
const SupportKey = struct { environment: Id, mask: u64 };

fn pop(list: *c.SmallList(Id, 16)) ?Id {
    if (list.items.len == 0) return null;
    const value = list.items[list.items.len - 1];
    list.items.len -= 1;
    return value;
}

pub inline fn whnf(checker: *Checker, expression: Expr, comptime delta: bool) c.Error!?Expr {
    if (checker.nbe_active or checker.nbe_blocked or !checker.nbe_enabled or checker.speculation_limit != null) return null;
    if (checker.expressions.get(expression).range != 0) return null;
    // Keep ordinary declarations and open core conversion on the existing path.
    // These are work thresholds, independent of names, files and test inputs.
    if (!checker.nbe_prefer and checker.ticks < checker.nbe_min_work and checker.expressions.local.nodes.items.len - checker.node_start < checker.nbe_min_work) return null;
    if ((!delta or checker.nbe_min_work != 0) and checker.expressions.hasFreeVariables(expression)) return null;
    const head = checker.expressions.get(checker.expressions.head(expression));
    // General dependent conversion benefits from lazy delta and proof
    // irrelevance before evaluation. Use semantic values for explicit beta/let
    // computation or a closed reflection request, not arbitrary hot terms.
    if (checker.nbe_min_work != 0) {
        if (!checker.nbe_prefer and head.kind != .lam and head.kind != .letE) return null;
    }
    if (head.kind == .cnst) {
        const d = checker.environment.find(head.a) orelse return null;
        if (d.kind != .definition and d.kind != .recursor and d.kind != .quotient) return null;
    }
    return attempt(checker, expression, delta);
}

// Keep the evaluator's allocation/cleanup frame off the ordinary reduction path.
fn attempt(checker: *Checker, expression: Expr, comptime delta: bool) c.Error!?Expr {
    checker.nbe_active = true;
    defer checker.nbe_active = false;
    var machine: Machine = .{ .checker = checker };
    defer machine.deinit();
    return machine.run(expression, delta) catch |err| switch (err) {
        error.Fallback, error.SpeculationLimit => blk: {
            checker.nbe_blocked = true;
            break :blk null;
        },
        else => return @errorCast(err),
    };
}

const Machine = struct {
    checker: *Checker,
    roots: c.List(Id) = .{},
    free_nodes: c.List(Id) = .{},
    free_bindings: c.List(Id) = .{},
    live_nodes: usize = 0,
    live_bindings: usize = 0,
    next_collection: usize = 262144,
    proof: Id = missing,
    masks: @import("check_cache.zig").Map(u32, u64) = .{},
    templates: @import("check_cache.zig").Map(Expr, Expr) = .{},
    hot: @import("check_cache.zig").Map(u32, u32) = .{},
    nodes: c.List(Node) = .{},
    bindings: c.List(Binding) = .{},
    closures: @import("check_cache.zig").Map(u64, Id) = .{},
    environments: @import("check_cache.zig").Map(u64, Id) = .{},
    applications: @import("check_cache.zig").Map(u64, Id) = .{},
    trimmed: @import("check_cache.zig").Map(u64, Id) = .{},
    supports: @import("check_cache.zig").Map(Expr, u64) = .{},
    projected: std.AutoHashMapUnmanaged(SupportKey, Id) = .{},
    readback: std.AutoHashMapUnmanaged(QuoteKey, Expr) = .{},

    fn deinit(self: *Machine) void {
        const a = self.checker.expressions.allocator;
        self.roots.deinit(a);
        self.masks.deinit(a);
        self.templates.deinit(a);
        self.hot.deinit(a);
        self.free_nodes.deinit(a);
        self.free_bindings.deinit(a);
        self.nodes.deinit(a);
        self.bindings.deinit(a);
        self.closures.deinit(a);
        self.environments.deinit(a);
        self.applications.deinit(a);
        self.trimmed.deinit(a);
        self.supports.deinit(a);
        self.projected.deinit(a);
        self.readback.deinit(a);
    }
    fn run(self: *Machine, e: Expr, delta: bool) Failure!Expr {
        const root = try self.closure(e, 0);
        const value = if (self.checker.nbe_prefer or self.checker.nbe_min_work == 0) try self.force(root, delta) else try self.evaluate(root);
        const quoted = try self.quote(value);
        const result = if (!self.checker.nbe_prefer and self.checker.nbe_min_work != 0) (if (delta) try self.checker.reduce(quoted, true) else try self.checker.reduce(quoted, false)) else quoted;
        return result;
    }
    fn charge(self: *Machine) Failure!void {
        try self.checker.tick();
        // Bound additional evaluator storage, even when few syntax nodes are
        // allocated. This is the configured resource limit, not a strategy cutoff.
        if (self.live_nodes + self.live_bindings + self.readback.count() >= self.checker.max_temporary_nodes) return error.ResourceLimit;
    }
    fn add(self: *Machine, n: Node) Failure!Id {
        try self.charge();
        const id: Id = if (self.free_nodes.pop()) |v| v else @intCast(self.nodes.items.len);
        if (id == self.nodes.items.len) c.append(Node, &self.nodes, self.checker.expressions.allocator, n) else self.nodes.items[id] = n;
        self.live_nodes += 1;
        return id;
    }
    fn closure(self: *Machine, e: Expr, environment: Id) Failure!Id {
        const node = self.checker.expressions.get(e);
        if (node.kind == .bvar) return self.lookup(environment, node.a);
        var env = try self.trim(environment, node.range);
        if (env != 0) {
            if (try self.support(e)) |mask| env = try self.projectEnvironment(env, mask);
        }
        const key = (@as(u64, e) << 32) | env;
        if (self.closures.get(key)) |id| return id;
        const id = try self.add(.{ .kind = .closure, .a = e, .b = env });
        self.closures.put(self.checker.expressions.allocator, key, id) catch c.oom();
        return id;
    }
    fn trim(self: *Machine, env: Id, count: u32) Failure!Id {
        if (count == 0 or env == 0) return 0;
        if (self.bindings.items[env - 1].length <= count) return env;
        const key = (@as(u64, env) << 32) | count;
        if (self.trimmed.get(key)) |result| return result;
        try self.charge();
        self.checker.depth += 1;
        defer self.checker.depth -= 1;
        const entry = self.bindings.items[env - 1];
        const result = try self.bind(try self.trim(entry.parent, count - 1), entry.value);
        self.trimmed.put(self.checker.expressions.allocator, key, result) catch c.oom();
        return result;
    }
    fn canonical(self: *Machine, value: Id) Id {
        if (value == missing) return value;
        const node = self.nodes.items[value];
        if (node.result[1] != missing) return node.result[1];
        return if (node.result[2] != missing) node.result[2] else value;
    }
    fn bind(self: *Machine, parent: Id, raw_value: Id) Failure!Id {
        const value = if (raw_value == missing) missing else self.canonical(raw_value);
        const key = (@as(u64, parent) << 32) | value;
        if (self.environments.get(key)) |id| return id;
        try self.charge();
        const entry: Binding = .{ .parent = parent, .value = value, .length = if (parent == 0) 1 else self.bindings.items[parent - 1].length + 1 };
        const id: Id = if (self.free_bindings.pop()) |v| v else @intCast(self.bindings.items.len + 1);
        if (id == self.bindings.items.len + 1) c.append(Binding, &self.bindings, self.checker.expressions.allocator, entry) else self.bindings.items[id - 1] = entry;
        self.live_bindings += 1;
        self.environments.put(self.checker.expressions.allocator, key, id) catch c.oom();
        return id;
    }
    fn lookup(self: *Machine, environment: Id, index: u32) Failure!Id {
        var env = environment;
        var i = index;
        while (env != 0) {
            const entry = self.bindings.items[env - 1];
            if (i == 0) return if (entry.value == missing) error.Fallback else entry.value;
            i -= 1;
            env = entry.parent;
        }
        return error.Fallback;
    }
    fn app(self: *Machine, function: Id, raw_argument: Id) Failure!Id {
        const argument = self.canonical(raw_argument);
        const key = (@as(u64, function) << 32) | argument;
        if (self.applications.get(key)) |id| return id;
        const id = try self.add(.{ .kind = .app, .a = function, .b = argument });
        self.applications.put(self.checker.expressions.allocator, key, id) catch c.oom();
        return id;
    }
    // Follow the application spine and bind closures without copying syntax or
    // allocating intermediate lambda/application values. Only demanded arguments
    // are evaluated by recursors, projections and literal operations.
    fn evaluate(self: *Machine, id: Id) Failure!Id {
        if (self.nodes.items[id].result[2] != missing) return self.nodes.items[id].result[2];
        const m = self.checker.expressions;
        var pending: c.SmallList(Id, 16) = .{};
        defer pending.deinit(m.allocator);
        var current = id;
        const result = outer: while (true) {
            try self.charge();
            const node = self.nodes.items[current];
            if (node.kind == .erased) return error.Fallback;
            if (node.result[1] != missing and node.result[1] != current) {
                current = node.result[1];
                continue;
            }
            if (node.result[2] != missing and node.result[2] != current) {
                current = node.result[2];
                continue;
            }
            if (node.kind == .app) {
                c.append(Id, &pending, m.allocator, node.b);
                current = node.a;
                continue;
            }
            if (node.kind == .proj) {
                var value = current;
                while (pop(&pending)) |arg| value = try self.app(value, arg);
                break :outer value;
            }
            var e = node.a;
            var env = node.b;
            while (true) {
                try self.charge();
                const n = m.get(e);
                switch (n.kind) {
                    .app => {
                        c.append(Id, &pending, m.allocator, try self.closure(n.b, env));
                        e = n.a;
                    },
                    .lam => {
                        if (pop(&pending)) |arg| {
                            env = try self.bind(env, if ((try self.support(n.b) orelse 1) & 1 != 0) arg else missing);
                            e = n.b;
                        } else break;
                    },
                    .letE => {
                        env = try self.bind(env, try self.closure(n.b, env));
                        e = n.c;
                    },
                    .bvar => {
                        current = try self.lookup(env, n.a);
                        continue :outer;
                    },
                    .proj => {
                        current = try self.add(.{ .kind = .proj, .a = n.a, .b = n.b, .c = try self.closure(n.c, env) });
                        continue :outer;
                    },
                    else => break,
                }
            }
            var value = try self.closure(e, env);
            while (pop(&pending)) |arg| value = try self.app(value, arg);
            break :outer value;
        };
        self.nodes.items[id].result[2] = result;
        return result;
    }
    fn force(self: *Machine, id: Id, delta: bool) Failure!Id {
        const ci: usize = @intFromBool(delta);
        if (self.nodes.items[id].result[ci] != missing) return self.nodes.items[id].result[ci];
        const root_count = self.roots.items.len;
        defer self.roots.items.len = root_count;
        self.checker.depth += 1;
        defer self.checker.depth -= 1;
        var visited: c.SmallList(Id, 32) = .{};
        defer visited.deinit(self.checker.expressions.allocator);
        var current = id;
        const result = while (true) {
            c.append(Id, &self.roots, self.checker.expressions.allocator, current);
            if (self.live_nodes + self.live_bindings >= self.next_collection) self.collect();
            try self.charge();
            if (self.nodes.items[current].result[ci] != missing) break self.nodes.items[current].result[ci];
            c.append(Id, &visited, self.checker.expressions.allocator, current);
            const evaluated = try self.evaluate(current);
            if (self.nodes.items[evaluated].result[ci] != missing) break self.nodes.items[evaluated].result[ci];
            c.append(Id, &visited, self.checker.expressions.allocator, evaluated);
            c.append(Id, &self.roots, self.checker.expressions.allocator, evaluated);
            const value = try self.normalize(evaluated, delta);
            if (value == evaluated) break value;
            current = value;
        };
        for (visited.items) |v| self.nodes.items[v].result[ci] = result;
        self.nodes.items[result].result[ci] = result;
        return result;
    }
    // Erase only arguments whose declared type syntactically ends in Prop.
    // Type arguments remain present, including Sort u that might instantiate
    // to Prop. Erased values cannot be observed or quoted: either operation
    // retries the original expression with the ordinary kernel.
    fn erasedArguments(self: *Machine, d: @import("environment.zig").Decl) u64 {
        if (self.masks.get(d.name)) |mask| return mask;
        const m = self.checker.expressions;
        var domains: [64]Expr = undefined;
        var count: usize = 0;
        var mask: u64 = 0;
        var ty = d.ty;
        while (count < 64 and m.kind(ty) == .pi) : (count += 1) {
            const pi = m.get(ty);
            domains[count] = pi.a;
            var body = pi.a;
            var bound: u32 = 0;
            while (m.kind(body) == .pi) {
                body = m.get(body).b;
                bound += 1;
            }
            var erased = false;
            var arity: usize = 0;
            while (m.kind(body) == .app) {
                arity += 1;
                body = m.get(body).a;
            }
            const head = m.get(body);
            var head_type: ?Expr = null;
            if (head.kind == .cnst) {
                if (self.checker.environment.find(head.a)) |decl| head_type = decl.ty;
            } else if (head.kind == .bvar and head.a >= bound and head.a - bound < count) {
                head_type = domains[count - 1 - (head.a - bound)];
            }
            if (head_type) |type_| {
                var result = type_;
                var params: usize = 0;
                while (m.kind(result) == .pi) {
                    result = m.get(result).b;
                    params += 1;
                }
                const sort = m.get(result);
                erased = params == arity and sort.kind == .sort and sort.a == 0;
            }
            if (erased) mask |= @as(u64, 1) << @intCast(count);
            ty = pi.b;
        }
        self.masks.put(m.allocator, d.name, mask) catch c.oom();
        return mask;
    }
    fn applyMany(self: *Machine, function: Id, arguments: []const Id) Failure!Id {
        var f = function;
        var used: usize = 0;
        const node = self.nodes.items[f];
        if (node.kind == .closure) {
            var e = node.a;
            var env = node.b;
            while (used < arguments.len and self.checker.expressions.kind(e) == .lam) : (used += 1) {
                const n = self.checker.expressions.get(e);
                const needed = (try self.support(n.b) orelse 1) & 1 != 0;
                env = try self.bind(env, if (needed) arguments[used] else missing);
                e = n.b;
            }
            if (used != 0) f = try self.closure(e, env);
        }
        // Preserve the entire spine before delta reduction, just as the syntax
        // reducer does. In particular, don't unfold Nat primitives too early.
        for (arguments[used..]) |argument| f = try self.app(f, argument);
        return f;
    }
    fn spine(self: *Machine, id: Id, args: *c.SmallList(Id, 16)) Id {
        var head = id;
        while (self.nodes.items[head].kind == .app) {
            const n = self.nodes.items[head];
            c.append(Id, args, self.checker.expressions.allocator, n.b);
            head = n.a;
        }
        std.mem.reverse(Id, args.items);
        return head;
    }
    fn normalize(self: *Machine, id: Id, delta: bool) Failure!Id {
        const m = self.checker.expressions;
        const value_node = self.nodes.items[id];
        if (value_node.kind == .proj) {
            const result = try self.project(value_node.a, value_node.b, value_node.c, delta);
            const node = self.nodes.items[result];
            if (node.kind == .proj and node.a == value_node.a and node.b == value_node.b and node.c == value_node.c) return id;
            return result;
        }
        var args: c.SmallList(Id, 16) = .{};
        defer args.deinit(m.allocator);
        const head = self.spine(id, &args);
        const hn = self.nodes.items[head];
        if (hn.kind != .closure) {
            if (delta) {
                const f = try self.force(head, true);
                if (f != head) return self.applyMany(f, args.items);
            }
            return id;
        }
        const n = m.get(hn.a);
        if (n.kind == .fvar and n.c != 0 and delta) return self.applyMany(try self.closure(n.c - 1, 0), args.items);
        if (n.kind != .cnst) return id;
        // A primitive function is a semantic value until fully applied. In
        // particular a typeclass projection must not unfold Nat.mul before
        // its pending operands arrive.
        if (@import("primitive.zig").arity(self.checker, hn.a)) |arity| {
            if (args.items.len < arity) return id;
        }
        if (delta or self.checker.eager_reduce) {
            if (@import("primitive.zig").arity(self.checker, hn.a)) |arity| {
                if (args.items.len == arity) {
                    var values: [2]Expr = undefined;
                    for (args.items, 0..) |arg, i| values[i] = try self.quote(try self.force(arg, true));
                    if (try @import("primitive.zig").reduce(self.checker, hn.a, values[0..arity])) |v| return self.closure(v, 0);
                }
            }
        }
        self.hot.put(m.allocator, n.a, (self.hot.get(n.a) orelse 0) + 1) catch c.oom();
        const d = self.checker.environment.find(n.a) orelse return id;
        if (self.checker.nbe_prefer and args.items.len != 0) {
            const mask = self.erasedArguments(d.*);
            var changed = false;
            for (args.items[0..@min(64, args.items.len)], 0..) |*arg, i| {
                if (mask & (@as(u64, 1) << @intCast(i)) == 0) continue;
                if (self.proof == missing) self.proof = try self.add(.{ .kind = .erased, .a = 0 });
                changed = changed or arg.* != self.proof;
                arg.* = self.proof;
            }
            if (changed) return self.applyMany(head, args.items);
        }
        if (delta and d.kind == .definition) {
            var body = d.value.?;
            var arity: usize = 0;
            while (m.kind(body) == .lam) : (arity += 1) body = m.get(body).b;
            if (arity != 0 and args.items.len > arity) {
                var prefix = head;
                for (args.items[0..arity]) |arg| prefix = try self.app(prefix, arg);
                return self.applyMany(try self.force(prefix, true), args.items[arity..]);
            }
        }
        if (d.kind == .quotient or d.kind == .recursor) {
            if (try self.recursor(id, hn.a, d.*, args.items)) |v| return v;
        }
        if (delta and d.kind == .definition) {
            var body = (try self.checker.unfold(hn.a)) orelse return id;
            if (self.checker.nbe_prefer and (self.hot.get(n.a) orelse 0) >= 8) body = try self.template(hn.a, body);
            return self.applyMany(try self.closure(body, 0), args.items);
        }
        return id;
    }
    // Cache the weak-head simplification of a frequently used lambda body.
    // Fresh typed locals preserve dependencies. Primitive operations stay
    // folded, and an unsuccessful preprocessing probe retains the original
    // body; its small budget never limits evaluation of an actual computation.
    fn template(self: *Machine, function: Expr, body: Expr) Failure!Expr {
        if (self.templates.get(function)) |result| return result;
        self.templates.put(self.checker.expressions.allocator, function, body) catch c.oom();
        const m = self.checker.expressions;
        var variables: c.SmallList(Expr, 16) = .{};
        defer variables.deinit(m.allocator);
        var e = body;
        while (m.kind(e) == .lam and variables.items.len < 16) {
            const n = m.get(e);
            c.append(Expr, &variables, m.allocator, m.fvar(m.instantiateReverse(n.a, variables.items)));
            e = n.b;
        }
        if (m.kind(e) == .lam or variables.items.len == 0) return body;
        const open = m.instantiateReverse(e, variables.items);
        const previous_limit = self.checker.speculation_limit;
        const previous_eager = self.checker.eager_reduce;
        const previous_primitives = self.checker.preserve_primitives;
        self.checker.preserve_primitives = true;
        defer self.checker.preserve_primitives = previous_primitives;
        self.checker.speculation_limit = @min(previous_limit orelse std.math.maxInt(u64), self.checker.ticks +| 2048);
        self.checker.eager_reduce = false;
        defer self.checker.speculation_limit = previous_limit;
        defer self.checker.eager_reduce = previous_eager;
        const normalized = self.checker.whnf(open) catch |err| switch (err) {
            error.ResourceLimit => return err,
            else => return body,
        };
        const result = m.bind(.lam, variables.items, normalized);
        if (m.hasFreeVariables(result)) return body;
        self.templates.put(m.allocator, function, result) catch c.oom();
        return result;
    }
    fn project(self: *Machine, name: u32, field: u32, base: Id, delta: bool) Failure!Id {
        const m = self.checker.expressions;
        var value = try self.force(base, delta);
        const raw = self.nodes.items[value];
        if (raw.kind == .closure and m.kind(raw.a) == .str) value = try self.force(try self.closure(try @import("primitive.zig").expand(self.checker, raw.a), 0), true);
        var args: c.SmallList(Id, 16) = .{};
        defer args.deinit(m.allocator);
        const head = self.nodes.items[self.spine(value, &args)];
        if (head.kind == .closure) {
            const n = m.get(head.a);
            if (n.kind == .cnst) {
                if (self.checker.environment.find(n.a)) |d| {
                    if (d.kind == .ctor and d.details.parent == name and args.items.len == d.details.num_params + d.details.num_fields and field < d.details.num_fields) return self.force(args.items[d.details.num_params + field], delta);
                }
            }
        }
        return self.add(.{ .kind = .proj, .a = name, .b = field, .c = value });
    }
    fn recursor(self: *Machine, id: Id, f: Expr, d: @import("environment.zig").Decl, args: []const Id) Failure!?Id {
        const m = self.checker.expressions;
        const major: usize = if (d.kind == .quotient) switch (d.details.quot_kind) {
            .lift => 5,
            .ind => 4,
            else => return null,
        } else d.details.num_params + d.details.num_motives + d.details.num_minors + d.details.num_indices;
        if (args.len <= major) return null;
        var value = try self.force(args[major], true);
        const raw = self.nodes.items[value];
        if (raw.kind == .closure and (m.kind(raw.a) == .nat or m.kind(raw.a) == .str)) value = try self.force(try self.closure(try @import("primitive.zig").expand(self.checker, raw.a), 0), false);
        var fields: c.SmallList(Id, 16) = .{};
        defer fields.deinit(m.allocator);
        const head = self.nodes.items[self.spine(value, &fields)];
        if (d.kind == .quotient) {
            if (head.kind != .closure) return null;
            const h = m.get(head.a);
            if (h.kind != .cnst or h.a != self.checker.environment.builtin("Quot.mk") or fields.items.len != 3) return null;
            const ctor = self.checker.environment.find(h.a) orelse return null;
            if (ctor.kind != .quotient or ctor.details.quot_kind != .mk) return null;
            const v = try self.app(args[3], fields.items[2]);
            return try self.applyMany(v, args[major + 1 ..]);
        }
        if (!d.details.k and head.kind == .closure) {
            const h = m.get(head.a);
            if (h.kind == .cnst) {
                for (d.details.rules) |rule| {
                    if (h.a != rule.ctor) continue;
                    const ctor = self.checker.environment.find(h.a) orelse return error.InvalidRecursor;
                    if (ctor.kind != .ctor or fields.items.len != ctor.details.num_params + rule.fields) return null;
                    const us = m.get(f).b;
                    if (m.listLen(us) != d.params.len) return error.TypeMismatch;
                    var levels: c.SmallList(u32, 8) = .{};
                    defer levels.deinit(m.allocator);
                    m.listArray(us, &levels);
                    const key = @as(u64, f) | (@as(u64, rule.ctor) << 32);
                    const rhs = if (d.params.len == 0) rule.rhs else self.checker.rule_cache.get(key) orelse blk: {
                        const result = m.substLevels(rule.rhs, d.params, levels.items);
                        self.checker.rule_cache.put(m.allocator, key, result) catch c.oom();
                        break :blk result;
                    };
                    var supplied: c.SmallList(Id, 16) = .{};
                    defer supplied.deinit(m.allocator);
                    for (args[0 .. d.details.num_params + d.details.num_motives + d.details.num_minors]) |arg| c.append(Id, &supplied, m.allocator, arg);
                    for (fields.items[ctor.details.num_params..]) |arg| c.append(Id, &supplied, m.allocator, arg);
                    for (args[major + 1 ..]) |arg| c.append(Id, &supplied, m.allocator, arg);
                    return try self.applyMany(try self.closure(rhs, 0), supplied.items);
                }
            }
        }
        // K reduction and structure eta use type inference in the main kernel.
        // Reuse it rather than introducing a second implementation of those rules.
        const syntax = try self.quote(id);
        var syntax_args: c.SmallList(Expr, 16) = .{};
        defer syntax_args.deinit(m.allocator);
        const syntax_head = m.unfoldApps(syntax, &syntax_args);
        if (try @import("reduction.zig").reduceRecursor(self.checker, syntax_head, syntax_args.items)) |v| return try self.closure(v, 0);
        return null;
    }
    fn quote(self: *Machine, id: Id) Failure!Expr {
        if (self.nodes.items[id].quoted != missing) return self.nodes.items[id].quoted;
        try self.charge();
        self.checker.depth += 1;
        defer self.checker.depth -= 1;
        const n = self.nodes.items[id];
        const m = self.checker.expressions;
        const value = switch (n.kind) {
            .free => unreachable,
            .erased => return error.Fallback,
            .closure => try self.close(n.a, n.b, 0),
            .app => m.app(try self.quote(n.a), try self.quote(n.b)),
            .proj => m.mk(.proj, n.a, n.b, try self.quote(n.c)),
        };
        self.nodes.items[id].quoted = value;
        return value;
    }
    // Stable IDs let live closures keep their memoized values. Intern tables
    // are weak: clear them before reclaiming/recycling nodes and environments.
    // Collection runs only at force safepoints, with every active value rooted.
    fn collect(self: *Machine) void {
        const a = self.checker.expressions.allocator;
        var todo: c.List(Id) = .{};
        defer todo.deinit(a);
        for (self.roots.items) |id| c.append(Id, &todo, a, id);
        if (self.proof != missing) c.append(Id, &todo, a, self.proof);
        const env_bit: u32 = 0x80000000;
        while (todo.pop()) |tag| {
            if (tag & env_bit != 0) {
                const id = (tag & ~env_bit) - 1;
                if (self.bindings.items[id].marked) continue;
                self.bindings.items[id].marked = true;
                const b = self.bindings.items[id];
                if (b.value != missing) c.append(Id, &todo, a, b.value);
                if (b.parent != 0) c.append(Id, &todo, a, b.parent | env_bit);
            } else {
                if (self.nodes.items[tag].marked) continue;
                self.nodes.items[tag].marked = true;
                const n = self.nodes.items[tag];
                switch (n.kind) {
                    .closure => if (n.b != 0) {
                        c.append(Id, &todo, a, n.b | env_bit);
                    },
                    .app => {
                        c.append(Id, &todo, a, n.a);
                        c.append(Id, &todo, a, n.b);
                    },
                    .proj => c.append(Id, &todo, a, n.c),
                    .erased => {},
                    .free => unreachable,
                }
                for (n.result) |v| if (v != missing) {
                    c.append(Id, &todo, a, v);
                };
            }
        }
        self.closures.clearRetainingCapacity();
        self.applications.clearRetainingCapacity();
        self.environments.clearRetainingCapacity();
        self.trimmed.clearRetainingCapacity();
        self.projected.clearRetainingCapacity();
        self.readback.clearRetainingCapacity();
        self.free_nodes.clearRetainingCapacity();
        self.free_bindings.clearRetainingCapacity();
        self.live_nodes = 0;
        self.live_bindings = 0;
        for (self.nodes.items, 0..) |*n, i| {
            const id: Id = @intCast(i);
            if (!n.marked) {
                n.* = .{ .kind = .free, .a = 0 };
                c.append(Id, &self.free_nodes, a, id);
                continue;
            }
            n.marked = false;
            self.live_nodes += 1;
            const key = (@as(u64, n.a) << 32) | n.b;
            switch (n.kind) {
                .closure => self.closures.put(a, key, id) catch c.oom(),
                .app => self.applications.put(a, key, id) catch c.oom(),
                else => {},
            }
        }
        for (self.bindings.items, 0..) |*b, i| {
            const id: Id = @intCast(i + 1);
            if (!b.marked) {
                b.length = 0;
                c.append(Id, &self.free_bindings, a, id);
                continue;
            }
            b.marked = false;
            self.live_bindings += 1;
            self.environments.put(a, (@as(u64, b.parent) << 32) | b.value, id) catch c.oom();
        }
        self.next_collection = @max(262144, (self.live_nodes + self.live_bindings) * 3);
    }
    fn support(self: *Machine, e: Expr) Failure!?u64 {
        const n = self.checker.expressions.get(e);
        if (n.range == 0) return 0;
        if (n.range > 64) return null;
        if (self.supports.get(e)) |mask| return mask;
        try self.charge();
        self.checker.depth += 1;
        defer self.checker.depth -= 1;
        const mask: u64 = switch (n.kind) {
            .bvar => @as(u64, 1) << @intCast(n.a),
            .app => (try self.support(n.a) orelse return null) | (try self.support(n.b) orelse return null),
            .lam, .pi => (try self.support(n.a) orelse return null) | ((try self.support(n.b) orelse return null) >> 1),
            .letE => (try self.support(n.a) orelse return null) | (try self.support(n.b) orelse return null) | ((try self.support(n.c) orelse return null) >> 1),
            .proj => try self.support(n.c) orelse return null,
            else => 0,
        };
        self.supports.put(self.checker.expressions.allocator, e, mask) catch c.oom();
        return mask;
    }
    fn projectEnvironment(self: *Machine, env: Id, mask: u64) Failure!Id {
        if (env == 0 or mask == 0) return 0;
        const key: SupportKey = .{ .environment = env, .mask = mask };
        if (self.projected.get(key)) |value| return value;
        const entry = self.bindings.items[env - 1];
        // Keep de Bruijn positions, but erase slots the complete syntax cannot
        // read (including binder domains and let types). Reading an erased slot
        // fails closed instead of manufacturing a term.
        const parent = try self.projectEnvironment(entry.parent, mask >> 1);
        const value = try self.bind(parent, if (mask & 1 != 0) entry.value else missing);
        self.projected.put(self.checker.expressions.allocator, key, value) catch c.oom();
        return value;
    }
    fn close(self: *Machine, e: Expr, env: Id, depth: u32) Failure!Expr {
        const m = self.checker.expressions;
        const n = m.get(e);
        if (env == 0 or n.range <= depth) return e;
        const key: QuoteKey = .{ .expression = e, .environment = env, .depth = depth };
        if (self.readback.get(key)) |value| return value;
        try self.charge();
        self.checker.depth += 1;
        defer self.checker.depth -= 1;
        const value = switch (n.kind) {
            .bvar => try self.quote(try self.lookup(env, n.a - depth)),
            .app => m.app(try self.close(n.a, env, depth), try self.close(n.b, env, depth)),
            .lam, .pi => m.mk(n.kind, try self.close(n.a, env, depth), try self.close(n.b, env, depth + 1), 0),
            .letE => m.mk(.letE, try self.close(n.a, env, depth), try self.close(n.b, env, depth), try self.close(n.c, env, depth + 1)),
            .proj => m.mk(.proj, n.a, n.b, try self.close(n.c, env, depth)),
            else => e,
        };
        self.readback.put(m.allocator, key, value) catch c.oom();
        return value;
    }
};

test "NbE erases proofs only when the signature fixes their sort to Prop" {
    var levels = @import("level.zig").Pool.init(std.testing.allocator);
    defer levels.deinit();
    var m = @import("expr.zig").Pool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var environment = @import("environment.zig").Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&m, &environment);
    defer checker.deinit();
    var machine: Machine = .{ .checker = &checker };
    defer machine.deinit();
    const prop = m.binder(.pi, m.sort(0), m.binder(.pi, m.bvar(0), m.sort(0)));
    const polymorphic = m.binder(.pi, m.sort(levels.param(environment.named("u"))), m.binder(.pi, m.bvar(0), m.sort(0)));
    try std.testing.expectEqual(@as(u64, 2), machine.erasedArguments(.{ .name = environment.named("proofArgument"), .kind = .axiom, .ty = prop }));
    try std.testing.expectEqual(@as(u64, 0), machine.erasedArguments(.{ .name = environment.named("dataArgument"), .kind = .axiom, .ty = polymorphic }));
    const erased = try machine.add(.{ .kind = .erased, .a = 0 });
    try std.testing.expectError(error.Fallback, machine.force(erased, true));
    try std.testing.expectError(error.Fallback, machine.quote(erased));
}

test "NbE collection clears weak tables before recycling values and environments" {
    var levels = @import("level.zig").Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = @import("expr.zig").Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = @import("environment.zig").Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    checker.nbe_min_work = 0;
    const ty = expressions.sort(levels.succ(0));
    const name = environment.named("identity");
    try environment.add(.{ .name = name, .kind = .definition, .ty = expressions.binder(.pi, ty, ty), .value = expressions.binder(.lam, ty, expressions.bvar(0)) });
    var machine: Machine = .{ .checker = &checker };
    defer machine.deinit();
    for (0..30) |_| {
        const x = expressions.fvar(ty);
        var term = x;
        for (0..40) |_| term = expressions.app(expressions.cnst(name, 0), term);
        machine.next_collection = 8;
        try std.testing.expectEqual(x, try machine.run(term, true));
    }
}
