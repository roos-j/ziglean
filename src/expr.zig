// Derived from microlean's ExprManager/ExprStore and loose-variable transforms.
// A handle is 32 bits; its high bit selects declaration-local scratch storage.
// Hash tables contain node indices only, never duplicate expression payloads.
const std = @import("std");
const c = @import("common.zig");
const LevelPool = @import("level.zig").Pool;
const TransformCache = @import("transform_cache.zig").Cache;
const StringPool = @import("string_pool.zig").StringPool;
pub const Expr = c.Expr;
pub const Kind = enum(u8) { bvar, sort, cnst, app, lam, pi, letE, proj, nat, str, fvar };
/// Fixed-width payload, deliberately avoiding a slice-bearing tagged union.
/// - app: (function, argument); lam/pi: (domain, body)
/// - letE: (type, value, body); proj: (type name, field index, structure)
/// - cnst: (name, interned universe list); sort/bvar/str: index in `a`
/// - nat: (low word, high word, 0), or (decimal-string index, 0, 1)
/// - fvar: (type, unique local ID, optional definition encoded as value + 1)
/// `range` and `flags` are derived metadata, excluded from structural identity.
pub const Node = extern struct {
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    range: u32 = 0,
    kind: Kind,
    flags: u8 = 0,
    reserved: u16 = 0,
};
comptime {
    std.debug.assert(@sizeOf(Node) == 20);
}
const local_bit: u32 = 0x80000000;
const param_flag: u8 = 1;
const fvar_flag: u8 = 2;
fn hash(n: Node) u32 {
    // Mix independent payload words in parallel before the final avalanche.
    // Avoid a serial multiply dependency for every field on the interning path.
    var h = (@as(u64, n.a) << 32) | n.b;
    h ^= @as(u64, n.c) *% 0x9e3779b185ebca87;
    h ^= @as(u64, @intFromEnum(n.kind)) *% 0xc2b2ae3d27d4eb4f;
    h = (h ^ (h >> 33)) *% 0x165667b19e3779f9;
    return @truncate(h ^ (h >> 32));
}
fn eql(a: Node, b: Node) bool {
    return a.kind == b.kind and a.a == b.a and a.b == b.b and a.c == b.c;
}
fn Store(comptime scratch: bool) type {
    return struct {
        const Self = @This();
        const Tag = if (scratch) u16 else u8;
        nodes: c.List(Node) = .{},
        slots: []u32 = &.{},
        tags: []Tag = &.{},
        epoch: u16 = 0x100,
        indexed_count: usize = 0,
        virtual: bool = false,
        owns_nodes: bool = true,
        region: @import("reserved_buffer.zig").Buffer = .{},
        fn deinit(s: *Self, a: std.mem.Allocator) void {
            if (s.owns_nodes) {
                if (s.virtual) s.region.deinit() else s.nodes.deinit(a);
            }
            a.free(s.slots);
            a.free(s.tags);
        }
        fn appendNode(s: *Self, allocator: std.mem.Allocator, node: Node) void {
            if (!s.virtual) return c.append(Node, &s.nodes, allocator, node);
            if (s.nodes.items.len == s.nodes.capacity) {
                s.region.ensure((s.nodes.items.len + 1) * @sizeOf(Node)) catch c.oom();
                const memory: [*]Node = @ptrCast(@alignCast(s.region.pointer.?));
                s.nodes.items = memory[0..s.nodes.items.len];
                s.nodes.capacity = s.region.committed / @sizeOf(Node);
            }
            s.nodes.appendAssumeCapacity(node);
        }
        pub fn clear(s: *Self) void {
            // Keep the fingerprint and generation in one compact load. Most
            // declarations are tiny even after a large proof grew this table.
            if (scratch) {
                s.epoch +%= 0x100;
                if (s.epoch == 0) {
                    @memset(s.tags, 0);
                    s.epoch = 0x100;
                }
            } else @memset(s.tags, 0);
            s.nodes.clearRetainingCapacity();
            s.indexed_count = 0;
        }
        inline fn occupied(s: *const Self, tag: Tag) bool {
            return if (scratch) tag & 0xff00 == s.epoch else tag != 0;
        }
        inline fn fingerprint(s: *const Self, value: u32) Tag {
            const byte: u8 = @truncate(value >> 24);
            return if (scratch) s.epoch | byte else byte | 1;
        }
        fn lookup(s: *const Self, n: Node) ?u32 {
            if (s.slots.len == 0) return null;
            const node_hash = hash(n);
            const tag = s.fingerprint(node_hash);
            var i: usize = node_hash & (s.slots.len - 1);
            while (s.occupied(s.tags[i])) : (i = (i + 1) & (s.slots.len - 1)) {
                if (s.tags[i] == tag) {
                    const id = s.slots[i] - 1;
                    if (eql(s.nodes.items[id], n)) return id;
                }
            }
            return null;
        }
        fn insert(s: *Self, a: std.mem.Allocator, n: Node) u32 {
            const node_hash = hash(n);
            const tag = s.fingerprint(node_hash);
            var slot: usize = 0;
            if (s.slots.len != 0) {
                slot = node_hash & (s.slots.len - 1);
                while (s.occupied(s.tags[slot])) : (slot = (slot + 1) & (s.slots.len - 1)) {
                    if (s.tags[slot] == tag) {
                        const id = s.slots[slot] - 1;
                        if (eql(s.nodes.items[id], n)) return id;
                    }
                }
            }
            if ((s.indexed_count + 1) * 10 >= s.slots.len * 7) {
                const slots = a.alloc(u32, @max(64, s.slots.len * 2)) catch c.oom();
                const tags = a.alloc(Tag, slots.len) catch c.oom();
                @memset(tags, 0);
                for (s.slots, s.tags) |entry, old_tag| {
                    if (!s.occupied(old_tag)) continue;
                    const id = entry - 1;
                    const old = s.nodes.items[id];
                    const old_hash = hash(old);
                    var i: usize = old_hash & (slots.len - 1);
                    while (tags[i] != 0) i = (i + 1) & (slots.len - 1);
                    slots[i] = @intCast(id + 1);
                    tags[i] = s.fingerprint(old_hash);
                }
                a.free(s.slots);
                a.free(s.tags);
                s.slots = slots;
                s.tags = tags;
                slot = node_hash & (slots.len - 1);
                while (tags[slot] != 0) slot = (slot + 1) & (slots.len - 1);
            }
            if (s.nodes.items.len >= local_bit - 1) c.oom();
            const id: u32 = @intCast(s.nodes.items.len);
            var stored = n;
            stored.reserved = 1;
            s.appendNode(a, stored);
            s.indexed_count += 1;
            s.slots[slot] = id + 1;
            s.tags[slot] = tag;
            return id;
        }
        fn appendRaw(s: *Self, allocator: std.mem.Allocator, node: Node) u32 {
            if (s.nodes.items.len >= local_bit - 1) c.oom();
            const id: u32 = @intCast(s.nodes.items.len);
            s.appendNode(allocator, node);
            return id;
        }
    };
}
pub const Pool = struct {
    allocator: std.mem.Allocator,
    levels: *LevelPool,
    global: Store(false) = .{},
    local: Store(true) = .{ .virtual = true, .region = .{ .granularity = 64 * 1024 } },
    temporary: bool = false,
    importing: bool = false,
    borrowed: bool = false,
    // A bounded collection of pure universe substitutions can be shared across
    // declarations. Its nodes refer only to permanent terms, never local IDs.
    promote: bool = false,
    promoted_nodes: usize = 0,
    promotion_limit: usize = 4 * 1024 * 1024,
    constant_types: @import("check_cache.zig").Map(u64, Expr) = .{},
    definition_values: @import("check_cache.zig").Map(u64, Expr) = .{},
    profile: bool = false,
    transform_ns: [4]u64 = .{0} ** 4,
    transform_calls: [4]u64 = .{0} ** 4,
    next_fvar: u32 = 0,
    // Instantiation may invoke lifting, but transformations never re-enter
    // their own mode. Each mode therefore owns one reusable work table.
    transform_caches: [std.meta.fields(Mode).len]TransformCache = .{TransformCache{}} ** std.meta.fields(Mode).len,
    lists: c.List([2]u32) = .{},
    list_map: std.AutoHashMapUnmanaged([2]u32, u32) = .{},
    natural_strings: [2]StringPool,
    pub fn init(a: std.mem.Allocator, lm: *LevelPool) Pool {
        var m: Pool = .{ .allocator = a, .levels = lm, .natural_strings = .{ StringPool.init(a), StringPool.init(a) } };
        c.append([2]u32, &m.lists, a, .{ 0, 0 });
        return m;
    }
    pub fn deinit(m: *Pool) void {
        m.constant_types.deinit(m.allocator);
        m.definition_values.deinit(m.allocator);
        for (&m.transform_caches) |*cache| cache.deinit(m.allocator);
        if (!m.borrowed) m.global.deinit(m.allocator);
        m.local.deinit(m.allocator);
        m.lists.deinit(m.allocator);
        m.list_map.deinit(m.allocator);
        if (!m.borrowed) m.natural_strings[0].deinit();
        m.natural_strings[1].deinit();
    }
    pub fn fork(m: *const Pool, levels: *LevelPool) Pool {
        return .{
            .allocator = m.allocator,
            .levels = levels,
            .global = m.global,
            .borrowed = true,
            .promotion_limit = 0,
            .lists = .fromOwnedSlice(m.allocator.dupe([2]u32, m.lists.items) catch c.oom()),
            .list_map = m.list_map.clone(m.allocator) catch c.oom(),
            .natural_strings = .{ m.natural_strings[0], StringPool.init(m.allocator) },
        };
    }
    pub fn snapshot(m: *const Pool, levels: *LevelPool) Pool {
        std.debug.assert(m.global.virtual);
        var result = m.fork(levels);
        result.borrowed = false;
        result.global.owns_nodes = false;
        result.global.slots = m.allocator.dupe(u32, m.global.slots) catch c.oom();
        result.global.tags = m.allocator.dupe(u8, m.global.tags) catch c.oom();
        const strings = &result.natural_strings[0];
        strings.arena = std.heap.ArenaAllocator.init(m.allocator);
        strings.strings = .fromOwnedSlice(m.allocator.dupe([]const u8, strings.strings.items) catch c.oom());
        strings.indices = strings.indices.clone(m.allocator) catch c.oom();
        return result;
    }
    pub fn reset(m: *Pool) void {
        for (&m.transform_caches) |*cache| {
            if (cache.entries.len > 256 * 1024) cache.deinit(m.allocator);
        }
        if (m.local.nodes.capacity > 1024 * 1024) {
            m.local.deinit(m.allocator);
            m.local = .{ .virtual = true, .region = .{ .granularity = 64 * 1024 } };
        } else m.local.clear();
        m.natural_strings[1].clear();
        m.next_fvar = 0;
        m.temporary = false;
    }
    pub fn internNatural(m: *Pool, digits: []const u8) u32 {
        if (m.natural_strings[0].find(digits)) |index| return index;
        const pool_index: usize = @intFromBool(m.temporary);
        const index = m.natural_strings[pool_index].intern(digits);
        return if (m.temporary) index | local_bit else index;
    }

    pub fn naturalDigits(m: *const Pool, index: u32) []const u8 {
        return m.natural_strings[@intFromBool(index & local_bit != 0)].get(index & ~local_bit);
    }
    // Virtual stores keep immutable nodes at stable addresses. For ordinary
    // allocator-backed stores, force a scalar snapshot before any growth:
    // an inline struct return can otherwise alias reallocating storage in 0.14.
    pub inline fn get(m: *const Pool, e: Expr) Node {
        const pointer = if (e & local_bit == 0) &m.global.nodes.items[e] else &m.local.nodes.items[e & ~local_bit];
        const virtual = if (e & local_bit == 0) m.global.virtual else m.local.virtual;
        if (virtual) return pointer.*;
        const node: *const volatile Node = pointer;
        return .{ .a = node.a, .b = node.b, .c = node.c, .range = node.range, .kind = node.kind, .flags = node.flags };
    }
    inline fn scalar(m: *const Pool, e: Expr, comptime field: []const u8) @TypeOf(@field(@as(Node, undefined), field)) {
        const pointer = if (e & local_bit == 0) &m.global.nodes.items[e] else &m.local.nodes.items[e & ~local_bit];
        return @field(pointer.*, field);
    }
    pub inline fn kind(m: *const Pool, e: Expr) Kind {
        return m.scalar(e, "kind");
    }
    pub inline fn hasFreeVariables(m: *const Pool, e: Expr) bool {
        return m.scalar(e, "flags") & fvar_flag != 0;
    }
    pub fn isPermanent(e: Expr) bool {
        return e & local_bit == 0;
    }
    pub fn cons(m: *Pool, first: u32, tail: u32) u32 {
        const key = [2]u32{ first, tail };
        const r = m.list_map.getOrPut(m.allocator, key) catch c.oom();
        if (r.found_existing) return r.value_ptr.*;
        const id: u32 = @intCast(m.lists.items.len);
        r.value_ptr.* = id;
        c.append([2]u32, &m.lists, m.allocator, key);
        return id;
    }
    pub fn list(m: *Pool, values: []const u32) u32 {
        var r: u32 = 0;
        var i = values.len;
        while (i > 0) {
            i -= 1;
            r = m.cons(values[i], r);
        }
        return r;
    }
    pub fn listLen(m: *const Pool, x: u32) u32 {
        var n: u32 = 0;
        var p = x;
        while (p != 0) : (p = m.lists.items[p][1]) {
            n += 1;
        }
        return n;
    }
    pub fn listArray(m: *const Pool, x: u32, out: anytype) void {
        var p = x;
        while (p != 0) : (p = m.lists.items[p][1]) c.append(u32, out, m.allocator, m.lists.items[p][0]);
    }
    pub fn mk(m: *Pool, kind_: Kind, a: u32, b: u32, d: u32) Expr {
        var n: Node = .{ .kind = kind_, .a = a, .b = b, .c = d };
        switch (kind_) {
            .bvar => n.range = a + 1,
            .sort => n.flags = if (m.levels.hasParam(a)) param_flag else 0,
            .cnst => {
                var p = b;
                while (p != 0) : (p = m.lists.items[p][1]) {
                    if (m.levels.hasParam(m.lists.items[p][0])) {
                        n.flags = param_flag;
                        break;
                    }
                }
            },
            .app, .pi, .lam => {
                const right_range = m.scalar(b, "range");
                n.range = @max(m.scalar(a, "range"), if (kind_ == .app) right_range else right_range -| 1);
                n.flags = m.scalar(a, "flags") | m.scalar(b, "flags");
            },
            .letE => {
                n.range = @max(@max(m.scalar(a, "range"), m.scalar(b, "range")), m.scalar(d, "range") -| 1);
                n.flags = m.scalar(a, "flags") | m.scalar(b, "flags") | m.scalar(d, "flags");
            },
            .proj => {
                n.range = m.scalar(d, "range");
                n.flags = m.scalar(d, "flags");
            },
            .fvar => n.flags = fvar_flag | m.scalar(a, "flags"),
            .nat, .str => {},
        }
        const local_child = switch (kind_) {
            .app, .pi, .lam => (a | b) & local_bit != 0,
            .letE => (a | b | d) & local_bit != 0,
            .proj => d & local_bit != 0,
            .nat => d != 0 and a & local_bit != 0,
            else => false,
        };
        if (m.temporary) {
            // Imported terms contain no checker locals. Probing the large
            // permanent interning table for an open local term cannot succeed.
            if (n.flags & fvar_flag == 0 and !local_child) {
                const composite = switch (kind_) {
                    .app, .lam, .pi, .letE, .proj => true,
                    else => false,
                };
                if (!m.borrowed or !composite) {
                    if (m.global.lookup(n)) |id| return id;
                }
                if (m.promote and m.promoted_nodes < m.promotion_limit) {
                    const id = m.global.insert(m.allocator, n);
                    m.promoted_nodes += 1;
                    return id;
                }
            }
            return m.local.insert(m.allocator, n) | local_bit;
        }
        std.debug.assert(n.flags & fvar_flag == 0 and !local_child);
        // The exporter already shares its expression DAG. Composite input
        // nodes need no second interning table; leaves retain canonical IDs.
        if (m.importing) switch (kind_) {
            .app, .lam, .pi, .letE, .proj => return m.global.appendRaw(m.allocator, n),
            else => {},
        };
        return m.global.insert(m.allocator, n);
    }
    pub fn sort(m: *Pool, l: u32) Expr {
        return m.mk(.sort, l, 0, 0);
    }
    pub fn bvar(m: *Pool, i: u32) Expr {
        return m.mk(.bvar, i, 0, 0);
    }
    pub fn cnst(m: *Pool, name: u32, us: u32) Expr {
        return m.mk(.cnst, name, us, 0);
    }
    pub fn app(m: *Pool, f: Expr, a: Expr) Expr {
        return m.mk(.app, f, a, 0);
    }
    pub fn apps(m: *Pool, f: Expr, args: []const Expr) Expr {
        var r = f;
        for (args) |a| r = m.app(r, a);
        return r;
    }
    pub fn binder(m: *Pool, comptime k: Kind, ty: Expr, body: Expr) Expr {
        return m.mk(k, ty, body, 0);
    }
    pub fn fvar(m: *Pool, ty: Expr) Expr {
        const id = m.next_fvar;
        m.next_fvar += 1;
        return m.mk(.fvar, ty, id, 0);
    }
    /// Local definitions remain variables during inference. Their values are
    /// unfolded only when conversion or weak-head reduction requires them.
    pub fn letVariable(m: *Pool, ty: Expr, value: Expr) Expr {
        const id = m.next_fvar;
        m.next_fvar += 1;
        return m.mk(.fvar, ty, id, value + 1);
    }
    pub fn head(m: *const Pool, e: Expr) Expr {
        var r = e;
        while (m.kind(r) == .app) r = m.scalar(r, "a");
        return r;
    }
    pub fn unfoldApps(m: *const Pool, e: Expr, out: anytype) Expr {
        var r = e;
        const start = out.items.len;
        while (m.kind(r) == .app) {
            c.append(Expr, out, m.allocator, m.scalar(r, "b"));
            r = m.scalar(r, "a");
        }
        std.mem.reverse(Expr, out.items[start..]);
        return r;
    }
    const Mode = enum { inst, abstract, levels, lift };
    fn Transform(comptime mode: Mode, comptime reverse: bool) type {
        return struct {
            m: *Pool,
            values: []const u32,
            names: []const u32 = &.{},
            cache: *TransformCache,
            visited: usize = 0,
            fn go(t: *@This(), e: Expr, depth: u32) Expr {
                const m = t.m;
                switch (mode) {
                    .inst, .lift => if (m.scalar(e, "range") <= depth) return e,
                    .abstract => if (m.scalar(e, "flags") & fvar_flag == 0) return e,
                    .levels => if (m.scalar(e, "flags") & param_flag == 0) return e,
                }
                const n = m.get(e);
                if (n.kind == .bvar) {
                    if (mode == .inst) {
                        const index = n.a - depth;
                        return if (index < t.values.len) m.lift(t.values[if (reverse) t.values.len - 1 - index else index], depth) else m.bvar(n.a - @as(u32, @intCast(t.values.len)));
                    }
                    if (mode == .lift) return m.bvar(n.a + t.values[0]);
                    return e;
                }
                const key = @as(u64, e) | (@as(u64, depth) << 32);
                t.visited += 1;
                if (t.visited > 16) {
                    if (t.cache.get(key)) |v| return v;
                }
                const r: Expr = switch (n.kind) {
                    .bvar => unreachable, // Handled before memoization.
                    .fvar => blk: {
                        if (mode == .abstract) {
                            for (t.values, 0..) |v, i| {
                                if (v == e) break :blk m.bvar(depth + @as(u32, @intCast(t.values.len - 1 - i)));
                            }
                        }
                        break :blk e;
                    },
                    .sort => blk: {
                        if (mode != .levels) break :blk e;
                        const universe = m.levels.subst(n.a, t.names, t.values);
                        break :blk if (universe == n.a) e else m.sort(universe);
                    },
                    .cnst => blk: {
                        if (mode != .levels) break :blk e;
                        var us: c.SmallList(u32, 8) = .{};
                        defer us.deinit(m.allocator);
                        m.listArray(n.b, &us);
                        var changed = false;
                        for (us.items) |*u| {
                            const universe = m.levels.subst(u.*, t.names, t.values);
                            changed = changed or universe != u.*;
                            u.* = universe;
                        }
                        if (!changed) break :blk e;
                        break :blk m.cnst(n.a, m.list(us.items));
                    },
                    .app, .lam, .pi => blk: {
                        const a = t.go(n.a, depth);
                        const b = t.go(n.b, depth + @intFromBool(n.kind != .app));
                        break :blk if (a == n.a and b == n.b) e else m.mk(n.kind, a, b, 0);
                    },
                    .letE => blk: {
                        const a = t.go(n.a, depth);
                        const b = t.go(n.b, depth);
                        const value = t.go(n.c, depth + 1);
                        break :blk if (a == n.a and b == n.b and value == n.c) e else m.mk(.letE, a, b, value);
                    },
                    .proj => blk: {
                        const value = t.go(n.c, depth);
                        break :blk if (value == n.c) e else m.mk(.proj, n.a, n.b, value);
                    },
                    .nat, .str => e,
                };
                if (t.visited > 16) t.cache.put(m.allocator, key, r);
                return r;
            }
        };
    }
    fn transform(m: *Pool, comptime mode: Mode, comptime reverse: bool, e: Expr, values: []const u32, names: []const u32) Expr {
        var timer = if (m.profile) std.time.Timer.start() catch unreachable else undefined;
        defer if (m.profile) {
            m.transform_ns[@intFromEnum(mode)] += timer.read();
            m.transform_calls[@intFromEnum(mode)] += 1;
        };
        var t: Transform(mode, reverse) = .{ .cache = &m.transform_caches[@intFromEnum(mode)], .m = m, .values = values, .names = names };
        t.cache.reset();
        return t.go(e, 0);
    }
    pub fn instantiate(m: *Pool, e: Expr, values: []const Expr) Expr {
        return m.instantiateOrdered(false, e, values);
    }
    /// Accept arguments in application order (outermost binder first).
    pub fn instantiateReverse(m: *Pool, e: Expr, values: []const Expr) Expr {
        return m.instantiateOrdered(true, e, values);
    }
    fn instantiateOrdered(m: *Pool, comptime reverse: bool, e: Expr, values: []const Expr) Expr {
        if (values.len == 0 or m.scalar(e, "range") == 0) return e;
        if (m.kind(e) == .bvar) {
            const index = m.scalar(e, "a");
            return if (index < values.len) values[if (reverse) values.len - 1 - index else index] else m.bvar(index - @as(u32, @intCast(values.len)));
        }
        return m.transform(.inst, reverse, e, values, &.{});
    }
    pub fn inst(m: *Pool, e: Expr, value: Expr) Expr {
        return m.instantiate(e, &.{value});
    }
    pub fn lift(m: *Pool, e: Expr, by: u32) Expr {
        if (by == 0 or m.scalar(e, "range") == 0) return e;
        if (m.kind(e) == .bvar) return m.bvar(m.scalar(e, "a") + by);
        return m.transform(.lift, false, e, &.{by}, &.{});
    }
    pub fn abstract(m: *Pool, e: Expr, vars: []const Expr) Expr {
        if (vars.len == 0 or !m.hasFreeVariables(e)) return e;
        if (m.kind(e) == .fvar) {
            for (vars, 0..) |variable, index| {
                if (variable == e) return m.bvar(@intCast(vars.len - 1 - index));
            }
            return e;
        }
        return m.transform(.abstract, false, e, vars, &.{});
    }
    pub fn substLevels(m: *Pool, e: Expr, names: []const u32, us: []const u32) Expr {
        if (names.len == 0 or m.scalar(e, "flags") & param_flag == 0) return e;
        var identity = true;
        for (names, us) |name, universe| {
            const node = m.levels.get(universe);
            if (node.kind != .param or node.a != name) {
                identity = false;
                break;
            }
        }
        if (identity) return e;
        return m.transform(.levels, false, e, us, names);
    }
    pub fn bind(m: *Pool, comptime k: Kind, vars: []const Expr, body: Expr) Expr {
        var r = body;
        var i = vars.len;
        while (i > 0) {
            i -= 1;
            r = m.binder(k, m.get(vars[i]).a, m.abstract(r, vars[i .. i + 1]));
        }
        return r;
    }
};
