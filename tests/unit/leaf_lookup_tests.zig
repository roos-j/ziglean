const std = @import("std");
const LevelPool = @import("../../src/level.zig").Pool;
const ExprPool = @import("../../src/expr.zig").Pool;

test "workers preserve imported leaf identities and isolate private universe leaves" {
    var levels = LevelPool.init(std.testing.allocator);
    defer levels.deinit();
    var expressions = ExprPool.init(std.testing.allocator, &levels);
    defer expressions.deinit();
    const parameter = levels.param(1);
    const imported_sort = expressions.sort(parameter);
    const universes = expressions.list(&.{parameter});
    const imported_constant = expressions.cnst(7, universes);
    const imported_empty = expressions.cnst(8, 0);
    const original_nodes = expressions.global.nodes.items.len;

    var worker_levels = levels.view();
    defer worker_levels.deinit();
    var worker = expressions.fork(&worker_levels);
    defer worker.deinit();
    worker.temporary = true;
    try std.testing.expectEqual(parameter, worker_levels.param(1));
    try std.testing.expectEqual(imported_sort, worker.sort(parameter));
    try std.testing.expectEqual(universes, worker.list(&.{parameter}));
    try std.testing.expectEqual(imported_constant, worker.cnst(7, universes));
    try std.testing.expectEqual(imported_empty, worker.cnst(8, 0));

    const private_level = worker_levels.param(99);
    try std.testing.expect(private_level >= worker_levels.base_length);
    const private_sort = worker.sort(private_level);
    try std.testing.expect(private_sort & 0x80000000 != 0);
    try std.testing.expectEqual(private_level, worker.get(private_sort).a);
    try std.testing.expectEqual(private_sort, worker.sort(private_level));
    const private_list = worker.list(&.{private_level});
    try std.testing.expect(private_list >= worker.universe_lists.base_length);
    const private_constant = worker.cnst(7, private_list);
    try std.testing.expect(private_constant & 0x80000000 != 0);
    try std.testing.expectEqual(private_list, worker.get(private_constant).b);
    try std.testing.expectEqual(private_constant, worker.cnst(7, private_list));

    // Even a new combination of imported levels belongs to the list overlay.
    const combined_list = worker.list(&.{ parameter, 0 });
    try std.testing.expect(combined_list >= worker.universe_lists.base_length);
    const combined_constant = worker.cnst(7, combined_list);
    try std.testing.expectEqual(combined_list, worker.get(combined_constant).b);
    try std.testing.expectEqual(original_nodes, expressions.global.nodes.items.len);
    worker.reset();
    worker.temporary = true;
    try std.testing.expectEqual(imported_sort, worker.sort(parameter));
    try std.testing.expectEqual(imported_constant, worker.cnst(7, universes));
    try std.testing.expectEqual(private_level, worker.get(worker.sort(private_level)).a);
    try std.testing.expectEqual(private_list, worker.get(worker.cnst(7, private_list)).b);
}
