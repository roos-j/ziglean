const std = @import("std");
const Importer = @import("../src/import.zig").Importer;
const Environment = @import("../src/environment.zig").Environment;
const ExprPool = @import("../src/expr.zig").Pool;
const LevelPool = @import("../src/level.zig").Pool;

fn apply(importer: *Importer, bytes: []const u8, json: bool) !void {
    if (!json) return importer.lineBytes(std.testing.allocator, bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try importer.line(parsed.value);
}

test "compressed name references preserve builtin aliases and affine page boundaries" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = ExprPool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    var importer = Importer.init(&expressions, &environment);
    defer importer.deinit();
    try apply(&importer, "{\"meta\":{\"format\":{\"version\":\"3.0.0\"}}}", false);
    var expected: [3073]u32 = undefined;
    expected[0] = 0;
    for (1..expected.len) |index| {
        var spelling_buffer: [32]u8 = undefined;
        const spelling = if (index == 5) "Nat" else if (index == 1025) "Fresh17" else try std.fmt.bufPrint(&spelling_buffer, "Fresh{d}", .{index});
        var line_buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"in\":{d},\"str\":{{\"pre\":0,\"str\":\"{s}\"}}}}", .{ index, spelling });
        try apply(&importer, line, false);
        expected[index] = environment.named(spelling);
        try std.testing.expectEqual(expected[index], try importer.names.get(@intCast(index)));
    }
    try std.testing.expectEqual(environment.builtin("Nat"), expected[5]);
    try std.testing.expectEqual(expected[17], expected[1025]);
    try std.testing.expectEqual(expected.len, importer.names.count());
    for (expected, 0..) |name, index| try std.testing.expectEqual(name, try importer.names.get(@intCast(index)));
    try std.testing.expectError(error.InvalidInput, importer.names.get(@intCast(expected.len)));
}

test "compressed name imports retain sparse aliases full-width IDs and duplicate rejection" {
    for ([_]bool{ false, true }) |json| {
        var levels = LevelPool.init(std.testing.allocator);
        defer levels.deinit();
        var expressions = ExprPool.init(std.testing.allocator, &levels);
        defer expressions.deinit();
        var environment = Environment.init(std.testing.allocator);
        defer environment.deinit();
        var importer = Importer.init(&expressions, &environment);
        defer importer.deinit();
        try apply(&importer, "{\"meta\":{\"format\":{\"version\":\"3.0.0\"}}}", json);
        for ([_][]const u8{
            "{\"in\":1,\"str\":{\"pre\":0,\"str\":\"Outer\"}}",
            "{\"in\":4294967295,\"str\":{\"pre\":0,\"str\":\"Outer\"}}",
            "{\"in\":8,\"str\":{\"pre\":0,\"str\":\"Outer\"}}",
            "{\"in\":2,\"str\":{\"pre\":1,\"str\":\"inner\"}}",
            "{\"in\":3,\"num\":{\"pre\":4294967295,\"i\":4294967295}}",
        }) |line| try apply(&importer, line, json);
        const outer = environment.named("Outer");
        try std.testing.expectEqual(outer, try importer.names.get(1));
        try std.testing.expectEqual(outer, try importer.names.get(8));
        try std.testing.expectEqual(outer, try importer.names.get(std.math.maxInt(u32)));
        try std.testing.expectEqual(environment.named("Outer.inner"), try importer.names.get(2));
        const numeric = environment.names.items[try importer.names.get(3)];
        try std.testing.expect(numeric.numeric);
        try std.testing.expectEqual(outer, numeric.pre);
        try std.testing.expectEqualStrings("4294967295", environment.getString(numeric.atom));
        try std.testing.expectEqual(@as(usize, 6), importer.names.count());

        for ([_][]const u8{
            "{\"in\":0,\"str\":{\"pre\":0,\"str\":\"replacement\"}}",
            "{\"in\":1,\"str\":{\"pre\":0,\"str\":\"replacement\"}}",
            "{\"in\":8,\"str\":{\"pre\":0,\"str\":\"replacement\"}}",
            "{\"in\":4294967295,\"str\":{\"pre\":0,\"str\":\"replacement\"}}",
            "{\"in\":4,\"str\":{\"pre\":7,\"str\":\"missing\"}}",
            "{\"il\":2,\"param\":7}",
            "{\"const\":{\"name\":7,\"us\":[]},\"ie\":0}",
        }) |line| try std.testing.expectError(error.InvalidInput, apply(&importer, line, json));
        try std.testing.expectEqual(@as(usize, 6), importer.names.count());
        try std.testing.expectEqual(@as(u32, 0), try importer.names.get(0));
        try std.testing.expectEqual(outer, try importer.names.get(1));
        try std.testing.expectEqual(outer, try importer.names.get(8));
        try std.testing.expectEqual(outer, try importer.names.get(std.math.maxInt(u32)));
        try std.testing.expectError(error.InvalidInput, importer.names.get(4));
        try std.testing.expectError(error.InvalidInput, importer.names.get(7));

        try apply(&importer, "{\"in\":4,\"str\":{\"pre\":3,\"str\":\"leaf\"}}", json);
        try std.testing.expectEqual(try importer.names.get(3), environment.names.items[try importer.names.get(4)].pre);
        try apply(&importer, "{\"il\":1,\"param\":4294967295}", json);
        try apply(&importer, "{\"const\":{\"name\":8,\"us\":[1]},\"ie\":0}", json);
        const constant = expressions.get(try importer.exprs.get(0));
        try std.testing.expectEqual(outer, constant.a);
        const universe = expressions.listNode(constant.b)[0];
        try std.testing.expectEqual(outer, levels.get(universe).a);
        try std.testing.expectEqual(@as(usize, 7), importer.names.count());
    }
}
