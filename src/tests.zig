const std = @import("std");
const level = @import("level.zig");
const expr = @import("expr.zig");
const Environment = @import("environment.zig").Environment;
const Checker = @import("type_checker.zig").Checker;
const Importer = @import("import.zig").Importer;
const primitive = @import("primitive.zig");

test "canonical record scanner never accepts truncated or malformed JSON" {
    const scan = @import("scan.zig").scan;
    const sample = "{\"app\":{\"arg\":12,\"fn\":45},\"ie\":67}";
    const record = scan(sample).?;
    try std.testing.expectEqual(@as(u32, 45), record.a);
    try std.testing.expectEqual(@as(u32, 12), record.b);
    for (0..sample.len) |length| try std.testing.expect(scan(sample[0..length]) == null);
    for ([_][]const u8{
        sample ++ "x",                    sample ++ ",",                                   sample ++ "{}",
        "{\"bvar\":01,\"ie\":0}",         "{\"bvar\":-1,\"ie\":0}",                        "{\"bvar\":4294967296,\"ie\":0}",
        "{\"bvar\":0,\"ie\":0,\"ie\":1}", "{\"const\":{\"name\":0,\"us\":[0,]},\"ie\":0}",
    }) |bytes| try std.testing.expect(scan(bytes) == null);
    var lines = std.mem.tokenizeScalar(u8, @embedFile("../tests/fixtures/conversion.ndjson"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (scan(line) != null) {
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
            parsed.deinit();
            count += 1;
        }
    }
    try std.testing.expect(count > 1000);
    var random = std.Random.DefaultPrng.init(772);
    var buffer: [80]u8 = undefined;
    for (0..5000) |_| {
        const value = random.random().int(u32);
        const line = try std.fmt.bufPrint(&buffer, "{{\"bvar\":{d},\"ie\":0}}", .{value});
        try std.testing.expectEqual(value, scan(line).?.a);
    }
}

test "line reader handles boundaries, empty records, final fragments and limits" {
    var stream = std.io.fixedBufferStream("a\n\n123456789\nlast");
    var reader = @import("line_reader.zig").LineReader(@TypeOf(stream.reader()), 3).init(stream.reader(), std.testing.allocator, 9);
    defer reader.deinit();
    for ([_][]const u8{ "a", "", "123456789", "last" }) |expected| try std.testing.expectEqualStrings(expected, (try reader.next()).?);
    try std.testing.expect(try reader.next() == null);
    var large = std.io.fixedBufferStream("1234567890\n");
    var limited = @import("line_reader.zig").LineReader(@TypeOf(large.reader()), 3).init(large.reader(), std.testing.allocator, 9);
    defer limited.deinit();
    try std.testing.expectError(error.StreamTooLong, limited.next());
}

test "canonical lambda and let records preserve every reference" {
    const scanner = @import("scan.zig");
    const samples = [_][]const u8{
        "{\"ie\":38,\"lam\":{\"binderInfo\":\"default\",\"body\":1,\"name\":14,\"type\":24}}",
        "{\"lam\":{\"binderInfo\":\"implicit\",\"body\":1,\"name\":14,\"type\":24},\"ie\":38}",
        "{\"ie\":38,\"letE\":{\"body\":1,\"name\":14,\"nondep\":false,\"type\":24,\"value\":7}}",
    };
    for (samples, 0..) |sample, index| {
        const record = scanner.scan(sample).?;
        try std.testing.expectEqual(@as(u32, 38), record.id);
        try std.testing.expectEqual(@as(u32, 24), record.a);
        if (index < 2) {
            try std.testing.expectEqual(scanner.Kind.lam, record.kind);
            try std.testing.expectEqual(@as(u32, 1), record.b);
            try std.testing.expectEqual(@as(u32, 14), record.c);
        } else {
            try std.testing.expectEqual(scanner.Kind.letE, record.kind);
            try std.testing.expectEqual(@as(u32, 7), record.b);
            try std.testing.expectEqual(@as(u32, 1), record.c);
            try std.testing.expectEqual(@as(u32, 14), record.d);
        }
        for (0..sample.len) |length| try std.testing.expect(scanner.scan(sample[0..length]) == null);
    }
}

test "direct expression caches separate imported and recycled temporary IDs" {
    var cache: @import("check_cache.zig").ExprMap(u32) = .{};
    defer cache.deinit(std.testing.allocator);
    const keys = [_]u32{ 3, 0x80000003, 0x80010000 };
    for (keys, 0..) |key, index| try cache.put(std.testing.allocator, key, @intCast(index));
    for (keys, 0..) |key, index| try std.testing.expectEqual(@as(u32, @intCast(index)), cache.get(key).?);
    cache.clearRetainingCapacity();
    for (keys) |key| try std.testing.expect(cache.get(key) == null);
    cache.epoch = std.math.maxInt(u32);
    try cache.put(std.testing.allocator, keys[1], 42);
    cache.clearRetainingCapacity();
    try std.testing.expect(cache.get(keys[1]) == null);
}

test "virtual storage keeps addresses stable when committing more pages" {
    var buffer: @import("reserved_buffer.zig").Buffer = .{ .granularity = 64 * 1024 };
    defer buffer.deinit();
    try buffer.ensure(1);
    const pointer = buffer.pointer.?;
    pointer[0] = 73;
    try buffer.ensure(128 * 1024 + 1);
    try std.testing.expect(pointer == buffer.pointer.?);
    try std.testing.expectEqual(@as(u8, 73), pointer[0]);
    try std.testing.expect(buffer.committed >= 128 * 1024 + 1);
}

test "checker memo generations invalidate reused keys and wrap safely" {
    var cache: @import("check_cache.zig").Map(u64, bool) = .{};
    defer cache.deinit(std.testing.allocator);
    for (0..2000) |key| try cache.put(std.testing.allocator, key, key % 2 == 0);
    for (0..2000) |key| try std.testing.expectEqual(key % 2 == 0, cache.get(key).?);
    cache.clearRetainingCapacity();
    for (0..2000) |key| try std.testing.expect(cache.get(key) == null);
    try cache.put(std.testing.allocator, 3, true);
    cache.epoch = std.math.maxInt(u32);
    cache.clearRetainingCapacity();
    try std.testing.expect(cache.get(3) == null);
}

test "substitution work tables isolate calls, grow, and handle generation wraparound" {
    var cache: @import("transform_cache.zig").Cache = .{};
    defer cache.deinit(std.testing.allocator);
    for (0..4000) |i| cache.put(std.testing.allocator, i * 3, @intCast(i));
    for (0..4000) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), cache.get(i * 3).?);
    cache.reset();
    for (0..4000) |i| try std.testing.expectEqual(@as(?u32, null), cache.get(i * 3));
    cache.put(std.testing.allocator, 3, 10000);
    try std.testing.expectEqual(@as(u32, 10000), cache.get(3).?);
    cache.epoch = std.math.maxInt(u32);
    cache.reset();
    for (0..4000) |i| try std.testing.expectEqual(@as(?u32, null), cache.get(i * 3));
}
test "universe normalization and substitution" {
    var l = level.Pool.init(std.testing.allocator);
    defer l.deinit();
    const u = l.param(1);
    const v = l.param(2);
    try std.testing.expect(l.equal(l.max(u, v), l.max(v, u)));
    try std.testing.expect(l.equal(l.succ(l.max(u, v)), l.max(l.succ(u), l.succ(v))));
    try std.testing.expectEqual(@as(u32, 0), l.subst(l.imax(u, v), &.{2}, &.{0}));
    try std.testing.expect(!l.equal(u, l.succ(u)));
}

test "natural arithmetic includes zero gcd and values beyond machine words" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();

    const zero = primitive.nat(&checker, 0);
    const gcd = expressions.cnst(environment.builtin("Nat.gcd"), 0);
    try std.testing.expectEqual(zero, (try primitive.reduce(&checker, gcd, &.{ zero, zero })).?);
    const left = try primitive.parseNatural(&expressions, "18446744073709551619");
    const right = try primitive.parseNatural(&expressions, "18446744073709551621");
    const product = try primitive.parseNatural(&expressions, "340282366920938463610948560021444624399");
    const multiply = expressions.cnst(environment.builtin("Nat.mul"), 0);
    try std.testing.expectEqual(product, (try primitive.reduce(&checker, multiply, &.{ left, right })).?);
    const divide = expressions.cnst(environment.builtin("Nat.div"), 0);
    try std.testing.expectEqual(left, (try primitive.reduce(&checker, divide, &.{ product, right })).?);
    const remainder = expressions.cnst(environment.builtin("Nat.mod"), 0);
    try std.testing.expectEqual(product, (try primitive.reduce(&checker, remainder, &.{ product, zero })).?);
}

test "scratch storage resets without retaining expressions or large numerals" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const proposition = expressions.sort(0);
    for (0..20) |_| {
        expressions.temporary = true;
        const variable = expressions.fvar(proposition);
        var term = variable;
        for (0..1000) |_| term = expressions.app(term, variable);
        _ = try primitive.parseNatural(&expressions, "18446744073709551616");
        expressions.reset();
        try std.testing.expectEqual(@as(usize, 0), expressions.local.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 0), expressions.natural_strings[1].strings.items.len);
        try std.testing.expectEqual(expr.Kind.sort, expressions.kind(proposition));
    }
}

fn checkFixture(bytes: []const u8) !void {
    return checkFixtureWithBudget(bytes, 100_000_000);
}

fn checkFixtureWithBudget(bytes: []const u8, max_steps: u64) !void {
    return checkFixtureThreads(bytes, max_steps, 1);
}

fn checkFixtureThreads(bytes: []const u8, max_steps: u64, threads: u8) !void {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    expressions.global.virtual = threads > 1;
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var importer = Importer.init(&expressions, &environment);
    defer importer.deinit();
    importer.max_ticks = max_steps;
    importer.threads = threads;
    importer.batch_size = 16;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        try importer.lineBytes(allocator, line);
    }
    try importer.finish();
}

test "parallel views preserve inductive scopes and reject forward references" {
    try checkFixtureThreads(@embedFile("../tests/fixtures/conversion.ndjson"), 100_000, 4);
    try checkFixtureThreads(@embedFile("../tests/fixtures/multifunctor.ndjson"), 1_000_000, 4);
    try std.testing.expectError(error.InvalidProjection, checkFixtureThreads(@embedFile("../arena/bad/tutorial/094_projProp6.ndjson"), 100_000, 4));
    const forward =
        \\{"meta":{"format":{"version":"3.1.0"}}}
        \\{"in":1,"str":{"pre":0,"str":"future"}}
        \\{"in":2,"str":{"pre":0,"str":"early"}}
        \\{"ie":0,"sort":0}
        \\{"const":{"name":1,"us":[]},"ie":1}
        \\{"axiom":{"name":2,"type":1,"levelParams":[]}}
        \\{"axiom":{"name":1,"type":0,"levelParams":[]}}
    ;
    try std.testing.expectError(error.UnknownConstant, checkFixtureThreads(forward, 100_000, 4));
}

test "repeated nested inductive parameters need no global hash-consing" {
    const fixture = @embedFile("../tests/fixtures/nested.ndjson");
    try checkFixture(fixture);
    try checkFixtureThreads(fixture, 100_000, 4);
}

test "polymorphic result universes retain proof irrelevance at zero" {
    const fixture = @embedFile("../tests/fixtures/proof_universes.ndjson");
    try checkFixture(fixture);
    try checkFixtureThreads(fixture, 100_000, 4);
}

test "universe views share imported levels and isolate derived levels" {
    var parent = level.Pool.init(std.testing.allocator);
    defer parent.deinit();
    const u = parent.param(1);
    const v = parent.param(2);
    const count = parent.nodes.items.len;
    var first = parent.view();
    defer first.deinit();
    var second = parent.view();
    defer second.deinit();
    try std.testing.expectEqual(u, first.param(1));
    const successor = first.succ(u);
    const maximum = second.max(u, v);
    try std.testing.expectEqual(level.Kind.offset, first.get(successor).kind);
    try std.testing.expectEqual(level.Kind.max, second.get(maximum).kind);
    try std.testing.expectEqual(count, parent.nodes.items.len);
    try std.testing.expectEqual(level.Kind.param, first.get(u).kind);
    try std.testing.expect(first.nonzero(successor));
    try std.testing.expect(!second.nonzero(maximum));
}

test "worker-generated names stay private without copying imported tables" {
    var base = Environment.init(std.testing.allocator);
    defer base.deinit();
    const parent = base.named("Family");
    const names_pointer = base.names.items.ptr;
    var worker = base.fork();
    defer worker.deinit();
    const generated = worker.child(parent, "rec_7");
    try std.testing.expectEqual(generated, worker.child(parent, "rec_7"));
    try std.testing.expect(worker.names.items.ptr == names_pointer);
    try std.testing.expectEqual(@as(usize, 0), base.extra_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), worker.extra_names.items.len);
    try std.testing.expectEqual(base.builtin("Nat"), worker.named("Nat"));
    const imported = base.child(parent, "rec_7");
    try std.testing.expect(imported != generated);
}

test "unchecked inference never bypasses argument validation" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const proposition = expressions.sort(0);
    const function = expressions.fvar(expressions.binder(.pi, proposition, proposition));
    const invalid = expressions.app(function, proposition);
    _ = try checker.infer(invalid, false);
    try std.testing.expectError(error.TypeMismatch, checker.infer(invalid, true));
}

test "scratch interning generations wrap without reusing stale nodes" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    const head = expressions.cnst(1, 0);
    for (0..600) |index| {
        expressions.temporary = true;
        const number = expressions.mk(.nat, @intCast(index), 0, 0);
        const applied = expressions.app(head, number);
        try std.testing.expectEqual(applied, expressions.app(head, number));
        const nested = expressions.app(applied, number);
        try std.testing.expectEqual(head, expressions.head(nested));
        try std.testing.expectEqual(@as(u32, @intCast(index)), expressions.get(expressions.get(applied).b).a);
        expressions.reset();
    }
}

test "Lean conversion regressions avoid proof evaluation and preserve projected primitives" {
    try checkFixtureWithBudget(@embedFile("../tests/fixtures/conversion.ndjson"), 100_000);
    try checkFixture(@embedFile("../tests/fixtures/unit_like.ndjson"));
}

test "projection conversion avoids both unnecessary instance unfolding and discarded fields" {
    try checkFixtureWithBudget(@embedFile("../arena/good/perf/proj-cheap-struct.ndjson"), 100_000);
    try checkFixtureWithBudget(@embedFile("../arena/good/perf/proj-lazy-struct.ndjson"), 100_000);
}

test "application congruence shares dependent function prefixes" {
    try checkFixtureWithBudget(@embedFile("../tests/fixtures/multifunctor.ndjson"), 1_000_000);
}

test "abbreviation hints preserve symbolic arithmetic in signed ranges" {
    try checkFixtureWithBudget(@embedFile("../tests/fixtures/signed_range.ndjson"), 1_000_000);
}

fn expectRejected(bytes: []const u8) !void {
    if (checkFixture(bytes)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err != error.Unsupported and err != error.ResourceLimit and err != error.UnsafeDeclaration and err != error.SpeculationLimit);
    }
}

test "Arena beta, dependent lets, quotients, and reflexive inductives" {
    try checkFixture(@embedFile("../arena/good/tutorial/007_betaReduction2.ndjson"));
    try checkFixture(@embedFile("../arena/good/tutorial/034_letTypeDep.ndjson"));
    try checkFixture(@embedFile("../arena/good/tutorial/130_quotLiftReduction.ndjson"));
    try checkFixture(@embedFile("../arena/good/tutorial/122_rtreeRecReduction.ndjson"));
}

test "Arena forged recursors and dependent data projections are rejected" {
    try std.testing.expectError(error.InvalidProjection, checkFixture(@embedFile("../arena/bad/tutorial/094_projProp6.ndjson")));
    try expectRejected(@embedFile("../arena/bad/bugs/rec-missing-ih.ndjson"));
    try std.testing.expectError(error.UndeclaredUniverse, checkFixture(@embedFile("../arena/bad/other/inductive-undeclared-universe.ndjson")));
    try expectRejected(@embedFile("../arena/bad/bugs/nested-name-capture.ndjson"));
}

test "a theorem without a proof cannot silently become an axiom" {
    const input =
        \\{"meta":{"format":{"version":"3.1.0"}}}
        \\{"in":1,"str":{"pre":0,"str":"P"}}
        \\{"ie":0,"sort":0}
        \\{"axiom":{"name":1,"levelParams":[],"type":0,"isUnsafe":false}}
        \\{"ie":1,"const":{"name":1,"us":[]}}
        \\{"in":2,"str":{"pre":0,"str":"forged"}}
        \\{"thm":{"name":2,"levelParams":[],"type":1}}
    ;
    try std.testing.expectError(error.InvalidInput, checkFixture(input));
}

test "large numeric name components remain distinct without floating-point rounding" {
    const input =
        \\{"meta":{"format":{"version":"3.1.0"}}}
        \\{"in":1,"num":{"pre":0,"i":18446744073709551616}}
        \\{"in":2,"num":{"pre":0,"i":18446744073709551617}}
        \\{"ie":0,"sort":0}
        \\{"axiom":{"name":1,"levelParams":[],"type":0,"isUnsafe":false}}
        \\{"axiom":{"name":2,"levelParams":[],"type":0,"isUnsafe":false}}
    ;
    try checkFixture(input);
}
test "substitution respects nested binders and local storage" {
    var l = level.Pool.init(std.testing.allocator);
    defer l.deinit();
    var m = expr.Pool.init(std.testing.allocator, &l);
    defer m.deinit();
    const prop = m.sort(0);
    const body = m.binder(.lam, prop, m.bvar(1));
    m.temporary = true;
    const x = m.fvar(prop);
    const r = m.inst(body, x);
    try std.testing.expectEqual(x, m.get(r).b);
    try std.testing.expectEqual(body, m.abstract(r, &.{x}));
}

test "reverse substitution preserves binder depth, open arguments, and argument order" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const prop = expressions.sort(0);
    const term = expressions.binder(.lam, expressions.bvar(0), expressions.apps(expressions.bvar(3), &.{ expressions.bvar(2), expressions.bvar(1), expressions.bvar(0) }));
    const outer_first = [_]expr.Expr{ expressions.bvar(2), prop, expressions.bvar(0) };
    const inner_first = [_]expr.Expr{ outer_first[2], outer_first[1], outer_first[0] };
    const expected = expressions.instantiate(term, &inner_first);
    try std.testing.expectEqual(expected, expressions.instantiateReverse(term, &outer_first));
    try std.testing.expectEqualSlices(expr.Expr, &.{ expressions.bvar(2), prop, expressions.bvar(0) }, &outer_first);
}

test "unchecked propositional Pi inference cannot bypass checked domain validation" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    const proposition = expressions.fvar(prop);
    const invalid_domain = expressions.cnst(environment.builtin("Nat"), 0);
    const invalid = expressions.binder(.pi, invalid_domain, proposition);
    try std.testing.expectEqual(prop, try checker.infer(invalid, false));
    try std.testing.expectError(error.UnknownConstant, checker.infer(invalid, true));
}

test "beta reduction preserves argument order through dependent binders" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const proposition = expressions.fvar(expressions.sort(0));
    const first = expressions.fvar(proposition);
    const second = expressions.fvar(proposition);
    // fun (P : Prop) (p : P) (q : P) => p
    const function = expressions.binder(.lam, expressions.sort(0), expressions.binder(.lam, expressions.bvar(0), expressions.binder(.lam, expressions.bvar(1), expressions.bvar(1))));
    const application = expressions.apps(function, &.{ proposition, first, second });
    try std.testing.expectEqual(first, try checker.whnf(application));
    try std.testing.expectEqual(proposition, try checker.infer(application, true));
}

test "temporary expression budget declines before checking a term" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    checker.max_temporary_nodes = 0;
    const local = expressions.fvar(expressions.sort(0));
    try std.testing.expectError(error.ResourceLimit, checker.infer(local, true));
}

test "eager reduction has a separate core cache" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const natural = expressions.cnst(environment.builtin("Nat"), 0);
    const variable = expressions.fvar(natural);
    const ignored_argument = expressions.app(expressions.binder(.lam, natural, primitive.nat(&checker, 5)), variable);
    const application = expressions.apps(expressions.cnst(environment.builtin("Nat.add"), 0), &.{ primitive.nat(&checker, 1), ignored_argument });
    try std.testing.expectEqual(application, try checker.reduce(application, false));
    checker.eager_reduce = true;
    try std.testing.expectEqual(primitive.nat(&checker, 6), try checker.reduce(application, false));
    checker.eager_reduce = false;
    try std.testing.expectEqual(application, try checker.reduce(application, false));
}

test "batched inference exposes a function type returned through a type parameter" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    const proposition = expressions.fvar(prop);
    const endomorphism = expressions.binder(.pi, proposition, proposition);
    const polymorphic_type = expressions.binder(.pi, prop, expressions.binder(.pi, expressions.bvar(0), expressions.bvar(1)));
    const function = expressions.fvar(polymorphic_type);
    const argument = expressions.fvar(endomorphism);
    const proof = expressions.fvar(proposition);
    const application = expressions.apps(function, &.{ endomorphism, argument, proof });
    try std.testing.expectEqual(proposition, try checker.infer(application, false));
    try std.testing.expectEqual(proposition, try checker.infer(application, true));
}

test "batched binder comparison preserves dependent domains and rejects changed results" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    const first = expressions.binder(.pi, prop, expressions.binder(.pi, expressions.bvar(0), expressions.bvar(1)));
    const aliased_domain = expressions.mk(.letE, prop, expressions.bvar(0), expressions.bvar(0));
    const second = expressions.binder(.pi, prop, expressions.binder(.pi, aliased_domain, expressions.bvar(1)));
    try std.testing.expect(try checker.defeq(first, second));
    const other_proposition = expressions.fvar(prop);
    const changed = expressions.binder(.pi, prop, expressions.binder(.pi, expressions.bvar(0), other_proposition));
    try std.testing.expect(!try checker.defeq(first, changed));
}

test "expected-type checking shares lambdas and still rejects a changed type" {
    const allocator = std.testing.allocator;
    var levels = level.Pool.init(allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    const identity = expressions.binder(.lam, prop, expressions.bvar(0));
    const expected = expressions.binder(.pi, prop, prop);
    _ = try checker.ensure(try checker.infer(expected, true), .sort);
    try @import("inference.zig").checkAgainst(&checker, identity, expected);
    const next_local = expressions.next_fvar;
    try @import("inference.zig").checkAgainst(&checker, identity, expected);
    try std.testing.expectEqual(next_local, expressions.next_fvar);
    const changed = expressions.binder(.pi, prop, expressions.sort(levels.succ(0)));
    try std.testing.expectError(error.TypeMismatch, @import("inference.zig").checkAgainst(&checker, identity, changed));
}

test "conversion variable reuse keeps nested binders distinct" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    const first = expressions.binder(.lam, prop, expressions.binder(.lam, prop, expressions.bvar(1)));
    const second = expressions.binder(.lam, prop, expressions.binder(.lam, prop, expressions.bvar(0)));
    try std.testing.expect(!try checker.defeq(first, second));
    const identity = expressions.binder(.lam, prop, expressions.bvar(0));
    const equivalent = expressions.binder(.lam, prop, expressions.binder(.lam, prop, expressions.app(identity, expressions.bvar(1))));
    try std.testing.expect(try checker.defeq(first, equivalent));
    try std.testing.expect(!try checker.defeq(second, equivalent));
    try std.testing.expectEqual(@as(u32, 0), checker.binder_depth);
}
