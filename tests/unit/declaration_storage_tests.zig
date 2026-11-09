const std = @import("std");
const environment = @import("../../src/environment.zig");

test "ordinary declaration groups validate references without allocating details" {
    const allocator = std.testing.allocator;
    var levels = @import("../../src/level.zig").Pool.init(allocator);
    defer levels.deinit();
    var expressions = @import("../../src/expr.zig").Pool.init(allocator, &levels);
    defer expressions.deinit();
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    var importer = @import("../../src/import.zig").Importer.init(&expressions, &env);
    defer importer.deinit();
    const prefix =
        \\{"meta":{"format":{"version":"3.1.0"}}}
        \\{"in":1,"str":{"pre":0,"str":"Ordinary"}}
        \\{"ie":0,"sort":0}
    ;
    var lines = std.mem.tokenizeScalar(u8, prefix, '\n');
    while (lines.next()) |line| try importer.lineBytes(allocator, line);
    const plain = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":1,\"type\":0,\"levelParams\":[]}", .{});
    defer plain.deinit();
    const grouped = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":1,\"type\":0,\"levelParams\":[],\"all\":[1,1]}", .{});
    defer grouped.deinit();
    const plain_body = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":1,\"type\":0,\"value\":0,\"levelParams\":[]}", .{});
    defer plain_body.deinit();
    const grouped_body = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":1,\"type\":0,\"value\":0,\"levelParams\":[],\"all\":[1,1]}", .{});
    defer grouped_body.deinit();
    inline for (.{ environment.DeclKind.axiom, environment.DeclKind.definition, environment.DeclKind.theorem, environment.DeclKind.opaque_decl, environment.DeclKind.ctor }) |kind| {
        const has_body = kind == .definition or kind == .theorem or kind == .opaque_decl;
        const without_group = try importer.decl(if (has_body) plain_body.value else plain.value, kind);
        const with_group = try importer.decl(if (has_body) grouped_body.value else grouped.value, kind);
        try std.testing.expect(with_group.details == without_group.details);
        try std.testing.expectEqual(@as(usize, 0), with_group.details.all.len);
    }
    inline for (.{ environment.DeclKind.inductive, environment.DeclKind.recursor }) |kind| {
        const retained = try importer.decl(grouped.value, kind);
        try std.testing.expectEqual(@as(usize, 2), retained.details.all.len);
        try std.testing.expectEqual(retained.name, retained.details.all[0]);
        try std.testing.expectEqual(retained.name, retained.details.all[1]);
    }
    for ([_][]const u8{
        "{\"name\":1,\"type\":0,\"levelParams\":[],\"all\":1}",
        "{\"name\":1,\"type\":0,\"levelParams\":[],\"all\":[\"invalid\"]}",
        "{\"name\":1,\"type\":0,\"levelParams\":[],\"all\":[2]}",
    }) |bytes| {
        const malformed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer malformed.deinit();
        try std.testing.expectError(error.InvalidInput, importer.decl(malformed.value, .axiom));
    }
}

test "compact declaration details stay immutable across snapshots and worker resets" {
    var base = environment.Environment.init(std.testing.allocator);
    defer base.deinit();
    const name = base.named("SharedInductive");
    const constructor = base.named("SharedInductive.mk");
    const constructors = base.copy(u32, &.{constructor});
    const original: environment.Decl = .{
        .name = name,
        .kind = .inductive,
        .ty = 17,
        .details = base.copyDetails(.{ .ctors = constructors, .reflexive = true, .num_params = 3 }),
    };
    try base.add(original);
    base.enableConcurrentSnapshots();
    var snapshot = base.snapshot();
    defer snapshot.deinit();
    try std.testing.expect(snapshot.find(name).?.details == original.details);
    var worker = snapshot.fork();
    defer worker.deinit();
    worker.beginView(0);
    var derived = original;
    var details = original.details.*;
    details.recursive = true;
    details.reflexive = false;
    derived.details = worker.copyDetails(details);
    try worker.add(derived);
    try std.testing.expect(worker.find(name).?.details == derived.details);
    try std.testing.expect(!base.find(name).?.details.recursive);
    try std.testing.expect(snapshot.find(name).?.details.reflexive);

    // Arena growth and overlay reset must not invalidate copied metadata or
    // mutate the independently owned imported record.
    for (0..4096) |index| _ = worker.copyDetails(.{ .num_fields = @intCast(index) });
    try std.testing.expectEqual(@as(u32, 3), derived.details.num_params);
    try std.testing.expectEqual(constructor, derived.details.ctors[0]);
    worker.beginView(1);
    try std.testing.expect(worker.find(name).?.details == original.details);
    try std.testing.expect(derived.details.recursive);
    try std.testing.expect(!derived.details.reflexive);
    try std.testing.expect(@sizeOf(environment.Decl) <= 64);
}

test "inductive checking restores exported recursor details without changing shared records" {
    const allocator = std.testing.allocator;
    var levels = @import("../../src/level.zig").Pool.init(allocator);
    defer levels.deinit();
    var expressions = @import("../../src/expr.zig").Pool.init(allocator, &levels);
    defer expressions.deinit();
    var base = environment.Environment.init(allocator);
    defer base.deinit();
    var importer = @import("../../src/import.zig").Importer.init(&expressions, &base);
    defer importer.deinit();
    var lines = std.mem.tokenizeScalar(u8, @embedFile("../kernel/good/conversion.ndjson"), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"inductive\"")) {
            try importer.lineBytes(allocator, line);
            continue;
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const group = parsed.value.object.get("inductive").?;
        const type_ = try importer.decl(group.object.get("types").?.array.items[0], .inductive);
        const constructor = try importer.decl(group.object.get("ctors").?.array.items[0], .ctor);
        const recursor = try importer.decl(group.object.get("recs").?.array.items[0], .recursor);
        const type_before = type_.details.*;
        const recursor_before = recursor.details.*;
        const first: u32 = @intCast(base.decls.items.len);
        try base.add(type_);
        try base.add(constructor);
        try base.add(recursor);
        base.enableConcurrentSnapshots();
        var snapshot = base.snapshot();
        defer snapshot.deinit();
        var worker = snapshot.fork();
        defer worker.deinit();
        worker.beginView(first);
        var worker_levels = levels.view();
        defer worker_levels.deinit();
        var worker_expressions = expressions.fork(&worker_levels);
        defer worker_expressions.deinit();
        var checker = @import("../../src/type_checker.zig").Checker.init(&worker_expressions, &worker);
        defer checker.deinit();
        checker.beginDeclaration();
        try @import("../../src/inductive.zig").check(&checker, &.{type_}, &.{constructor}, &.{recursor});
        // check() has destroyed its generation arena. The installed recursor
        // must have returned to the original immutable exported metadata.
        try std.testing.expect(worker.find(recursor.name).?.details == recursor.details);
        try std.testing.expect(worker.find(type_.name).?.details == type_.details);
        try std.testing.expectEqualDeep(type_before, snapshot.find(type_.name).?.details.*);
        try std.testing.expectEqualDeep(recursor_before, snapshot.find(recursor.name).?.details.*);
        try std.testing.expectEqual(recursor_before.rules[0].rhs, worker.find(recursor.name).?.details.rules[0].rhs);
        worker.beginView(@intCast(snapshot.decls.items.len));
        try std.testing.expect(worker.find(recursor.name).?.details == recursor.details);
        return;
    }
    return error.MissingInductiveFixture;
}
