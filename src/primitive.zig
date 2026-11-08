//! Lean's trusted literal reductions. Small naturals stay inline in expression
//! nodes; larger naturals use Zig's arbitrary-precision arithmetic.
const std = @import("std");
const common = @import("common.zig");
const Checker = @import("type_checker.zig").Checker;
const Pool = @import("expr.zig").Pool;
const Expr = common.Expr;
const Big = std.math.big.int.Managed;
const max_natural_bits: usize = 8 * 1024 * 1024;

pub fn nat(checker: *Checker, value: u64) Expr {
    return checker.expressions.mk(.nat, @truncate(value), @intCast(value >> 32), 0);
}

pub fn parseNatural(manager: *Pool, digits: []const u8) common.Error!Expr {
    if (digits.len == 0) return error.InvalidInput;
    for (digits) |digit| if (digit < '0' or digit > '9') return error.InvalidInput;
    var start: usize = 0;
    while (start + 1 < digits.len and digits[start] == '0') : (start += 1) {}
    const canonical = digits[start..];
    if (std.fmt.parseInt(u64, canonical, 10)) |value| {
        return manager.mk(.nat, @truncate(value), @intCast(value >> 32), 0);
    } else |_| {
        if (canonical.len > max_natural_bits / 3) return error.ResourceLimit;
        return manager.mk(.nat, manager.internNatural(canonical), 0, 1);
    }
}

pub fn number(checker: *Checker, expression: Expr) ?u64 {
    const node = checker.expressions.get(expression);
    if (node.kind == .nat and node.c == 0) return @as(u64, node.a) | (@as(u64, node.b) << 32);
    if (node.kind == .cnst and node.a == checker.environment.builtin("Nat.zero")) return 0;
    return null;
}

fn isNatural(checker: *Checker, expression: Expr) bool {
    return checker.expressions.kind(expression) == .nat or number(checker, expression) != null;
}

fn toBig(checker: *Checker, expression: Expr) Big {
    var result = Big.init(checker.expressions.allocator) catch common.oom();
    if (number(checker, expression)) |value| {
        result.set(value) catch common.oom();
    } else {
        const node = checker.expressions.get(expression);
        result.setString(10, checker.expressions.naturalDigits(node.a)) catch common.oom();
    }
    return result;
}

fn fromBig(checker: *Checker, value: Big) common.Error!Expr {
    if (value.toInt(u64)) |small| return nat(checker, small) else |_| {}
    if (value.bitCountAbs() > max_natural_bits) return error.ResourceLimit;
    const digits = value.toString(checker.expressions.allocator, 10, .lower) catch common.oom();
    defer checker.expressions.allocator.free(digits);
    return parseNatural(checker.expressions, digits);
}

pub fn expand(checker: *Checker, expression: Expr) common.Error!Expr {
    const manager = checker.expressions;
    const node = manager.get(expression);
    switch (node.kind) {
        .nat => {
            const predecessor = if (number(checker, expression)) |value| blk: {
                if (value == 0) return manager.cnst(checker.environment.builtin("Nat.zero"), 0);
                break :blk nat(checker, value - 1);
            } else blk: {
                var value = toBig(checker, expression);
                defer value.deinit();
                value.addScalar(&value, @as(i32, -1)) catch common.oom();
                break :blk try fromBig(checker, value);
            };
            return manager.app(manager.cnst(checker.environment.builtin("Nat.succ"), 0), predecessor);
        },
        .str => return expandString(checker, checker.environment.getString(node.a)),
        else => return expression,
    }
}

fn expandString(checker: *Checker, bytes: []const u8) common.Error!Expr {
    const manager = checker.expressions;
    const view = std.unicode.Utf8View.init(bytes) catch return error.InvalidInput;
    var iterator = view.iterator();
    var codepoints: common.List(u21) = .{};
    defer codepoints.deinit(manager.allocator);
    while (iterator.nextCodepoint()) |codepoint| common.append(u21, &codepoints, manager.allocator, codepoint);
    const character = manager.cnst(checker.environment.builtin("Char"), 0);
    const levels = manager.list(&.{0});
    const cons = manager.app(manager.cnst(checker.environment.builtin("List.cons"), levels), character);
    var result = manager.app(manager.cnst(checker.environment.builtin("List.nil"), levels), character);
    var index = codepoints.items.len;
    while (index > 0) {
        index -= 1;
        const value = manager.app(manager.cnst(checker.environment.builtin("Char.ofNat"), 0), nat(checker, codepoints.items[index]));
        result = manager.apps(cons, &.{ value, result });
    }
    const constructor = if (checker.environment.find(checker.environment.builtin("String.ofList")) != null) checker.environment.builtin("String.ofList") else checker.environment.builtin("String.mk");
    return manager.app(manager.cnst(constructor, 0), result);
}

const Operation = enum { add, sub, mul, div, mod, pow, gcd, beq, ble, land, lor, xor, shiftLeft, shiftRight };

fn reduceSmall(checker: *Checker, operation: Operation, left: u64, right: u64) ?Expr {
    const result: u64 = switch (operation) {
        .add => std.math.add(u64, left, right) catch return null,
        .sub => left -| right,
        .mul => std.math.mul(u64, left, right) catch return null,
        .div => if (right == 0) 0 else left / right,
        .mod => if (right == 0) left else left % right,
        .pow => std.math.powi(u64, left, right) catch return null,
        .gcd => if (left == 0) right else if (right == 0) left else std.math.gcd(left, right),
        .land => left & right,
        .lor => left | right,
        .xor => left ^ right,
        .shiftLeft => if (left == 0) 0 else if (right >= 64 or left > (@as(u64, std.math.maxInt(u64)) >> @intCast(right))) return null else left << @intCast(right),
        .shiftRight => if (right >= 64) 0 else left >> @intCast(right),
        .beq, .ble => return checker.expressions.cnst((if (if (operation == .beq) left == right else left <= right) checker.environment.builtin("Bool.true") else checker.environment.builtin("Bool.false")), 0),
    };
    return nat(checker, result);
}

fn reduceBig(checker: *Checker, operation: Operation, left_expression: Expr, right_expression: Expr) common.Error!Expr {
    var left = toBig(checker, left_expression);
    defer left.deinit();
    var right = toBig(checker, right_expression);
    defer right.deinit();
    var result = Big.init(checker.expressions.allocator) catch common.oom();
    defer result.deinit();
    const order = Big.order(left, right);
    switch (operation) {
        .add => result.add(&left, &right) catch common.oom(),
        .sub => if (order == .lt) return nat(checker, 0) else result.sub(&left, &right) catch common.oom(),
        .mul => result.mul(&left, &right) catch common.oom(),
        .div, .mod => {
            if (right.toConst().orderAgainstScalar(@as(u32, 0)) == .eq) return if (operation == .div) nat(checker, 0) else left_expression;
            var remainder = Big.init(checker.expressions.allocator) catch common.oom();
            defer remainder.deinit();
            result.divTrunc(&remainder, &left, &right) catch common.oom();
            if (operation == .mod) return fromBig(checker, remainder);
        },
        .gcd => {
            if (left.toConst().orderAgainstScalar(@as(u32, 0)) == .eq) return right_expression;
            if (right.toConst().orderAgainstScalar(@as(u32, 0)) == .eq) return left_expression;
            result.gcd(&left, &right) catch common.oom();
        },
        .beq, .ble => return checker.expressions.cnst((if (if (operation == .beq) order == .eq else order != .gt) checker.environment.builtin("Bool.true") else checker.environment.builtin("Bool.false")), 0),
        .land => result.bitAnd(&left, &right) catch common.oom(),
        .lor => result.bitOr(&left, &right) catch common.oom(),
        .xor => result.bitXor(&left, &right) catch common.oom(),
        .pow, .shiftLeft, .shiftRight => {
            const count = right.toInt(u32) catch {
                if (operation == .shiftRight) return nat(checker, 0);
                return error.ResourceLimit;
            };
            const bits = left.bitCountAbs();
            if (operation == .pow) {
                if (count != 0 and bits > max_natural_bits / count) return error.ResourceLimit;
                result.pow(&left, count) catch common.oom();
            } else if (operation == .shiftLeft) {
                if (count > max_natural_bits or bits > max_natural_bits - count) return error.ResourceLimit;
                result.shiftLeft(&left, count) catch common.oom();
            } else result.shiftRight(&left, count) catch common.oom();
        },
    }
    return fromBig(checker, result);
}

pub fn reduce(checker: *Checker, function: Expr, arguments: []const Expr) common.Error!?Expr {
    const manager = checker.expressions;
    const node = manager.get(function);
    if (node.kind != .cnst or node.b != 0) return null;
    if (arguments.len == 1 and node.a == checker.environment.builtin("Nat.succ")) {
        const argument = try checker.whnf(arguments[0]);
        if (!isNatural(checker, argument)) return null;
        if (number(checker, argument)) |small| {
            if (small < std.math.maxInt(u64)) return nat(checker, small + 1);
        }
        var value = toBig(checker, argument);
        defer value.deinit();
        value.addScalar(&value, @as(u32, 1)) catch common.oom();
        return try fromBig(checker, value);
    }
    if (arguments.len != 2) return null;
    const operation: Operation = blk: {
        inline for (std.meta.fields(Operation)) |field| {
            if (node.a == checker.environment.builtin("Nat." ++ field.name)) break :blk @enumFromInt(field.value);
        }
        return null;
    };
    const left = try checker.whnf(arguments[0]);
    if (!isNatural(checker, left)) return null;
    const right = try checker.whnf(arguments[1]);
    if (!isNatural(checker, right)) return null;
    if (number(checker, left)) |small_left| {
        if (number(checker, right)) |small_right| {
            if (reduceSmall(checker, operation, small_left, small_right)) |result| return result;
        }
    }
    return try reduceBig(checker, operation, left, right);
}
