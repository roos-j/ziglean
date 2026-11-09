//! Parallel declaration checking over immutable imported terms. Each task sees
//! only its declaration's predecessors, plus locally derived inductive entries.
const std = @import("std");
const c = @import("common.zig");
const environment = @import("environment.zig");
const ExprPool = @import("expr.zig").Pool;
const Checker = @import("type_checker.zig").Checker;
const LevelPool = @import("level.zig").Pool;
const SubstitutionTotals = @import("substitution_profile.zig").Totals;

pub const Task = struct {
    first: u32,
    line: u64,
    name: u32,
    weight: usize = 0,
    body: union(enum) {
        // The imported declaration already lives at `first` in the snapshot.
        single: void,
        inductive: struct { types: []const environment.Decl, ctors: []const environment.Decl, recs: []const environment.Decl },
    },
    failure: ?c.Error = null,
    elapsed_ns: u64 = 0,
};

pub const Batch = struct {
    expressions: *const ExprPool,
    environment: *const environment.Environment,
    tasks: []Task,
    max_ticks: u64,
    max_temporary_nodes: u32,
    profile: bool = false,
    profile_workers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    substitution_profiles: [32]SubstitutionTotals = undefined,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn worker(self: *Batch) void {
        var levels = self.expressions.levels.view();
        defer levels.deinit();
        var expressions = self.expressions.fork(&levels);
        defer expressions.deinit();
        var env = self.environment.fork();
        defer env.deinit();
        var checker = Checker.init(&expressions, &env);
        defer checker.deinit();
        checker.substitution_profile.enabled = self.profile;
        const profile_index = if (self.profile) self.profile_workers.fetchAdd(1, .monotonic) else 0;
        defer if (self.profile) {
            self.substitution_profiles[profile_index] = checker.substitution_profile.totals;
        };
        checker.max_ticks = self.max_ticks;
        checker.max_temporary_nodes = self.max_temporary_nodes;
        while (!self.failed.load(.monotonic)) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.tasks.len) return;
            const task = &self.tasks[index];
            var timer = if (self.profile) std.time.Timer.start() catch unreachable else undefined;
            env.beginView(task.first);
            checker.beginDeclaration();
            // The importing thread reports errors after all workers finish.
            checker.reported = true;
            checkTask(&checker, task.*) catch |err| {
                task.failure = err;
                self.failed.store(true, .monotonic);
                return;
            };
            checker.trimCaches();
            expressions.reset();
            if (self.profile) task.elapsed_ns = timer.read();
        }
    }
    fn checkTask(checker: *Checker, task: Task) c.Error!void {
        switch (task.body) {
            .single => {
                const decl = checker.environment.decls.items[task.first];
                if (decl.kind == .quotient) try @import("quotient.zig").check(checker, decl) else try checker.checkDecl(decl);
            },
            .inductive => |group| try @import("inductive.zig").check(checker, group.types, group.ctors, group.recs),
        }
    }
    pub fn run(self: *Batch, count: usize) c.Error!void {
        var threads: [32]std.Thread = undefined;
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        const workers = @min(count, self.tasks.len);
        if (workers <= 1) return self.worker();
        for (0..workers) |_| {
            threads[started] = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, worker, .{self}) catch {
                self.failed.store(true, .monotonic);
                return error.ResourceLimit;
            };
            started += 1;
        }
    }
    /// Call only after every worker has joined. Each slot has one writer.
    pub fn substitutionTotals(self: *const Batch) SubstitutionTotals {
        var result: SubstitutionTotals = .{};
        for (self.substitution_profiles[0..self.profile_workers.load(.monotonic)]) |totals| result.add(totals);
        return result;
    }
};

/// Owns the small mutable-table snapshots; the large node array is borrowed at
/// stable virtual addresses. Input can append new nodes while these are checked.
pub const Job = struct {
    levels: LevelPool,
    expressions: ExprPool,
    environment: environment.Environment,
    tasks: c.List(Task),
    batch: Batch = undefined,
    group: std.Thread.WaitGroup = .{},
    remaining: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    timer: std.time.Timer = undefined,
    joined: bool = false,
    threads: u8,
    completion: *std.Thread.Semaphore,
    elapsed_ns: u64 = 0,

    pub fn create(expressions: *const ExprPool, env: *const environment.Environment, tasks: c.List(Task), threads: u8, max_ticks: u64, max_temporary_nodes: u32, completion: *std.Thread.Semaphore) *Job {
        const self = expressions.allocator.create(Job) catch c.oom();
        self.* = .{ .levels = expressions.levels.fork(), .expressions = undefined, .environment = env.snapshot(), .tasks = tasks, .threads = threads, .completion = completion };
        self.expressions = expressions.snapshot(&self.levels);
        self.batch = .{ .expressions = &self.expressions, .environment = &self.environment, .tasks = tasks.items, .max_ticks = max_ticks, .max_temporary_nodes = max_temporary_nodes };
        return self;
    }
    pub fn start(self: *Job, pool: *std.Thread.Pool) void {
        const count = @min(self.threads, self.tasks.items.len);
        self.remaining.store(count, .monotonic);
        self.timer = std.time.Timer.start() catch unreachable;
        for (0..count) |_| pool.spawnWg(&self.group, run, .{self});
    }
    fn run(self: *Job) void {
        self.batch.worker();
        if (self.remaining.fetchSub(1, .acq_rel) == 1) {
            self.elapsed_ns = self.timer.read();
            self.completion.post();
        }
    }
    pub fn join(self: *Job) void {
        if (!self.joined) self.group.wait();
        self.joined = true;
    }
    /// Profile-only estimate of owned tables. Shared node/declaration storage,
    /// indexed name tables, and string bytes are excluded; hash headers/padding are small
    /// and omitted, so this is not a replacement for OS peak-memory counters.
    pub fn estimatedOwnedBytes(self: *const Job) usize {
        const env = &self.environment;
        const m = &self.expressions;
        return @sizeOf(Job) + self.tasks.capacity * @sizeOf(Task) +
            (if (env.owns_name_storage) env.names.capacity * @sizeOf(environment.NameNode) else 0) +
            (if (env.owns_string_storage) env.strings.capacity * @sizeOf([]const u8) else 0) +
            (if (env.owns_declaration_index) env.decl_map.capacity * @sizeOf(u32) else 0) + (if (env.owns_declarations) env.decls.capacity * @sizeOf(environment.Decl) else 0) +
            self.levels.nodes.capacity * @sizeOf(@import("level.zig").Node) + mapBytes(@import("level.zig").Node, u32, self.levels.map.capacity()) +
            m.universe_lists.nodes.capacity * @sizeOf([2]u32) + mapBytes([2]u32, u32, m.universe_lists.map.capacity()) +
            m.global.slots.len * @sizeOf(u32) + m.global.tags.len + mapBytes(u32, u32, m.global.wide_ranges.capacity()) +
            m.natural_strings[0].strings.capacity * @sizeOf([]const u8) + mapBytes([]const u8, u32, m.natural_strings[0].indices.capacity());
    }
    pub fn deinit(self: *Job) void {
        self.join();
        const allocator = self.expressions.allocator;
        self.tasks.deinit(allocator);
        self.environment.deinit();
        self.expressions.deinit();
        self.levels.deinit();
        allocator.destroy(self);
    }
};

fn mapBytes(comptime Key: type, comptime Value: type, capacity: usize) usize {
    // std.HashMap uses separate key/value arrays and one metadata byte per slot.
    return capacity * (@sizeOf(Key) + @sizeOf(Value) + 1);
}
