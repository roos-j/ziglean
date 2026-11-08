//! Parallel declaration checking over immutable imported terms. Each task sees
//! only its declaration's predecessors, plus locally derived inductive entries.
const std = @import("std");
const c = @import("common.zig");
const environment = @import("environment.zig");
const ExprPool = @import("expr.zig").Pool;
const Checker = @import("type_checker.zig").Checker;
const LevelPool = @import("level.zig").Pool;

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
