//! Validated streaming import of lean4export names, universes, terms, and declarations.
const std = @import("std");
const c = @import("common.zig");
const ExprPool = @import("expr.zig").Pool;
const ExprKind = @import("expr.zig").Kind;
const environment = @import("environment.zig");
const Checker = @import("type_checker.zig").Checker;
const parallel = @import("parallel.zig");
const J = std.json.Value;
fn field(j: J, key: []const u8) c.Error!J {
    if (j != .object) return error.InvalidInput;
    return j.object.get(key) orelse error.InvalidInput;
}
fn num(j: J) c.Error!u32 {
    if (j == .number_string) return std.fmt.parseInt(u32, j.number_string, 10) catch error.InvalidInput;
    if (j != .integer or j.integer < 0 or j.integer > std.math.maxInt(u32)) return error.InvalidInput;
    return @intCast(j.integer);
}
fn text(j: J) c.Error![]const u8 {
    if (j != .string) return error.InvalidInput;
    return j.string;
}
fn boolean(j: J) c.Error!bool {
    if (j != .bool) return error.InvalidInput;
    return j.bool;
}
fn array(j: J) c.Error![]J {
    if (j != .array) return error.InvalidInput;
    return j.array.items;
}
const Refs = struct {
    dense: c.List(u32) = .{},
    sparse: std.AutoHashMapUnmanaged(u32, u32) = .{},
    fn deinit(r: *Refs, a: std.mem.Allocator) void {
        r.dense.deinit(a);
        r.sparse.deinit(a);
    }
    fn add(r: *Refs, a: std.mem.Allocator, id: u32, value: u32) c.Error!void {
        if (id < r.dense.items.len or r.sparse.contains(id)) return error.InvalidInput;
        if (id == r.dense.items.len) c.append(u32, &r.dense, a, value) else r.sparse.put(a, id, value) catch c.oom();
    }
    fn get(r: *const Refs, id: u32) c.Error!u32 {
        if (id < r.dense.items.len) return r.dense.items[id];
        return r.sparse.get(id) orelse error.InvalidInput;
    }
};
pub const Importer = struct {
    expressions: *ExprPool,
    environment: *environment.Environment,
    names: Refs = .{},
    levels: Refs = .{},
    exprs: @import("import_refs.zig").Refs = .{},
    lines: u64 = 0,
    declarations: u64 = 0,
    header: bool = false,
    last_name: u32 = 0,
    max_ticks: u64 = 100_000_000,
    max_temporary_nodes: u32 = 64_000_000,
    profile: bool = false,
    check_ns: u64 = 0,
    checker: ?Checker = null,
    threads: u8 = 1,
    batch_size: u32 = 8192,
    tasks: c.List(parallel.Task) = .{},
    last_expression_count: usize = 0,
    active: c.List(*parallel.Job) = .{},
    workers: ?*std.Thread.Pool = null,
    completion: std.Thread.Semaphore = .{},
    pub fn init(m: *ExprPool, env: *environment.Environment) Importer {
        var self: Importer = .{ .expressions = m, .environment = env };
        self.names.add(m.allocator, 0, 0) catch unreachable;
        self.levels.add(m.allocator, 0, 0) catch unreachable;
        return self;
    }
    pub fn deinit(self: *Importer) void {
        for (self.active.items) |job| job.deinit();
        self.active.deinit(self.expressions.allocator);
        if (self.workers) |workers| {
            workers.deinit();
            self.expressions.allocator.destroy(workers);
        }
        if (self.checker) |*checker| checker.deinit();
        self.names.deinit(self.expressions.allocator);
        self.levels.deinit(self.expressions.allocator);
        self.exprs.deinit(self.expressions.allocator);
        self.tasks.deinit(self.expressions.allocator);
    }
    fn waitActive(self: *Importer, index: usize) c.Error!void {
        if (self.active.items.len == 0) return;
        const job = self.active.orderedRemove(index);
        defer {
            job.deinit();
        }
        job.join();
        self.check_ns += job.elapsed_ns;
        if (self.profile) {
            var total: u64 = 0;
            var slowest: ?parallel.Task = null;
            for (job.tasks.items) |task| {
                total += task.elapsed_ns;
                if (slowest == null or task.elapsed_ns > slowest.?.elapsed_ns) slowest = task;
            }
            if (slowest) |task| {
                std.debug.print("batch: work {d:.3}s; longest {d:.3}s ", .{ @as(f64, @floatFromInt(total)) / 1e9, @as(f64, @floatFromInt(task.elapsed_ns)) / 1e9 });
                self.environment.printName(task.name);
                std.debug.print("\n", .{});
            }
        }
        for (job.tasks.items) |task| {
            if (task.failure) |err| {
                self.last_name = task.name;
                self.lines = task.line;
                return err;
            }
        }
    }
    fn launch(self: *Importer) c.Error!void {
        if (!self.expressions.global.virtual) return self.finishSync();
        if (self.tasks.items.len == 0) return;
        // Reclaim completed jobs in any order. A slow declaration in the
        // oldest batch must not block importing new work when later batches
        // have already finished and released their workers.
        while (true) {
            var index: usize = 0;
            while (index < self.active.items.len) {
                if (self.active.items[index].remaining.load(.acquire) == 0) {
                    try self.waitActive(index);
                } else index += 1;
            }
            if (self.active.items.len < 4) break;
            self.completion.wait();
        }
        if (self.workers == null) {
            const workers = self.expressions.allocator.create(std.Thread.Pool) catch c.oom();
            workers.init(.{ .allocator = self.expressions.allocator, .n_jobs = self.threads, .stack_size = 128 * 1024 * 1024 }) catch {
                self.expressions.allocator.destroy(workers);
                return error.ResourceLimit;
            };
            self.workers = workers;
        }
        std.mem.sort(parallel.Task, self.tasks.items, {}, struct {
            fn heavier(_: void, left: parallel.Task, right: parallel.Task) bool {
                return left.weight > right.weight;
            }
        }.heavier);
        const job = parallel.Job.create(self.expressions, self.environment, self.tasks, self.threads, self.max_ticks, self.max_temporary_nodes, &self.completion);
        self.tasks = .{};
        c.append(*parallel.Job, &self.active, self.expressions.allocator, job);
        job.batch.profile = self.profile;
        job.start(self.workers.?);
    }
    pub fn finish(self: *Importer) c.Error!void {
        try self.launch();
        while (self.active.items.len != 0) try self.waitActive(0);
    }
    fn finishSync(self: *Importer) c.Error!void {
        if (self.tasks.items.len == 0) return;
        std.mem.sort(parallel.Task, self.tasks.items, {}, struct {
            fn heavier(_: void, left: parallel.Task, right: parallel.Task) bool {
                return left.weight > right.weight;
            }
        }.heavier);
        var timer = if (self.profile) std.time.Timer.start() catch unreachable else undefined;
        defer if (self.profile) {
            self.check_ns += timer.read();
        };
        var batch: parallel.Batch = .{
            .expressions = self.expressions,
            .environment = self.environment,
            .tasks = self.tasks.items,
            .max_ticks = self.max_ticks,
            .max_temporary_nodes = self.max_temporary_nodes,
        };
        try batch.run(self.threads);
        for (self.tasks.items) |task| {
            if (task.failure) |err| {
                self.last_name = task.name;
                self.lines = task.line;
                return err;
            }
        }
        self.tasks.clearRetainingCapacity();
    }

    fn enqueue(self: *Importer, j: J) c.Error!void {
        const allocator = self.expressions.allocator;
        const first: u32 = @intCast(self.environment.decls.items.len);
        if (j.object.get("inductive")) |group| {
            var types: c.List(environment.Decl) = .{};
            defer types.deinit(allocator);
            var ctors: c.List(environment.Decl) = .{};
            defer ctors.deinit(allocator);
            var recs: c.List(environment.Decl) = .{};
            defer recs.deinit(allocator);
            for (try array(try field(group, "types"))) |decl_| c.append(environment.Decl, &types, allocator, try self.decl(decl_, .inductive));
            for (try array(try field(group, "ctors"))) |decl_| c.append(environment.Decl, &ctors, allocator, try self.decl(decl_, .ctor));
            for (try array(try field(group, "recs"))) |decl_| c.append(environment.Decl, &recs, allocator, try self.decl(decl_, .recursor));
            if (types.items.len == 0) return error.InvalidInductive;
            for (types.items) |decl_| try self.environment.add(decl_);
            for (ctors.items) |decl_| try self.environment.add(decl_);
            for (recs.items) |decl_| try self.environment.add(decl_);
            self.last_name = types.items[0].name;
            c.append(parallel.Task, &self.tasks, allocator, .{ .first = first, .line = self.lines, .name = self.last_name, .body = .{ .inductive = .{
                .types = self.environment.copy(environment.Decl, types.items),
                .ctors = self.environment.copy(environment.Decl, ctors.items),
                .recs = self.environment.copy(environment.Decl, recs.items),
            } } });
            self.declarations += types.items.len + ctors.items.len + recs.items.len;
        } else {
            var found = false;
            inline for (.{ "axiom", "def", "thm", "opaque", "quot" }, .{ environment.DeclKind.axiom, environment.DeclKind.definition, environment.DeclKind.theorem, environment.DeclKind.opaque_decl, environment.DeclKind.quotient }) |key_, kind_| {
                if (j.object.get(key_)) |value| {
                    const decl_ = try self.decl(value, kind_);
                    self.last_name = decl_.name;
                    try self.environment.add(decl_);
                    c.append(parallel.Task, &self.tasks, allocator, .{ .first = first, .line = self.lines, .name = decl_.name, .body = .single });
                    self.declarations += 1;
                    found = true;
                }
            }
            if (!found) return error.InvalidInput;
        }
        const expression_count = self.exprs.count();
        self.tasks.items[self.tasks.items.len - 1].weight = expression_count - self.last_expression_count;
        self.last_expression_count = expression_count;
        const target = @max(self.batch_size, @min(65536, self.declarations / 8));
        if (self.tasks.items.len >= target) try self.launch();
    }
    fn nameRef(self: *Importer, j: J) c.Error!u32 {
        return self.names.get(try num(j));
    }
    fn numericName(self: *Importer, prefix: u32, value: J) c.Error!u32 {
        var buffer: [20]u8 = undefined;
        const digits = switch (value) {
            .integer => if (value.integer >= 0) std.fmt.bufPrint(&buffer, "{d}", .{value.integer}) catch unreachable else return error.InvalidInput,
            .number_string => value.number_string,
            else => return error.InvalidInput,
        };
        if (digits.len == 0) return error.InvalidInput;
        for (digits) |digit| if (digit < '0' or digit > '9') return error.InvalidInput;
        var first: usize = 0;
        while (first + 1 < digits.len and digits[first] == '0') : (first += 1) {}
        return self.environment.name(prefix, self.environment.string(digits[first..]), true);
    }
    fn levelRef(self: *Importer, j: J) c.Error!u32 {
        return self.levels.get(try num(j));
    }
    fn exprRef(self: *Importer, j: J) c.Error!u32 {
        return self.exprs.get(try num(j));
    }
    pub fn lineBytes(self: *Importer, allocator: std.mem.Allocator, bytes: []const u8) c.Error!void {
        if (@import("scan.zig").scan(bytes)) |record| return self.scanned(record, bytes);
        const parsed = std.json.parseFromSlice(J, allocator, bytes, .{ .allocate = .alloc_if_needed, .parse_numbers = false, .max_value_len = 256 * 1024 * 1024 }) catch return error.InvalidInput;
        defer parsed.deinit();
        return self.line(parsed.value);
    }

    inline fn scanned(self: *Importer, record: @import("scan.zig").Record, bytes: []const u8) c.Error!void {
        self.lines += 1;
        if (!self.header) return error.InvalidInput;
        const m = self.expressions;
        m.importing = true;
        defer m.importing = false;
        switch (record.kind) {
            .name_str, .name_num => {
                const prefix = try self.names.get(record.a);
                var buffer: [10]u8 = undefined;
                const value = if (record.kind == .name_str) self.environment.child(prefix, bytes[record.b..record.c]) else self.environment.name(prefix, self.environment.string(std.fmt.bufPrint(&buffer, "{d}", .{record.b}) catch unreachable), true);
                return self.names.add(m.allocator, record.id, value);
            },
            .succ, .param, .max, .imax => {
                const value = switch (record.kind) {
                    .succ => m.levels.succ(try self.levels.get(record.a)),
                    .param => m.levels.param(try self.names.get(record.a)),
                    .max => m.levels.max(try self.levels.get(record.a), try self.levels.get(record.b)),
                    .imax => m.levels.imax(try self.levels.get(record.a), try self.levels.get(record.b)),
                    else => unreachable,
                };
                return self.levels.add(m.allocator, record.id, value);
            },
            else => {},
        }
        const value = switch (record.kind) {
            .app => m.app(try self.exprs.get(record.a), try self.exprs.get(record.b)),
            .bvar => if (record.a == std.math.maxInt(u32)) return error.InvalidInput else m.bvar(record.a),
            .sort => m.sort(try self.levels.get(record.a)),
            .cnst => blk: {
                const name = try self.names.get(record.a);
                var universes: [16]u32 = undefined;
                for (record.universes[0..record.universe_count], 0..) |id, index| universes[index] = try self.levels.get(id);
                break :blk m.cnst(name, m.list(universes[0..record.universe_count]));
            },
            inline .lam, .pi => |kind| blk: {
                _ = try self.names.get(record.c);
                break :blk m.binder(if (kind == .lam) .lam else .pi, try self.exprs.get(record.a), try self.exprs.get(record.b));
            },
            .proj => m.mk(.proj, try self.names.get(record.a), record.b, try self.exprs.get(record.c)),
            .letE => blk: {
                _ = try self.names.get(record.d);
                break :blk m.mk(.letE, try self.exprs.get(record.a), try self.exprs.get(record.b), try self.exprs.get(record.c));
            },
            else => unreachable,
        };
        try self.exprs.add(m.allocator, record.id, value);
    }
    fn nameRefs(self: *Importer, j: J) c.Error![]const u32 {
        var r: c.List(u32) = .{};
        defer r.deinit(self.expressions.allocator);
        for (try array(j)) |v| c.append(u32, &r, self.expressions.allocator, try self.nameRef(v));
        return self.environment.copy(u32, r.items);
    }
    fn universeRefs(self: *Importer, j: J) c.Error!u32 {
        var r: c.List(u32) = .{};
        defer r.deinit(self.expressions.allocator);
        for (try array(j)) |v| c.append(u32, &r, self.expressions.allocator, try self.levelRef(v));
        return self.expressions.list(r.items);
    }
    pub fn decl(self: *Importer, j: J, kind: environment.DeclKind) c.Error!environment.Decl {
        var d: environment.Decl = .{ .name = try self.nameRef(try field(j, "name")), .kind = kind, .ty = try self.exprRef(try field(j, "type")), .params = try self.nameRefs(try field(j, "levelParams")) };
        var result_type = d.ty;
        while (self.expressions.kind(result_type) == .pi) result_type = self.expressions.get(result_type).b;
        d.nonproof_result = self.expressions.kind(result_type) == .sort;
        const result_head = self.expressions.get(self.expressions.head(result_type));
        if (result_head.kind == .cnst) {
            if (self.environment.find(result_head.a)) |result_decl| {
                var universe_type = result_decl.ty;
                while (self.expressions.kind(universe_type) == .pi) universe_type = self.expressions.get(universe_type).b;
                const universe = self.expressions.get(universe_type);
                // A strictly positive result universe stays positive under
                // all parameter substitutions. Prop-valued results and
                // unknown universe parameters retain the general path.
                if (universe.kind == .sort and self.expressions.levels.nonzero(universe.a)) d.nonproof_result = true;
            }
        }
        if (j.object.get("value")) |v| d.value = try self.exprRef(v);
        switch (kind) {
            .definition, .theorem, .opaque_decl => if (d.value == null) return error.InvalidInput,
            else => if (d.value != null) return error.InvalidInput,
        }
        if (kind == .definition) {
            var body = d.value.?;
            while (self.expressions.kind(body) == .lam) body = self.expressions.get(body).b;
            d.projection_function = self.expressions.kind(body) == .proj;
        }
        if (j.object.get("isUnsafe")) |v| d.unsafe_ = try boolean(v);
        if (j.object.get("safety")) |v| d.unsafe_ = !std.mem.eql(u8, try text(v), "safe");
        if (j.object.get("hints")) |v| {
            if (v == .string) {
                if (std.mem.eql(u8, v.string, "abbrev")) d.hint_kind = .abbrev else if (std.mem.eql(u8, v.string, "opaque")) d.hint_kind = .opaque_hint else return error.InvalidInput;
            } else {
                const h = try field(v, "regular");
                d.height = if (h == .integer or h == .number_string) try num(h) else try num(try field(h, "height"));
            }
        }
        inline for (.{ "numParams", "numIndices", "numFields", "numMotives", "numMinors", "numNested", "cidx" }, .{ "num_params", "num_indices", "num_fields", "num_motives", "num_minors", "nested", "ctor_index" }) |key, dest| {
            if (j.object.get(key)) |v| @field(d, dest) = try num(v);
        }
        inline for (.{ "isRec", "isReflexive", "k" }, .{ "recursive", "reflexive", "k" }) |key, dest| {
            if (j.object.get(key)) |v| @field(d, dest) = try boolean(v);
        }
        if (j.object.get("induct")) |v| d.parent = try self.nameRef(v);
        if (j.object.get("all")) |v| d.all = try self.nameRefs(v);
        if (j.object.get("ctors")) |v| d.ctors = try self.nameRefs(v);
        if (j.object.get("rules")) |v| {
            var rules: c.List(environment.Rule) = .{};
            defer rules.deinit(self.expressions.allocator);
            for (try array(v)) |rule| c.append(environment.Rule, &rules, self.expressions.allocator, .{ .ctor = try self.nameRef(try field(rule, "ctor")), .fields = try num(try field(rule, "nfields")), .rhs = try self.exprRef(try field(rule, "rhs")) });
            d.rules = self.environment.copy(environment.Rule, rules.items);
        }
        if (kind == .quotient) {
            const k = try text(try field(j, "kind"));
            d.quot_kind = if (std.mem.eql(u8, k, "ctor")) .mk else std.meta.stringToEnum(@TypeOf(d.quot_kind), k) orelse return error.InvalidInput;
        }
        return d;
    }
    pub fn line(self: *Importer, j: J) c.Error!void {
        self.lines += 1;
        if (j != .object) return error.InvalidInput;
        const m = self.expressions;
        m.importing = true;
        defer m.importing = false;
        const a = m.allocator;
        if (j.object.get("meta")) |meta| {
            if (j.object.count() != 1) return error.InvalidInput;
            if (self.header or self.lines != 1) return error.InvalidInput;
            const version = try text(try field(try field(meta, "format"), "version"));
            if (!std.mem.startsWith(u8, version, "3.")) return error.Unsupported;
            self.header = true;
            return;
        }
        if (!self.header) return error.InvalidInput;
        if (j.object.get("in")) |id| {
            if (j.object.count() != 2) return error.InvalidInput;
            const name: u32 = if (j.object.get("str")) |v| self.environment.child(try self.nameRef(try field(v, "pre")), try text(try field(v, "str"))) else if (j.object.get("num")) |v| try self.numericName(try self.nameRef(try field(v, "pre")), try field(v, "i")) else return error.InvalidInput;
            try self.names.add(a, try num(id), name);
            return;
        }
        if (j.object.get("il")) |id| {
            if (j.object.count() != 2) return error.InvalidInput;
            const lv: u32 = if (j.object.get("succ")) |v| m.levels.succ(try self.levelRef(v)) else if (j.object.get("param")) |v| m.levels.param(try self.nameRef(v)) else blk: {
                const im = j.object.get("imax");
                const v = im orelse j.object.get("max") orelse return error.InvalidInput;
                const pair = try array(v);
                if (pair.len != 2) return error.InvalidInput;
                const lhs = try self.levelRef(pair[0]);
                const rhs = try self.levelRef(pair[1]);
                break :blk if (im != null) m.levels.imax(lhs, rhs) else m.levels.max(lhs, rhs);
            };
            try self.levels.add(a, try num(id), lv);
            return;
        }
        if (j.object.get("ie")) |id| {
            if (j.object.count() != 2) return error.InvalidInput;
            const ex: u32 = blk: {
                if (j.object.get("bvar")) |v| {
                    const index = try num(v);
                    if (index == std.math.maxInt(u32)) return error.InvalidInput;
                    break :blk m.bvar(index);
                }
                if (j.object.get("mdata")) |v| break :blk try self.exprRef(try field(v, "expr"));
                if (j.object.get("sort")) |v| break :blk m.sort(try self.levelRef(v));
                if (j.object.get("const")) |v| break :blk m.cnst(try self.nameRef(try field(v, "name")), try self.universeRefs(try field(v, "us")));
                if (j.object.get("app")) |v| break :blk m.app(try self.exprRef(try field(v, "fn")), try self.exprRef(try field(v, "arg")));
                inline for (.{ "lam", "forallE" }, .{ ExprKind.lam, ExprKind.pi }) |key, kind| {
                    if (j.object.get(key)) |v| {
                        _ = try self.nameRef(try field(v, "name"));
                        const bi = try text(try field(v, "binderInfo"));
                        if (!std.mem.eql(u8, bi, "default") and !std.mem.eql(u8, bi, "implicit") and !std.mem.eql(u8, bi, "strictImplicit") and !std.mem.eql(u8, bi, "instImplicit")) return error.InvalidInput;
                        break :blk m.binder(kind, try self.exprRef(try field(v, "type")), try self.exprRef(try field(v, "body")));
                    }
                }
                if (j.object.get("letE")) |v| break :blk m.mk(.letE, try self.exprRef(try field(v, "type")), try self.exprRef(try field(v, "value")), try self.exprRef(try field(v, "body")));
                if (j.object.get("proj")) |v| break :blk m.mk(.proj, try self.nameRef(try field(v, "typeName")), try num(try field(v, "idx")), try self.exprRef(try field(v, "struct")));
                if (j.object.get("natVal")) |v| {
                    const digits = try text(v);
                    break :blk try @import("primitive.zig").parseNatural(m, digits);
                }
                if (j.object.get("strVal")) |v| break :blk m.mk(.str, self.environment.string(try text(v)), 0, 0);
                return error.InvalidInput;
            };
            try self.exprs.add(a, try num(id), ex);
            return;
        }
        if (j.object.count() != 1) return error.InvalidInput;
        m.importing = false;
        if (self.threads > 1) return self.enqueue(j);
        var check_timer = if (self.profile) std.time.Timer.start() catch unreachable else undefined;
        defer if (self.profile) {
            self.check_ns += check_timer.read();
        };
        if (self.checker == null) self.checker = Checker.init(m, self.environment);
        const tc = &self.checker.?;
        tc.beginDeclaration();
        tc.max_ticks = self.max_ticks;
        tc.max_temporary_nodes = self.max_temporary_nodes;
        defer tc.trimCaches();
        defer m.reset();
        if (j.object.get("inductive")) |v| {
            var types: c.List(environment.Decl) = .{};
            defer types.deinit(a);
            var ctors: c.List(environment.Decl) = .{};
            defer ctors.deinit(a);
            var recs: c.List(environment.Decl) = .{};
            defer recs.deinit(a);
            for (try array(try field(v, "types"))) |d| c.append(environment.Decl, &types, a, try self.decl(d, .inductive));
            for (try array(try field(v, "ctors"))) |d| c.append(environment.Decl, &ctors, a, try self.decl(d, .ctor));
            for (try array(try field(v, "recs"))) |d| c.append(environment.Decl, &recs, a, try self.decl(d, .recursor));
            if (types.items.len == 0) return error.InvalidInductive;
            self.last_name = types.items[0].name;
            try @import("inductive.zig").check(tc, types.items, ctors.items, recs.items);
            self.declarations += types.items.len + ctors.items.len + recs.items.len;
            return;
        }
        inline for (.{ "axiom", "def", "thm", "opaque", "quot" }, .{ environment.DeclKind.axiom, environment.DeclKind.definition, environment.DeclKind.theorem, environment.DeclKind.opaque_decl, environment.DeclKind.quotient }) |key, kind| {
            if (j.object.get(key)) |v| {
                const d = try self.decl(v, kind);
                self.last_name = d.name;
                if (kind == .quotient) {
                    try @import("quotient.zig").check(tc, d);
                } else try tc.checkDecl(d);
                self.declarations += 1;
                return;
            }
        }
        return error.InvalidInput;
    }
};
