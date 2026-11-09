const std = @import("std");
const level = @import("../../src/level.zig");
const expr = @import("../../src/expr.zig");
const Environment = @import("../../src/environment.zig").Environment;
const Checker = @import("../../src/type_checker.zig").Checker;

test "delta priority avoids instantiating an unused polymorphic body" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const parameter_name = environment.named("u");
    const parameter = levels.param(parameter_name);
    const type_ = expressions.sort(levels.succ(parameter));
    const value = expressions.sort(parameter);
    var body = value;
    for (0..1024) |_| body = expressions.mk(.letE, type_, value, body);
    const target_name = environment.named("LargeType");
    const alias_name = environment.named("TypeAlias");
    const parameters = [_]u32{parameter_name};
    try environment.add(.{ .name = target_name, .kind = .definition, .ty = type_, .value = body, .params = &parameters, .height = 0 });
    try environment.add(.{ .name = alias_name, .kind = .definition, .ty = type_, .value = expressions.cnst(target_name, expressions.list(&.{parameter})), .params = &parameters, .height = 1 });
    const target = expressions.cnst(target_name, expressions.list(&.{0}));
    const alias = expressions.cnst(alias_name, expressions.list(&.{0}));
    expressions.promotion_limit = 0;
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    checker.max_temporary_nodes = 64;
    // Only the alias must unfold. Instantiating the target's thousand lets
    // would exhaust the budget despite none of them being needed.
    try std.testing.expect(try checker.defeq(alias, target));
}

test "identical open binder bodies do not bypass domain comparison" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    const type_ = expressions.sort(levels.succ(0));
    const body = expressions.binder(.pi, expressions.bvar(0), expressions.bvar(1));
    const first = expressions.binder(.pi, prop, body);
    const different_domain = expressions.binder(.pi, type_, body);
    try std.testing.expect(!try checker.defeq(first, different_domain));
    const equivalent_domain = expressions.mk(.letE, type_, prop, expressions.bvar(0));
    const equivalent = expressions.binder(.pi, equivalent_domain, body);
    try std.testing.expect(try checker.defeq(first, equivalent));
    try std.testing.expectEqual(@as(u32, 0), checker.binder_depth);
}

test "local result classification preserves zero and unknown universes" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const name = environment.named("u");
    const parameter = levels.param(name);
    const parameters = [_]u32{name};
    checker.params = &parameters;
    for ([_]u32{ 0, parameter, levels.succ(parameter) }) |universe| {
        const type_ = expressions.fvar(expressions.sort(universe));
        const function_type = expressions.binder(.pi, type_, type_);
        const left = expressions.fvar(function_type);
        const right = expressions.fvar(function_type);
        const argument = expressions.fvar(type_);
        try std.testing.expectEqual(universe == 0, try checker.defeq(expressions.app(left, argument), expressions.app(right, argument)));
    }
    // The result is a bound type argument; specializing that argument to a
    // proposition must still enable proof irrelevance.
    const prop = expressions.sort(0);
    const polymorphic_type = expressions.binder(.pi, prop, expressions.bvar(0));
    const left = expressions.fvar(polymorphic_type);
    const right = expressions.fvar(polymorphic_type);
    const proposition = expressions.fvar(prop);
    try std.testing.expect(try checker.defeq(expressions.app(left, proposition), expressions.app(right, proposition)));
}

test "scoped inference abstracts dependent results and distinguishes shadowed domains" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    // fun (P Q : Prop) (p : P) => p. P and Q have identical domains but
    // distinct scopes; the inferred result must mention P, not Q.
    const term = expressions.binder(.lam, prop, expressions.binder(.lam, prop, expressions.binder(.lam, expressions.bvar(1), expressions.bvar(0))));
    const expected = expressions.binder(.pi, prop, expressions.binder(.pi, prop, expressions.binder(.pi, expressions.bvar(1), expressions.bvar(2))));
    const wrong = expressions.binder(.pi, prop, expressions.binder(.pi, prop, expressions.binder(.pi, expressions.bvar(1), expressions.bvar(1))));
    const unchecked = try checker.infer(term, false);
    const checked = try checker.infer(term, true);
    try std.testing.expect(try checker.defeq(expected, unchecked));
    try std.testing.expect(try checker.defeq(expected, checked));
    try std.testing.expect(!expressions.hasFreeVariables(checked));
    try std.testing.expectError(error.TypeMismatch, @import("../../src/inference.zig").checkAgainst(&checker, term, wrong));
    try std.testing.expectEqual(@as(u32, 0), checker.binder_depth);

    // A let between surrounding scopes must retain its own value and leave
    // the same dependent result after the let-local is substituted away.
    const let_body = expressions.mk(.letE, expressions.bvar(2), expressions.bvar(0), expressions.bvar(0));
    const with_let = expressions.binder(.lam, prop, expressions.binder(.lam, prop, expressions.binder(.lam, expressions.bvar(1), let_body)));
    try @import("../../src/inference.zig").checkAgainst(&checker, with_let, expected);
    try std.testing.expectError(error.TypeMismatch, @import("../../src/inference.zig").checkAgainst(&checker, with_let, wrong));
    try std.testing.expectEqual(@as(u32, 0), checker.binder_depth);
}

test "shared inference locals never turn unchecked arguments into checked proofs" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const prop = expressions.sort(0);
    // fun (P Q : Prop) (p : P) (f : Q -> Q) => f p is ill typed.
    const function_type = expressions.binder(.pi, expressions.bvar(1), expressions.bvar(2));
    const application = expressions.app(expressions.bvar(0), expressions.bvar(1));
    const invalid = expressions.binder(.lam, prop, expressions.binder(.lam, prop, expressions.binder(.lam, expressions.bvar(1), expressions.binder(.lam, function_type, application))));
    _ = try checker.infer(invalid, false);
    try std.testing.expectError(error.TypeMismatch, checker.infer(invalid, true));
    try std.testing.expectEqual(@as(u32, 0), checker.binder_depth);
}

test "monomorphic declaration shortcuts retain universe arity checks" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const name = environment.named("Monomorphic");
    const value = expressions.sort(0);
    const type_ = expressions.sort(levels.succ(0));
    try environment.add(.{ .name = name, .kind = .definition, .ty = type_, .value = value });
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const valid = expressions.cnst(name, 0);
    const invalid = expressions.cnst(name, expressions.list(&.{0}));
    try std.testing.expectEqual(type_, try checker.constType(valid));
    try std.testing.expectEqual(@as(?expr.Expr, value), try checker.unfold(valid));
    try std.testing.expectError(error.TypeMismatch, checker.constType(invalid));
    try std.testing.expectError(error.TypeMismatch, checker.unfold(invalid));
}

test "inference memo hits respect budgets and reset before scratch IDs are reused" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const prop = expressions.sort(0);
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    checker.beginDeclaration();
    const cached = expressions.sort(levels.offset(0, 2));
    try std.testing.expect(!expr.Pool.isPermanent(cached));
    const type_ = try checker.infer(cached, true);
    try std.testing.expectEqual(type_, try checker.infer(cached, false));
    checker.speculation_limit = checker.ticks;
    try std.testing.expectError(error.SpeculationLimit, checker.infer(cached, true));

    expressions.reset();
    checker.beginDeclaration();
    const loose = expressions.bvar(0);
    try std.testing.expectEqual(cached, loose);
    try std.testing.expectError(error.LooseVariable, checker.infer(loose, true));
    try std.testing.expectError(error.LooseVariable, checker.infer(loose, false));
    const variable = expressions.fvar(prop);
    try std.testing.expectEqual(prop, try checker.infer(variable, true));
    try std.testing.expectEqual(prop, try checker.infer(variable, false));
}

test "constant-type profiling excludes overlays and separates permanent substitutions" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    expressions.promotion_limit = 0;
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const parameter_name = environment.named("u");
    const parameter = levels.param(parameter_name);
    const name = environment.named("ProfiledType");
    const parameters = [_]u32{parameter_name};
    const declaration: @import("../../src/environment.zig").Decl = .{
        .name = name,
        .kind = .axiom,
        .ty = expressions.sort(levels.succ(parameter)),
        .params = &parameters,
    };
    try environment.add(declaration);
    const temporary = expressions.cnst(name, expressions.list(&.{0}));
    const identity = expressions.cnst(name, expressions.list(&.{parameter}));
    const permanent = expressions.cnst(name, expressions.list(&.{levels.succ(0)}));
    const permanent_type = expressions.sort(levels.offset(0, 2));
    var worker_environment = environment.fork();
    defer worker_environment.deinit();
    var checker = Checker.init(&expressions, &worker_environment);
    defer checker.deinit();
    checker.substitution_profile.enabled = true;
    checker.beginDeclaration();
    _ = try checker.constType(temporary);
    try std.testing.expectEqual(declaration.ty, try checker.constType(identity));
    try std.testing.expectEqual(permanent_type, try checker.constType(permanent));
    expressions.reset();
    checker.beginDeclaration();
    _ = try checker.constType(temporary);
    // A generated signature can coincide with an imported expression. Overlay
    // ownership still excludes it from the proposed retained-cache opportunity.
    try worker_environment.overlay.put(std.testing.allocator, name, declaration);
    checker.clearCaches();
    _ = try checker.constType(temporary);
    const totals = checker.substitution_profile.totals;
    try std.testing.expectEqual(@as(u64, 2), totals.nonidentity_misses);
    try std.testing.expectEqual(@as(u64, 2), totals.generated_nodes);
    try std.testing.expectEqual(@as(u64, 1), totals.repeated_misses);
    try std.testing.expectEqual(@as(u64, 1), totals.repeated_nodes);
    try std.testing.expectEqual(@as(u64, 1), totals.identity_misses);
    try std.testing.expectEqual(@as(u64, 1), totals.permanent_misses);
    try std.testing.expectEqual(@as(u64, 1), totals.excluded_misses);
    try std.testing.expect(!expressions.profile);
}

test "direct lambda comparison retains proof irrelevance and data inequality" {
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
    const proof = expressions.fvar(proposition);
    const identity_proof = expressions.binder(.lam, proposition, expressions.bvar(0));
    const constant_proof = expressions.binder(.lam, proposition, proof);
    try std.testing.expect(try checker.defeq(identity_proof, constant_proof));
    const other_proposition = expressions.fvar(prop);
    const other_identity = expressions.binder(.lam, other_proposition, expressions.bvar(0));
    try std.testing.expect(!try checker.defeq(identity_proof, other_identity));
    const data_type = expressions.fvar(expressions.sort(levels.succ(0)));
    const first = expressions.fvar(data_type);
    const second = expressions.fvar(data_type);
    const first_function = expressions.binder(.lam, data_type, first);
    const second_function = expressions.binder(.lam, data_type, second);
    try std.testing.expect(!try checker.defeq(first_function, second_function));
    try std.testing.expectEqual(@as(u32, 0), checker.binder_depth);
}

test "batched data projections instantiate dependent fields and preserve alias fallback" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const type_ = expressions.sort(levels.succ(0));
    const type_one = expressions.sort(levels.offset(0, 2));
    const name = environment.named("DependentRecord");
    const ctor_name = environment.named("DependentRecord.mk");
    const constructors = [_]u32{ctor_name};
    try environment.add(.{ .name = name, .kind = .inductive, .ty = expressions.binder(.pi, type_, type_one), .details = environment.copyDetails(.{ .num_params = 1, .ctors = &constructors }) });
    // mk (A : Type) (x : A) (B : A -> Type) (y : B x) : Record A
    const result = expressions.app(expressions.cnst(name, 0), expressions.bvar(3));
    const y_type = expressions.app(expressions.bvar(0), expressions.bvar(1));
    const family_type = expressions.binder(.pi, expressions.bvar(1), type_);
    const constructor_type = expressions.binder(.pi, type_, expressions.binder(.pi, expressions.bvar(0), expressions.binder(.pi, family_type, expressions.binder(.pi, y_type, result))));
    var constructor: @import("../../src/environment.zig").Decl = .{ .name = ctor_name, .kind = .ctor, .ty = constructor_type, .details = environment.copyDetails(.{ .parent = name, .num_params = 1, .num_fields = 3 }) };
    try environment.add(constructor);
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const parameter = expressions.fvar(type_);
    const record_type = expressions.app(expressions.cnst(name, 0), parameter);
    const record = expressions.fvar(record_type);
    const first = expressions.mk(.proj, name, 0, record);
    const family = expressions.mk(.proj, name, 1, record);
    const last = expressions.mk(.proj, name, 2, record);
    const expected = expressions.app(family, first);
    try std.testing.expect(try checker.defeq(expected, try checker.infer(last, true)));

    // The same signature can be exposed only after delta reduction. Such
    // constructors must use the general path instead of assuming raw Pis.
    const alias = environment.named("ConstructorSignature");
    try environment.add(.{ .name = alias, .kind = .definition, .ty = type_one, .value = constructor_type });
    constructor.ty = expressions.cnst(alias, 0);
    environment.update(constructor);
    checker.clearCaches();
    try std.testing.expect(try checker.defeq(expected, try checker.infer(last, true)));
}

test "projection batching preserves dependent Prop elimination restrictions" {
    var levels = level.Pool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = expr.Pool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const prop = expressions.sort(0);
    const type_ = expressions.sort(levels.succ(0));
    const name = environment.named("ExistentialRecord");
    const ctor_name = environment.named("ExistentialRecord.mk");
    const constructors = [_]u32{ctor_name};
    const predicate_type = expressions.binder(.pi, expressions.bvar(0), prop);
    const record_type = expressions.binder(.pi, type_, expressions.binder(.pi, predicate_type, prop));
    try environment.add(.{ .name = name, .kind = .inductive, .ty = record_type, .details = environment.copyDetails(.{ .num_params = 2, .ctors = &constructors }) });
    // mk (A : Type) (P : A -> Prop) (x : A) (h : P x) : Record A P
    const result = expressions.apps(expressions.cnst(name, 0), &.{ expressions.bvar(3), expressions.bvar(2) });
    const proof_type = expressions.app(expressions.bvar(1), expressions.bvar(0));
    const constructor_type = expressions.binder(.pi, type_, expressions.binder(.pi, predicate_type, expressions.binder(.pi, expressions.bvar(1), expressions.binder(.pi, proof_type, result))));
    try environment.add(.{ .name = ctor_name, .kind = .ctor, .ty = constructor_type, .details = environment.copyDetails(.{ .parent = name, .num_params = 2, .num_fields = 2 }) });
    var checker = Checker.init(&expressions, &environment);
    defer checker.deinit();
    const parameter = expressions.fvar(type_);
    const predicate = expressions.fvar(expressions.binder(.pi, parameter, prop));
    const record = expressions.fvar(expressions.apps(expressions.cnst(name, 0), &.{ parameter, predicate }));
    try std.testing.expectError(error.InvalidProjection, checker.infer(expressions.mk(.proj, name, 0, record), true));
    try std.testing.expectError(error.InvalidProjection, checker.infer(expressions.mk(.proj, name, 1, record), true));
}
