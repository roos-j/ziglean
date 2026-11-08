// Reconstruct the primitive mutual inductive eliminators from checked constructors.
// No exported type, reduction rule, K flag, or structure flag is trusted.
const std = @import("std");
const environment = @import("environment.zig");
const expr = @import("expr.zig");
const Checker = @import("type_checker.zig").Checker;
const c = @import("common.zig");
const Expr = c.Expr;
const Error = c.Error;
const Info = struct { indices: []const Expr, major: Expr, motive: Expr };
const Ctor = struct { decl: environment.Decl, base: Expr, fields: []const Expr, result: Expr, owner: usize };
/// A recursive target is either a declared type applied to its parameters,
/// or a specialized existing container, such as `List (Tree alpha)`.
const Target = struct { pattern: Expr, type: Expr, parameter_count: u32, index_count: u32, recursor_name: u32, constructors: []const u32 };

test "nested targets match structurally equal raw parameters" {
    const allocator = std.testing.allocator;
    var levels = @import("level.zig").Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    var checker = Checker.init(&expressions, &env);
    defer checker.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var gen: Gen = .{ .checker = &checker, .expressions = &expressions, .allocator = arena.allocator(), .types = &.{}, .ctors = &.{}, .recs = &.{} };
    expressions.temporary = false;
    const list = expressions.cnst(1, expressions.list(&.{}));
    const tree = expressions.cnst(2, expressions.list(&.{}));
    expressions.importing = true;
    const first = expressions.app(list, tree);
    const second = expressions.app(list, tree);
    expressions.importing = false;
    expressions.temporary = true;
    try std.testing.expect(first != second);
    gen.push(Target, &gen.targets, .{ .pattern = expressions.app(list, first), .type = 0, .parameter_count = 1, .index_count = 0, .recursor_name = 0, .constructors = &.{} });
    try std.testing.expectEqual(@as(?usize, 0), try gen.validApp(expressions.app(list, second)));
    try std.testing.expectEqual(@as(?usize, null), try gen.validApp(expressions.app(list, list)));
}

const Gen = struct {
    checker: *Checker,
    expressions: *expr.Pool,
    allocator: std.mem.Allocator,
    types: []const environment.Decl,
    ctors: []const environment.Decl,
    recs: []const environment.Decl,
    params: c.List(Expr) = .{},
    targets: c.List(Target) = .{},
    infos: c.List(Info) = .{},
    cs: c.List(Ctor) = .{},
    motives: c.List(Expr) = .{},
    minors: c.List(Expr) = .{},
    levels: u32 = 0,
    result_level: u32 = 0,
    elim_level: u32 = 0,
    np: u32 = 0,
    recursive: bool = false,
    reflexive: bool = false,
    k: bool = false,
    fn push(self: *Gen, comptime T: type, l: *c.List(T), v: T) void {
        c.append(T, l, self.allocator, v);
    }
    fn idx(self: *Gen, n: u32) ?usize {
        for (self.types, 0..) |d, i| {
            if (d.name == n) return i;
        }
        return null;
    }
    fn occurs(self: *Gen, e: Expr) bool {
        const n = self.expressions.get(e);
        return switch (n.kind) {
            .cnst => self.idx(n.a) != null,
            .app, .lam, .pi => self.occurs(n.a) or self.occurs(n.b),
            .letE => self.occurs(n.a) or self.occurs(n.b) or self.occurs(n.c),
            .proj => self.occurs(n.c),
            else => false,
        };
    }
    fn uniform(self: *Gen, e: Expr, depth: u32) Error!void {
        const m = self.expressions;
        const n = m.get(e);
        if (n.kind == .app or n.kind == .cnst) {
            var aa: c.List(Expr) = .{};
            const h = m.get(m.unfoldApps(e, &aa));
            defer aa.deinit(m.allocator);
            if (h.kind == .cnst and self.idx(h.a) != null) {
                if (aa.items.len < self.np or h.b != self.levels or depth < self.np) return error.InvalidInductive;
                for (aa.items[0..self.np], 0..) |arg, i| {
                    const v = m.get(arg);
                    if (v.kind != .bvar or v.a != depth - 1 - i) return error.InvalidInductive;
                }
                for (aa.items[self.np..]) |arg| try self.uniform(arg, depth);
                return;
            }
        }
        switch (n.kind) {
            .app => {
                try self.uniform(n.a, depth);
                try self.uniform(n.b, depth);
            },
            .lam, .pi => {
                try self.uniform(n.a, depth);
                try self.uniform(n.b, depth + 1);
            },
            .letE => {
                try self.uniform(n.a, depth);
                try self.uniform(n.b, depth);
                try self.uniform(n.c, depth + 1);
            },
            .proj => try self.uniform(n.c, depth),
            else => {},
        }
    }
    // Imported composite expressions are not hash-consed. Nested parameters
    // must therefore be compared structurally, even when both are closed.
    fn samePattern(self: *Gen, left: Expr, right: Expr) Error!bool {
        if (left == right) return true;
        try self.checker.tick();
        const a = self.expressions.get(left);
        const b = self.expressions.get(right);
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .app, .lam, .pi => try self.samePattern(a.a, b.a) and try self.samePattern(a.b, b.b),
            .letE => try self.samePattern(a.a, b.a) and try self.samePattern(a.b, b.b) and try self.samePattern(a.c, b.c),
            .proj => a.a == b.a and a.b == b.b and try self.samePattern(a.c, b.c),
            else => a.a == b.a and a.b == b.b and a.c == b.c,
        };
    }
    fn validApp(self: *Gen, expression: Expr) Error!?usize {
        var arguments: c.List(Expr) = .{};
        defer arguments.deinit(self.expressions.allocator);
        const head = self.expressions.unfoldApps(expression, &arguments);
        for (self.targets.items, 0..) |target, index| {
            if (arguments.items.len != target.parameter_count + target.index_count) continue;
            if (!try self.samePattern(self.expressions.apps(head, arguments.items[0..target.parameter_count]), target.pattern)) continue;
            for (arguments.items[target.parameter_count..]) |argument| {
                if (self.occurs(argument)) return error.InvalidInductive;
            }
            return index;
        }
        if (self.idx(self.expressions.get(head).a) != null and self.expressions.kind(head) == .cnst) return error.InvalidInductive;
        return null;
    }

    fn onlyParameters(self: *Gen, expression: Expr) bool {
        const node = self.expressions.get(expression);
        return switch (node.kind) {
            .fvar => std.mem.indexOfScalar(Expr, self.params.items, expression) != null,
            .app, .lam, .pi => self.onlyParameters(node.a) and self.onlyParameters(node.b),
            .letE => self.onlyParameters(node.a) and self.onlyParameters(node.b) and self.onlyParameters(node.c),
            .proj => self.onlyParameters(node.c),
            else => true,
        };
    }

    fn discoverNested(self: *Gen, expression: Expr) Error!bool {
        var arguments: c.List(Expr) = .{};
        defer arguments.deinit(self.expressions.allocator);
        const head = self.expressions.get(self.expressions.unfoldApps(expression, &arguments));
        if (head.kind != .cnst or self.idx(head.a) != null) return false;
        const container = self.checker.environment.find(head.a) orelse return false;
        if (container.kind != .inductive or arguments.items.len != container.num_params + container.num_indices) return false;
        const parameters = arguments.items[0..container.num_params];
        var nested = false;
        for (parameters) |parameter| {
            if (!self.onlyParameters(parameter) or self.expressions.get(parameter).range != 0) return error.InvalidInductive;
            nested = nested or self.occurs(parameter);
        }
        if (!nested) return false;
        for (arguments.items[container.num_params..]) |index| {
            if (self.occurs(index)) return error.InvalidInductive;
        }
        // Copy the whole previously checked mutual family, in declaration order.
        for (container.all) |name| {
            const declaration = self.checker.environment.find(name) orelse return error.InvalidInductive;
            const pattern = self.expressions.apps(self.expressions.cnst(name, head.b), parameters);
            const body_type = try self.checker.infer(pattern, true);
            const telescope_ = try self.telescope(body_type);
            if (self.expressions.kind(telescope_.result) != .sort or !self.expressions.levels.equal(self.expressions.get(telescope_.result).a, self.result_level)) return error.InvalidInductive;
            const suffix = std.fmt.allocPrint(self.allocator, "rec_{d}", .{self.targets.items.len - self.types.len + 1}) catch c.oom();
            self.push(Target, &self.targets, .{
                .pattern = pattern,
                .type = body_type,
                .parameter_count = declaration.num_params,
                .index_count = declaration.num_indices,
                .recursor_name = self.checker.environment.child(self.types[0].name, suffix),
                .constructors = declaration.ctors,
            });
        }
        return true;
    }
    fn positive(self: *Gen, e: Expr) Error!void {
        const checker = try self.checker.whnf(e);
        if (!self.occurs(checker)) return;
        const n = self.expressions.get(checker);
        if (n.kind == .pi) {
            if (self.occurs(n.a)) return error.InvalidInductive;
            try self.positive(self.expressions.inst(n.b, self.expressions.fvar(n.a)));
            return;
        }
        if (try self.validApp(checker) == null and !try self.discoverNested(checker)) return error.InvalidInductive;
    }
    fn recArg(self: *Gen, e: Expr, xs: *c.List(Expr)) Error!?usize {
        var checker = try self.checker.whnf(e);
        while (self.expressions.kind(checker) == .pi) {
            const n = self.expressions.get(checker);
            const x = self.expressions.fvar(n.a);
            self.push(Expr, xs, x);
            checker = try self.checker.whnf(self.expressions.inst(n.b, x));
        }
        return self.validApp(checker);
    }
    fn indices(self: *Gen, e: Expr) c.List(Expr) {
        var aa: c.List(Expr) = .{};
        _ = self.expressions.unfoldApps(e, &aa);
        return aa;
    }
    fn telescope(self: *Gen, ty: Expr) Error!struct { vars: []const Expr, result: Expr } {
        var r = ty;
        var vars: c.List(Expr) = .{};
        while (self.expressions.kind(try self.checker.whnf(r)) == .pi) {
            const n = self.expressions.get(try self.checker.whnf(r));
            const x = self.expressions.fvar(n.a);
            self.push(Expr, &vars, x);
            r = self.expressions.inst(n.b, x);
        }
        return .{ .vars = vars.items, .result = try self.checker.whnf(r) };
    }
    fn checkTypes(self: *Gen) Error!void {
        const m = self.expressions;
        const checker = self.checker;
        self.np = self.types[0].num_params;
        checker.params = self.types[0].params;
        var ls: c.List(u32) = .{};
        for (checker.params, 0..) |p, i| {
            if (std.mem.indexOfScalar(u32, checker.params[0..i], p) != null) return error.UndeclaredUniverse;
            self.push(u32, &ls, m.levels.param(p));
        }
        self.levels = m.list(ls.items);
        for (self.types, 0..) |d, i| {
            if (d.unsafe_) return error.UnsafeDeclaration;
            if (d.num_params != self.np or !std.mem.eql(u32, d.params, checker.params)) return error.InvalidInductive;
            if (checker.environment.find(d.name) != null or checker.environment.find(checker.environment.child(d.name, "rec")) != null) return error.DuplicateDeclaration;
            for (self.types[0..i]) |prev| {
                if (prev.name == d.name) return error.DuplicateDeclaration;
            }
            if (d.all.len != self.types.len) return error.InvalidInductive;
            for (d.all, self.types) |x, y| {
                if (x != y.name) return error.InvalidInductive;
            }
            _ = try checker.ensure(try checker.infer(d.ty, true), .sort);
            var r = try checker.whnf(d.ty);
            var count: u32 = 0;
            while (m.kind(r) == .pi) {
                const n = m.get(r);
                var x: Expr = undefined;
                if (count < self.np) {
                    if (i == 0) {
                        x = m.fvar(n.a);
                        self.push(Expr, &self.params, x);
                    } else {
                        x = self.params.items[count];
                        if (!try checker.defeq(n.a, m.get(x).a)) return error.InvalidInductive;
                    }
                } else x = m.fvar(n.a);
                r = try checker.whnf(m.inst(n.b, x));
                count += 1;
            }
            if (count < self.np or count - self.np != d.num_indices or m.kind(r) != .sort) return error.InvalidInductive;
            if (i == 0) self.result_level = m.get(r).a else if (!m.levels.equal(self.result_level, m.get(r).a)) return error.InvalidInductive;
        }
        for (self.ctors) |d| try self.uniform(d.ty, 0);
        for (self.types) |d| {
            var safe = d;
            safe.recursive = true;
            safe.reflexive = false;
            try checker.environment.add(safe);
        }
        checker.clearCaches();
        for (self.types) |declaration| {
            const pattern = m.apps(m.cnst(declaration.name, self.levels), self.params.items);
            self.push(Target, &self.targets, .{
                .pattern = pattern,
                .type = try checker.infer(pattern, true),
                .parameter_count = self.np,
                .index_count = declaration.num_indices,
                .recursor_name = checker.environment.child(declaration.name, "rec"),
                .constructors = declaration.ctors,
            });
        }
    }
    fn checkCtors(self: *Gen) Error!void {
        const m = self.expressions;
        const checker = self.checker;
        var consumed: usize = 0;
        for (self.types, 0..) |ind, owner| {
            for (ind.ctors, 0..) |name, ci| {
                var found: ?environment.Decl = null;
                for (self.ctors) |candidate| {
                    if (candidate.name == name) {
                        if (found != null) return error.DuplicateDeclaration;
                        found = candidate;
                    }
                }
                const d = found orelse return error.InvalidInductive;
                if (d.unsafe_) return error.UnsafeDeclaration;
                if (d.parent != ind.name or d.ctor_index != ci or d.num_params != self.np or !std.mem.eql(u32, d.params, checker.params)) return error.InvalidInductive;
                if (checker.environment.find(d.name) != null) return error.DuplicateDeclaration;
                for (self.cs.items) |prev| {
                    if (prev.decl.name == d.name) return error.DuplicateDeclaration;
                }
                _ = try checker.ensure(try checker.infer(d.ty, true), .sort);
                var r = d.ty;
                var count: u32 = 0;
                var fields: c.List(Expr) = .{};
                while (m.kind(r) == .pi) {
                    const n = m.get(r);
                    var x: Expr = undefined;
                    if (count < self.np) {
                        x = self.params.items[count];
                        if (!try checker.defeq(n.a, m.get(x).a)) return error.InvalidInductive;
                    } else {
                        const sort = m.get(try checker.ensure(try checker.infer(n.a, true), .sort));
                        if (!m.levels.equal(self.result_level, 0) and !m.levels.geq(self.result_level, sort.a)) return error.InvalidInductive;
                        try self.positive(n.a);
                        if (self.occurs(n.a)) {
                            self.recursive = true;
                            if (m.kind(n.a) == .pi) self.reflexive = true;
                        }
                        x = m.fvar(n.a);
                        self.push(Expr, &fields, x);
                    }
                    r = m.inst(n.b, x);
                    count += 1;
                }
                if (count < self.np or fields.items.len != d.num_fields or (try self.validApp(r) orelse return error.InvalidInductive) != owner) return error.InvalidInductive;
                self.push(Ctor, &self.cs, .{ .decl = d, .base = m.apps(m.cnst(d.name, self.levels), self.params.items), .fields = fields.items, .result = r, .owner = owner });
                consumed += 1;
            }
        }
        if (consumed != self.ctors.len) return error.InvalidInductive;
        var target_index = self.types.len;
        while (target_index < self.targets.items.len) : (target_index += 1) {
            const target = self.targets.items[target_index];
            var parameters: c.List(Expr) = .{};
            defer parameters.deinit(m.allocator);
            const head = m.get(m.unfoldApps(target.pattern, &parameters));
            for (target.constructors) |name| {
                const declaration = checker.environment.find(name) orelse return error.InvalidInductive;
                const base = m.apps(m.cnst(name, head.b), parameters.items);
                var constructor_type = try checker.infer(base, true);
                var fields: c.List(Expr) = .{};
                while (m.kind(constructor_type) == .pi) {
                    const node = m.get(constructor_type);
                    const sort = m.get(try checker.ensure(try checker.infer(node.a, true), .sort));
                    if (!m.levels.equal(self.result_level, 0) and !m.levels.geq(self.result_level, sort.a)) return error.InvalidInductive;
                    try self.positive(node.a);
                    if (self.occurs(node.a)) {
                        self.recursive = true;
                        if (m.kind(node.a) == .pi) self.reflexive = true;
                    }
                    const variable = m.fvar(node.a);
                    self.push(Expr, &fields, variable);
                    constructor_type = m.inst(node.b, variable);
                }
                if ((try self.validApp(constructor_type) orelse return error.InvalidInductive) != target_index or fields.items.len != declaration.num_fields) return error.InvalidInductive;
                self.push(Ctor, &self.cs, .{ .decl = declaration.*, .base = base, .fields = fields.items, .result = constructor_type, .owner = target_index });
            }
        }
        for (self.types) |d| {
            if (d.nested != self.targets.items.len - self.types.len) return error.InvalidInductive;
            if (d.recursive != self.recursive or d.reflexive != self.reflexive) return error.InvalidInductive;
            checker.environment.update(d);
        }
        for (self.cs.items) |ctor| {
            if (ctor.owner < self.types.len) try checker.environment.add(ctor.decl);
        }
        checker.clearCaches();
    }
    fn propOnly(self: *Gen) Error!bool {
        if (self.expressions.levels.nonzero(self.result_level)) return false;
        if (self.targets.items.len > 1 or self.cs.items.len > 1) return true;
        if (self.cs.items.len == 0) return false;
        const ctor = self.cs.items[0];
        var aa = self.indices(ctor.result);
        defer aa.deinit(self.expressions.allocator);
        for (ctor.fields) |f| {
            if (!try self.checker.isProp(self.expressions.get(f).a) and std.mem.indexOfScalar(Expr, aa.items, f) == null) return true;
        }
        return false;
    }
    fn makeInfos(self: *Gen) Error!void {
        const m = self.expressions;
        for (self.targets.items) |target| {
            const tel = try self.telescope(target.type);
            const major = m.fvar(m.apps(target.pattern, tel.vars));
            const mt = m.bind(.pi, tel.vars, m.bind(.pi, &.{major}, m.sort(self.elim_level)));
            const motive = m.fvar(mt);
            self.push(Info, &self.infos, .{ .indices = tel.vars, .major = major, .motive = motive });
            self.push(Expr, &self.motives, motive);
        }
        for (self.cs.items) |ctor| {
            var aa = self.indices(ctor.result);
            defer aa.deinit(m.allocator);
            const ca = m.apps(ctor.base, ctor.fields);
            const result = m.app(m.apps(self.motives.items[ctor.owner], aa.items[self.targets.items[ctor.owner].parameter_count..]), ca);
            var ihs: c.List(Expr) = .{};
            for (ctor.fields) |f| {
                var xs: c.List(Expr) = .{};
                if (try self.recArg(m.get(f).a, &xs)) |owner| {
                    const applied = m.apps(f, xs.items);
                    const fty = try self.checker.whnf(try self.checker.infer(applied, false));
                    var ix = self.indices(fty);
                    defer ix.deinit(m.allocator);
                    const ih = m.bind(.pi, xs.items, m.app(m.apps(self.motives.items[owner], ix.items[self.targets.items[owner].parameter_count..]), applied));
                    self.push(Expr, &ihs, m.fvar(ih));
                }
            }
            const minor = m.fvar(m.bind(.pi, ctor.fields, m.bind(.pi, ihs.items, result)));
            self.push(Expr, &self.minors, minor);
        }
    }
    fn findRec(self: *Gen, name: u32) Error!environment.Decl {
        var found: ?environment.Decl = null;
        for (self.recs) |r| {
            if (r.name == name) {
                if (found != null) return error.DuplicateDeclaration;
                found = r;
            }
        }
        return found orelse error.InvalidRecursor;
    }
    fn generate(self: *Gen) Error!void {
        const m = self.expressions;
        const checker = self.checker;
        if (self.recs.len != self.targets.items.len) return error.InvalidRecursor;
        const only = try self.propOnly();
        const first = try self.findRec(checker.environment.child(self.types[0].name, "rec"));
        if (only) {
            if (!std.mem.eql(u32, first.params, checker.params)) return error.InvalidRecursor;
            self.elim_level = 0;
        } else {
            if (first.params.len != checker.params.len + 1 or !std.mem.eql(u32, first.params[1..], checker.params) or std.mem.indexOfScalar(u32, checker.params, first.params[0]) != null) return error.InvalidRecursor;
            self.elim_level = m.levels.param(first.params[0]);
        }
        self.k = self.targets.items.len == 1 and m.levels.equal(self.result_level, 0) and self.cs.items.len == 1 and self.cs.items[0].fields.len == 0;
        try self.makeInfos();
        var rlevels: c.List(u32) = .{};
        for (first.params) |p| self.push(u32, &rlevels, m.levels.param(p));
        const rls = m.list(rlevels.items);
        var generated: c.List(environment.Decl) = .{};
        for (self.targets.items, self.infos.items, 0..) |target_info, info, owner| {
            const d = try self.findRec(target_info.recursor_name);
            if (d.unsafe_ or d.num_params != self.np or d.num_indices != info.indices.len or d.num_motives != self.targets.items.len or d.num_minors != self.cs.items.len or d.k != self.k or !std.mem.eql(u32, d.params, first.params) or !std.mem.eql(u32, d.all, self.types[0].all)) return error.InvalidRecursor;
            var ty = m.app(m.apps(info.motive, info.indices), info.major);
            ty = m.bind(.pi, self.params.items, m.bind(.pi, self.motives.items, m.bind(.pi, self.minors.items, m.bind(.pi, info.indices, m.bind(.pi, &.{info.major}, ty)))));
            var rules: c.List(environment.Rule) = .{};
            for (self.cs.items, 0..) |ctor, ci| {
                if (ctor.owner != owner) continue;
                var ihs: c.List(Expr) = .{};
                for (ctor.fields) |f| {
                    var xs: c.List(Expr) = .{};
                    if (try self.recArg(m.get(f).a, &xs)) |target| {
                        const applied = m.apps(f, xs.items);
                        const fty = try checker.whnf(try checker.infer(applied, false));
                        var ix = self.indices(fty);
                        defer ix.deinit(m.allocator);
                        var call = m.cnst(self.targets.items[target].recursor_name, rls);
                        call = m.apps(m.apps(m.apps(m.apps(call, self.params.items), self.motives.items), self.minors.items), ix.items[self.targets.items[target].parameter_count..]);
                        self.push(Expr, &ihs, m.bind(.lam, xs.items, m.app(call, applied)));
                    }
                }
                const body = m.apps(m.apps(self.minors.items[ci], ctor.fields), ihs.items);
                const rhs = m.bind(.lam, self.params.items, m.bind(.lam, self.motives.items, m.bind(.lam, self.minors.items, m.bind(.lam, ctor.fields, body))));
                self.push(environment.Rule, &rules, .{ .ctor = ctor.decl.name, .fields = ctor.decl.num_fields, .rhs = rhs });
            }
            var safe = d;
            safe.ty = ty;
            safe.rules = rules.items;
            self.push(environment.Decl, &generated, safe);
        }
        // Install only derived recursors while comparing the untrusted exports.
        for (generated.items) |d| try checker.environment.add(d);
        checker.params = first.params;
        checker.clearCaches();
        for (generated.items) |safe| {
            const d = try self.findRec(safe.name);
            _ = try checker.ensure(try checker.infer(d.ty, true), .sort);
            if (!try checker.defeq(d.ty, safe.ty) or d.rules.len != safe.rules.len) return error.InvalidRecursor;
            for (d.rules, safe.rules) |actual, expected| {
                if (actual.ctor != expected.ctor or actual.fields != expected.fields) return error.InvalidRecursor;
                // Compare with the independently generated rule, not just its type.
                // Only generated rules are installed during this conversion.
                _ = try checker.infer(actual.rhs, true);
                if (!try checker.defeq(actual.rhs, expected.rhs)) return error.InvalidRecursor;
            }
        }
        for (self.recs) |d| checker.environment.update(d);
        checker.clearCaches();
    }
};
pub fn check(checker: *Checker, types: []const environment.Decl, ctors: []const environment.Decl, recs: []const environment.Decl) Error!void {
    var arena = std.heap.ArenaAllocator.init(checker.expressions.allocator);
    defer arena.deinit();
    var self = Gen{ .checker = checker, .expressions = checker.expressions, .allocator = arena.allocator(), .types = types, .ctors = ctors, .recs = recs };
    try self.checkTypes();
    try self.checkCtors();
    try self.generate();
}
