const std = @import("std");
const Expr = @import("../../src/common.zig").Expr;
const LevelPool = @import("../../src/level.zig").Pool;
const ExprPool = @import("../../src/expr.zig").Pool;
const Environment = @import("../../src/environment.zig").Environment;
const Checker = @import("../../src/type_checker.zig").Checker;
const Importer = @import("../../src/import.zig").Importer;

fn compare(checker: *Checker, term: Expr) !void {
    checker.beginDeclaration();
    checker.nbe_enabled = false;
    const reference = try checker.whnf(term);
    checker.beginDeclaration();
    checker.nbe_enabled = true;
    checker.nbe_min_work = 0;
    const evaluated = try checker.whnf(term);
    try std.testing.expect(!checker.nbe_blocked);
    checker.beginDeclaration();
    checker.nbe_enabled = false;
    try std.testing.expect(try checker.defeq(reference, evaluated));
}

fn generated(m: *ExprPool, random: std.Random, depth: u32, scope: u32, neutral: Expr) Expr {
    const ty = m.sort(m.levels.succ(0));
    if (depth == 0) return if (scope > 0 and random.boolean()) m.bvar(random.uintLessThan(u32, scope)) else m.sort(0);
    return switch (random.uintLessThan(u32, 4)) {
        0 => m.app(m.binder(.lam, ty, generated(m, random, depth - 1, scope + 1, neutral)), generated(m, random, depth - 1, scope, neutral)),
        1 => m.mk(.letE, ty, generated(m, random, depth - 1, scope, neutral), generated(m, random, depth - 1, scope + 1, neutral)),
        2 => m.app(neutral, generated(m, random, depth - 1, scope, neutral)),
        else => if (scope > 0) m.bvar(random.uintLessThan(u32, scope)) else m.sort(0),
    };
}

test "NbE agrees with substitution on generated scoped beta and let terms" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var checker = Checker.init(&m, &env);
    defer checker.deinit();
    const ty = m.sort(levels.succ(0));
    const neutral = m.fvar(m.binder(.pi, ty, ty));
    var prng = std.Random.DefaultPrng.init(0x19b347);
    for (0..400) |_| try compare(&checker, generated(&m, prng.random(), 6, 0, neutral));
}

test "NbE readback preserves capture, dependent domains, and shadowing" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var checker = Checker.init(&m, &env);
    defer checker.deinit();
    const ty = m.sort(levels.succ(0));
    const alpha = m.fvar(ty);
    const x = m.fvar(alpha);
    const constant = m.binder(.lam, ty, m.binder(.lam, m.bvar(0), m.binder(.lam, m.bvar(1), m.bvar(1))));
    try compare(&checker, m.apps(constant, &.{ alpha, x }));
    const shadow = m.mk(.letE, ty, alpha, m.binder(.lam, ty, m.binder(.pi, m.bvar(1), m.bvar(1))));
    try compare(&checker, shadow);
    const inner = m.binder(.lam, ty, m.binder(.lam, ty, m.bvar(1)));
    try compare(&checker, m.apps(inner, &.{ m.sort(0), alpha }));
}

test "NbE does not force a discarded argument" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var checker = Checker.init(&m, &env);
    defer checker.deinit();
    const ty = m.sort(levels.succ(0));
    var expensive = m.sort(0);
    for (0..1024) |_| expensive = m.mk(.letE, ty, m.sort(0), expensive);
    const term = m.app(m.binder(.lam, ty, m.sort(0)), expensive);
    checker.nbe_min_work = 0;
    checker.max_ticks = 128;
    try std.testing.expectEqual(m.sort(0), try checker.whnf(term));
}

test "NbE specializes universe parameters and preserves local definitions" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var checker = Checker.init(&m, &env);
    defer checker.deinit();
    const u = env.named("u");
    const ty = m.sort(levels.param(u));
    const params = [_]u32{u};
    const name = env.named("polyId");
    try env.add(.{ .name = name, .kind = .definition, .ty = m.binder(.pi, ty, ty), .value = m.binder(.lam, ty, m.bvar(0)), .params = &params });
    try compare(&checker, m.app(m.cnst(name, m.list(&.{levels.succ(0)})), m.sort(0)));
    try compare(&checker, m.app(m.cnst(name, m.list(&.{levels.succ(levels.succ(0))})), m.sort(levels.succ(0))));
    const local = m.letVariable(m.sort(levels.succ(0)), m.sort(0));
    try compare(&checker, local);
}

fn forcedFixture(bytes: []const u8) !void {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var importer = Importer.init(&m, &env);
    defer importer.deinit();
    importer.checker = Checker.init(&m, &env);
    importer.checker.?.nbe_min_work = 0;
    m.temporary = false;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| try importer.lineBytes(std.testing.allocator, line);
    try importer.finish();
}

test "forced NbE preserves quotient, recursor, projection and proof rules" {
    try forcedFixture(@embedFile("../../arena/good/tutorial/130_quotLiftReduction.ndjson"));
    try forcedFixture(@embedFile("../../arena/good/tutorial/131_quotIndReduction.ndjson"));
    try forcedFixture(@embedFile("../../arena/good/tutorial/122_rtreeRecReduction.ndjson"));
    try forcedFixture(@embedFile("../kernel/good/unit_like.ndjson"));
    try forcedFixture(@embedFile("../kernel/good/conversion.ndjson"));
    try forcedFixture(@embedFile("../kernel/good/nbe-data.ndjson"));
    try forcedFixture(@embedFile("../../arena/good/perf/proj-stuck-struct.ndjson"));
    try std.testing.expectError(error.TypeMismatch, forcedFixture(@embedFile("../kernel/bad/axiom-quot-mk-without-ind.ndjson")));
    try std.testing.expectError(error.InvalidProjection, forcedFixture(@embedFile("../../arena/bad/tutorial/094_projProp6.ndjson")));
}

test "NbE honors configured storage limits without a speculative work cutoff" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var checker = Checker.init(&m, &env);
    defer checker.deinit();
    const ty = m.sort(levels.succ(0));
    const term = m.app(m.binder(.lam, ty, m.bvar(0)), m.sort(0));
    checker.beginDeclaration();
    checker.nbe_min_work = 0;
    checker.max_temporary_nodes = 1;
    try std.testing.expectError(error.ResourceLimit, checker.whnf(term));
    try std.testing.expect(!checker.nbe_active);
    checker.beginDeclaration();
    checker.max_temporary_nodes = 64_000_000;
    var long = m.sort(0);
    const identity = m.binder(.lam, ty, m.bvar(0));
    for (0..20000) |_| long = m.app(identity, long);
    checker.beginDeclaration();
    try std.testing.expectEqual(m.sort(0), try checker.whnf(long));
    try std.testing.expect(checker.ticks > 65536);
    try std.testing.expect(!checker.nbe_blocked);
    try std.testing.expectEqual(@as(?u64, null), checker.speculation_limit);
}

test "NbE preserves sparse captures and environments wider than its support mask" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var checker = Checker.init(&m, &env);
    defer checker.deinit();
    const ty = m.sort(levels.succ(0));
    const x = m.fvar(ty);
    const y = m.fvar(ty);
    for ([_]u32{ 4, 63, 70 }) |width| {
        // Retain only the oldest capture inside a returned dependent binder.
        var term = m.binder(.pi, m.bvar(width - 1), m.bvar(width));
        for (0..width) |_| term = m.binder(.lam, ty, term);
        term = m.app(term, x);
        for (1..width) |_| term = m.app(term, y);
        try compare(&checker, term);
    }
}

test "closed literal computation switches to NbE and restores the caller limits" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var m = ExprPool.init(std.testing.allocator, &levels);
    defer m.deinit();
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    var checker = Checker.init(&m, &env);
    defer checker.deinit();
    const ty = m.cnst(env.builtin("Nat"), 0);
    const value = @import("../../src/primitive.zig").nat(&checker, 42);
    const identity = m.binder(.lam, ty, m.bvar(0));
    var term = value;
    for (0..20000) |_| term = m.app(identity, term);
    checker.beginDeclaration();
    try std.testing.expect(try checker.defeq(term, value));
    try std.testing.expect(checker.ticks > 65536);
    try std.testing.expect(!checker.nbe_active and !checker.nbe_prefer and !checker.nbe_blocked);
    try std.testing.expectEqual(@as(?u64, null), checker.speculation_limit);
    checker.beginDeclaration();
    checker.max_ticks = 10;
    try std.testing.expectError(error.ResourceLimit, checker.defeq(term, value));
    try std.testing.expect(!checker.nbe_active and !checker.nbe_prefer);
    try std.testing.expectEqual(@as(?u64, null), checker.speculation_limit);
}
