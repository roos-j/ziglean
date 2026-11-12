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
// Common imported terms use two 27-bit payloads, a three-bit kind, one
// parameter flag and a six-bit range in one aligned word. Kind 7 escapes to
// an exact Node for larger payloads, third words and uncommon expression kinds.
// The escape preserves all 32 bits of every logical payload and the range.
const GlobalNode = extern struct { bits: u64 };
const ScratchNode = extern struct { a: u32, b: u32, c: u32, metadata: u32 };
const payload_bits = 27;
const payload_mask: u32 = (1 << payload_bits) - 1;
const global_kind_shift = 2 * payload_bits;
const global_flag_shift = global_kind_shift + 3;
const global_range_shift = global_flag_shift + 1;
const global_escape_kind = 7;
const global_range_sentinel: u32 = 63;
// Scratch metadata retains its existing full-kind, two-flag and 24-bit range
// layout. Scratch ranges use an exact overflow map; imported overflows escape.
const range_shift = 8;
const wide_range_bit = 1 << 6;
comptime {
    std.debug.assert(@sizeOf(GlobalNode) == 8);
    std.debug.assert(@alignOf(GlobalNode) == 8);
    std.debug.assert(@sizeOf(ScratchNode) == 16);
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
        const StoredNode = if (scratch) ScratchNode else GlobalNode;
        const range_mask: u32 = std.math.maxInt(u32) >> range_shift;
        nodes: c.List(StoredNode) = .{},
        extra_payloads: c.List(Node) = .{},
        extra_region: @import("reserved_buffer.zig").Buffer = .{ .granularity = 64 * 1024 },
        wide_ranges: std.AutoHashMapUnmanaged(u32, u32) = .{},
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
                if (s.virtual) s.extra_region.deinit() else s.extra_payloads.deinit(a);
            }
            s.wide_ranges.deinit(a);
            a.free(s.slots);
            a.free(s.tags);
        }
        fn appendNode(s: *Self, allocator: std.mem.Allocator, node: Node) void {
            if (scratch) {
                var metadata: u32 = @intFromEnum(node.kind);
                metadata |= @as(u32, node.flags) << 4;
                metadata |= @as(u32, @min(node.range, range_mask)) << range_shift;
                if (node.range > range_mask) {
                    metadata |= wide_range_bit;
                    s.wide_ranges.put(allocator, @intCast(s.nodes.items.len), node.range) catch c.oom();
                }
                s.appendStored(allocator, .{ .a = node.a, .b = node.b, .c = node.c, .metadata = metadata });
                return;
            }
            // Imported expressions never contain checker-local free variables.
            std.debug.assert(node.flags & ~@as(u8, param_flag) == 0);
            const flags = @as(u64, node.flags) << global_flag_shift;
            const range = @as(u64, @min(node.range, global_range_sentinel)) << global_range_shift;
            if (@intFromEnum(node.kind) >= global_escape_kind or node.c != 0 or (node.a | node.b) > payload_mask or node.range >= global_range_sentinel) {
                const index: u32 = @intCast(s.extra_payloads.items.len);
                s.appendExtra(allocator, node);
                s.appendStored(allocator, .{ .bits = index | (@as(u64, global_escape_kind) << global_kind_shift) | flags | range });
                return;
            }
            s.appendStored(allocator, .{ .bits = @as(u64, node.a) | (@as(u64, node.b) << payload_bits) |
                (@as(u64, @intFromEnum(node.kind)) << global_kind_shift) | flags | range });
        }
        fn appendStored(s: *Self, allocator: std.mem.Allocator, stored: StoredNode) void {
            if (!s.virtual) return c.append(StoredNode, &s.nodes, allocator, stored);
            if (s.nodes.items.len == s.nodes.capacity) {
                s.region.ensure((s.nodes.items.len + 1) * @sizeOf(StoredNode)) catch c.oom();
                const memory: [*]StoredNode = @ptrCast(@alignCast(s.region.pointer.?));
                s.nodes.items = memory[0..s.nodes.items.len];
                s.nodes.capacity = s.region.committed / @sizeOf(StoredNode);
            }
            s.nodes.appendAssumeCapacity(stored);
        }
        fn appendBinary(s: *Self, allocator: std.mem.Allocator, comptime kind_: Kind, a: Expr, b: Expr) Expr {
            comptime std.debug.assert(!scratch and (kind_ == .app or kind_ == .pi or kind_ == .lam));
            if (s.nodes.items.len >= local_bit - 1) c.oom();
            const id: u32 = @intCast(s.nodes.items.len);
            const left_bits = s.nodes.items[a].bits;
            const right_bits = s.nodes.items[b].bits;
            const left_range: u32 = @intCast(left_bits >> global_range_shift);
            const right_range: u32 = @intCast(right_bits >> global_range_shift);
            const maximum = @max(left_range, right_range);
            if (maximum == global_range_sentinel or (a | b) > payload_mask) {
                @branchHint(.unlikely);
                return s.appendBinaryWide(allocator, kind_, id, a, b);
            }
            // Escaped children also retain ordinary range/flag metadata inline.
            const range = if (kind_ == .app) maximum else @max(left_range, right_range -| 1);
            const flags = (left_bits | right_bits) & (@as(u64, 1) << global_flag_shift);
            s.appendStored(allocator, .{ .bits = @as(u64, a) | (@as(u64, b) << payload_bits) |
                (@as(u64, @intFromEnum(kind_)) << global_kind_shift) | flags | (@as(u64, range) << global_range_shift) });
            return id;
        }
        noinline fn appendBinaryWide(s: *Self, allocator: std.mem.Allocator, comptime kind_: Kind, id: u32, a: Expr, b: Expr) Expr {
            const left_range = s.scalar(a, "range");
            const right_range = s.scalar(b, "range");
            const range = @max(left_range, if (kind_ == .app) right_range else right_range -| 1);
            s.appendNode(allocator, .{ .kind = kind_, .a = a, .b = b, .range = range, .flags = s.scalar(a, "flags") | s.scalar(b, "flags") });
            return id;
        }
        fn appendExtra(s: *Self, allocator: std.mem.Allocator, payload: Node) void {
            if (!s.virtual) return c.append(Node, &s.extra_payloads, allocator, payload);
            if (s.extra_payloads.items.len == s.extra_payloads.capacity) {
                s.extra_region.ensure((s.extra_payloads.items.len + 1) * @sizeOf(Node)) catch c.oom();
                const memory: [*]Node = @ptrCast(@alignCast(s.extra_region.pointer.?));
                s.extra_payloads.items = memory[0..s.extra_payloads.items.len];
                s.extra_payloads.capacity = s.extra_region.committed / @sizeOf(Node);
            }
            s.extra_payloads.appendAssumeCapacity(payload);
        }
        inline fn extra(s: *const Self, index: u32) Node {
            const pointer = &s.extra_payloads.items[index];
            if (s.virtual) return pointer.*;
            const source: *const volatile Node = pointer;
            return .{ .a = source.a, .b = source.b, .c = source.c, .range = source.range, .kind = source.kind, .flags = source.flags, .reserved = source.reserved };
        }
        inline fn get(s: *const Self, id: u32) Node {
            const pointer = &s.nodes.items[id];
            if (!scratch) {
                const source: *const volatile GlobalNode = pointer;
                const bits = if (s.virtual) pointer.bits else source.bits;
                const kind = (bits >> global_kind_shift) & 7;
                if (kind == global_escape_kind) return s.extra(@truncate(bits));
                const range: u32 = @intCast(bits >> global_range_shift);
                return .{
                    .a = @intCast(bits & payload_mask),
                    .b = @intCast((bits >> payload_bits) & payload_mask),
                    .kind = @enumFromInt(kind),
                    .flags = @intCast((bits >> global_flag_shift) & 1),
                    .range = range,
                };
            }
            // Ordinary allocator-backed arrays can move during recursion.
            // Snapshot their fields before any caller can grow the store.
            const node: StoredNode = if (s.virtual) pointer.* else blk: {
                const source: *const volatile StoredNode = pointer;
                break :blk .{ .a = source.a, .b = source.b, .c = source.c, .metadata = source.metadata };
            };
            return .{
                .a = node.a,
                .b = node.b,
                .c = node.c,
                .range = if (node.metadata & wide_range_bit != 0) s.wide_ranges.get(id).? else node.metadata >> range_shift,
                .kind = @enumFromInt(node.metadata & 15),
                .flags = @intCast((node.metadata >> 4) & 3),
            };
        }
        inline fn scalar(s: *const Self, id: u32, comptime field: []const u8) @TypeOf(@field(@as(Node, undefined), field)) {
            const node = &s.nodes.items[id];
            if (!scratch) {
                const bits = node.bits;
                if (comptime std.mem.eql(u8, field, "flags")) return @intCast((bits >> global_flag_shift) & 1);
                if (comptime std.mem.eql(u8, field, "range")) {
                    const range: u32 = @intCast(bits >> global_range_shift);
                    if (range != global_range_sentinel) return range;
                    return s.extra(@truncate(bits)).range;
                }
                const kind = (bits >> global_kind_shift) & 7;
                if (kind == global_escape_kind) return @field(s.extra(@truncate(bits)), field);
                if (comptime std.mem.eql(u8, field, "kind")) return @enumFromInt(kind);
                if (comptime std.mem.eql(u8, field, "a")) return @intCast(bits & payload_mask);
                if (comptime std.mem.eql(u8, field, "b")) return @intCast((bits >> payload_bits) & payload_mask);
                return 0;
            }
            if (comptime std.mem.eql(u8, field, "kind")) return @enumFromInt(node.metadata & 15);
            if (comptime std.mem.eql(u8, field, "flags")) return @intCast((node.metadata >> 4) & 3);
            if (comptime std.mem.eql(u8, field, "range")) return if (node.metadata & wide_range_bit != 0) s.wide_ranges.get(id).? else node.metadata >> range_shift;
            return @field(node.*, field);
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
            s.extra_payloads.clearRetainingCapacity();
            s.wide_ranges.clearRetainingCapacity();
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
                    if (eql(s.get(id), n)) return id;
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
                        if (eql(s.get(id), n)) return id;
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
                    const old = s.get(@intCast(id));
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
            s.appendNode(a, n);
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
    transform_ns: [std.meta.fields(Mode).len]u64 = .{0} ** std.meta.fields(Mode).len,
    transform_calls: [std.meta.fields(Mode).len]u64 = .{0} ** std.meta.fields(Mode).len,
    next_fvar: u32 = 0,
    // Instantiation may invoke lifting, but transformations never re-enter
    // their own mode. Each mode therefore owns one reusable work table.
    transform_caches: [std.meta.fields(Mode).len]TransformCache = .{TransformCache{}} ** std.meta.fields(Mode).len,
    universe_lists: @import("universe_lists.zig").Pool,
    natural_strings: [2]StringPool,
    pub fn init(a: std.mem.Allocator, lm: *LevelPool) Pool {
        return .{ .allocator = a, .levels = lm, .universe_lists = .init(a), .natural_strings = .{ StringPool.init(a), StringPool.init(a) } };
    }
    pub fn deinit(m: *Pool) void {
        m.constant_types.deinit(m.allocator);
        m.definition_values.deinit(m.allocator);
        for (&m.transform_caches) |*cache| cache.deinit(m.allocator);
        if (!m.borrowed) m.global.deinit(m.allocator);
        m.local.deinit(m.allocator);
        m.universe_lists.deinit();
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
            .universe_lists = m.universe_lists.view(),
            .natural_strings = .{ m.natural_strings[0], StringPool.init(m.allocator) },
        };
    }
    pub fn snapshot(m: *const Pool, levels: *LevelPool) Pool {
        std.debug.assert(m.global.virtual);
        var result = m.fork(levels);
        result.universe_lists = m.universe_lists.snapshot();
        result.borrowed = false;
        result.global.owns_nodes = false;
        result.global.slots = m.allocator.dupe(u32, m.global.slots) catch c.oom();
        result.global.tags = m.allocator.dupe(u8, m.global.tags) catch c.oom();
        result.global.wide_ranges = m.global.wide_ranges.clone(m.allocator) catch c.oom();
        const strings = &result.natural_strings[0];
        strings.arena = std.heap.ArenaAllocator.init(m.allocator);
        strings.strings = .fromOwnedSlice(m.allocator.dupe([]const u8, strings.strings.items) catch c.oom());
        strings.indices = strings.indices.clone(m.allocator) catch c.oom();
        return result;
    }
    pub fn reset(m: *Pool) void {
        for (&m.transform_caches) |*cache| {
            if (cache.entries.len > 64 * 1024) cache.deinit(m.allocator);
        }
        if (m.local.nodes.capacity > 64 * 1024) {
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
        return if (e & local_bit == 0) m.global.get(e) else m.local.get(e & ~local_bit);
    }
    inline fn scalar(m: *const Pool, e: Expr, comptime field: []const u8) @TypeOf(@field(@as(Node, undefined), field)) {
        return if (e & local_bit == 0) m.global.scalar(e, field) else m.local.scalar(e & ~local_bit, field);
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
        return m.universe_lists.cons(first, tail);
    }
    pub inline fn listNode(m: *const Pool, id: u32) [2]u32 {
        return m.universe_lists.get(id);
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
        while (p != 0) : (p = m.listNode(p)[1]) {
            n += 1;
        }
        return n;
    }
    pub fn listArray(m: *const Pool, x: u32, out: anytype) void {
        var p = x;
        while (p != 0) : (p = m.listNode(p)[1]) c.append(u32, out, m.allocator, m.listNode(p)[0]);
    }
    pub fn mk(m: *Pool, kind_: Kind, a: u32, b: u32, d: u32) Expr {
        var n: Node = .{ .kind = kind_, .a = a, .b = b, .c = d };
        switch (kind_) {
            .bvar => n.range = a + 1,
            .sort => n.flags = if (m.levels.hasParam(a)) param_flag else 0,
            .cnst => {
                var p = b;
                while (p != 0) : (p = m.listNode(p)[1]) {
                    if (m.levels.hasParam(m.listNode(p)[0])) {
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
                // A worker's derived universe IDs lie beyond the immutable
                // imported prefix, so no global leaf can contain them.
                const lookup_global = if (!m.borrowed) true else switch (kind_) {
                    .app, .lam, .pi, .letE, .proj => false,
                    .sort => m.levels.parent == null or a < m.levels.base_length,
                    .cnst => m.universe_lists.parent == null or b < m.universe_lists.base_length,
                    else => true,
                };
                if (lookup_global) {
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
        if (m.importing and !m.temporary and (f | a) & local_bit == 0) return m.global.appendBinary(m.allocator, .app, f, a);
        return m.mk(.app, f, a, 0);
    }
    pub fn apps(m: *Pool, f: Expr, args: []const Expr) Expr {
        var r = f;
        for (args) |a| r = m.app(r, a);
        return r;
    }
    pub fn binder(m: *Pool, comptime k: Kind, ty: Expr, body: Expr) Expr {
        if (m.importing and !m.temporary and (ty | body) & local_bit == 0) return m.global.appendBinary(m.allocator, k, ty, body);
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
    /// `inst_levels` substitutes bound variables and universe parameters in one
    /// traversal; the inserted values themselves are left untouched.
    const Mode = enum { inst, abstract, levels, lift, inst_levels };
    fn Transform(comptime mode: Mode, comptime reverse: bool) type {
        return struct {
            m: *Pool,
            values: []const u32,
            names: []const u32 = &.{},
            // Universe arguments of `inst_levels`; `levels` keeps them in `values`.
            universes: []const u32 = &.{},
            cache: *TransformCache,
            visited: usize = 0,
            recent_lists: [4][2]u32 = undefined,
            recent_count: usize = 0,
            const substitutes_levels = mode == .levels or mode == .inst_levels;
            inline fn levelValues(t: *const @This()) []const u32 {
                return if (mode == .levels) t.values else t.universes;
            }
            fn go(t: *@This(), e: Expr, depth: u32) Expr {
                const m = t.m;
                switch (mode) {
                    .inst, .lift => if (m.scalar(e, "range") <= depth) return e,
                    .abstract => if (m.scalar(e, "flags") & fvar_flag == 0) return e,
                    .levels => if (m.scalar(e, "flags") & param_flag == 0) return e,
                    .inst_levels => if (m.scalar(e, "range") <= depth and m.scalar(e, "flags") & param_flag == 0) return e,
                }
                const n = m.get(e);
                if (n.kind == .bvar) {
                    if (mode == .inst or mode == .inst_levels) {
                        const index = n.a - depth;
                        return if (index < t.values.len) m.lift(t.values[if (reverse) t.values.len - 1 - index else index], depth) else m.bvar(n.a - @as(u32, @intCast(t.values.len)));
                    }
                    if (mode == .lift) return m.bvar(n.a + t.values[0]);
                    return e;
                }
                // Universe substitution does not depend on term binders. Its
                // expression keys occupy the low word, including local IDs;
                // the separate high word also namespaces universe-list keys.
                const key = if (mode == .levels) @as(u64, e) else @as(u64, e) | (@as(u64, depth) << 32);
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
                        if (!substitutes_levels) break :blk e;
                        const universe = m.levels.subst(n.a, t.names, t.levelValues());
                        break :blk if (universe == n.a) e else m.sort(universe);
                    },
                    .cnst => blk: {
                        if (!substitutes_levels) break :blk e;
                        const universes = t.substUniverseList(n.b);
                        break :blk if (universes == n.b) e else m.cnst(n.a, universes);
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

            fn substUniverseList(t: *@This(), list_id: u32) u32 {
                // A body mentions few distinct universe lists, usually many
                // times each. Reuse them without hashing or re-interning.
                for (t.recent_lists[0..t.recent_count]) |entry| {
                    if (entry[0] == list_id) return entry[1];
                }
                const result = t.substUniverseListSlow(list_id);
                if (t.recent_count < t.recent_lists.len) {
                    t.recent_lists[t.recent_count] = .{ list_id, result };
                    t.recent_count += 1;
                }
                return result;
            }

            fn substUniverseListSlow(t: *@This(), list_id: u32) u32 {
                const m = t.m;
                // Expression keys carry a binder depth in their high word
                // (zero for pure universe substitution); no depth reaches
                // this reserved value, which namespaces universe-list keys.
                const key = (@as(u64, std.math.maxInt(u32)) << 32) | list_id;
                // Keep tiny substitutions allocation-free, just as for the
                // expression memo. Different constants can share this list.
                const memoize = t.visited > 16;
                if (memoize) if (t.cache.get(key)) |result| return result;
                var universes: c.SmallList(u32, 8) = .{};
                defer universes.deinit(m.allocator);
                m.listArray(list_id, &universes);
                var changed = false;
                for (universes.items) |*universe| {
                    const result = m.levels.subst(universe.*, t.names, t.levelValues());
                    changed = changed or result != universe.*;
                    universe.* = result;
                }
                const result = if (changed) m.list(universes.items) else list_id;
                if (memoize) t.cache.put(m.allocator, key, result);
                return result;
            }
        };
    }
    fn transform(m: *Pool, comptime mode: Mode, comptime reverse: bool, e: Expr, values: []const u32, names: []const u32) Expr {
        return m.transformWith(mode, reverse, e, values, names, &.{});
    }
    fn transformWith(m: *Pool, comptime mode: Mode, comptime reverse: bool, e: Expr, values: []const u32, names: []const u32, universes: []const u32) Expr {
        var timer = if (m.profile) std.time.Timer.start() catch unreachable else undefined;
        defer if (m.profile) {
            m.transform_ns[@intFromEnum(mode)] += timer.read();
            m.transform_calls[@intFromEnum(mode)] += 1;
        };
        var t: Transform(mode, reverse) = .{ .cache = &m.transform_caches[@intFromEnum(mode)], .m = m, .values = values, .names = names, .universes = universes };
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
    /// Instantiate loose bound variables and universe parameters in a single
    /// traversal. `values` are in application order (outermost binder first),
    /// exactly as for `instantiateReverse`, and are inserted unchanged: the
    /// universe substitution `names := us` applies to `e` only. The result is
    /// `instantiateReverse(substLevels(e, names, us), values)` without the
    /// intermediate term, so the binder domains of a consumed telescope and
    /// the unused parts of a body are never copied.
    pub fn instantiateLevels(m: *Pool, e: Expr, values: []const Expr, names: []const u32, us: []const u32) Expr {
        if (names.len == 0 or m.scalar(e, "flags") & param_flag == 0) return m.instantiateReverse(e, values);
        if (values.len == 0 or m.scalar(e, "range") == 0) return m.substLevels(e, names, us);
        var identity = true;
        for (names, us) |name, universe| {
            const node = m.levels.get(universe);
            if (node.kind != .param or node.a != name) {
                identity = false;
                break;
            }
        }
        if (identity) return m.instantiateReverse(e, values);
        return m.transformWith(.inst_levels, true, e, values, names, us);
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

test "fused instantiation equals universe substitution followed by instantiation" {
    const allocator = std.testing.allocator;
    var levels = LevelPool.init(allocator);
    defer levels.deinit();
    var m = Pool.init(allocator, &levels);
    defer m.deinit();
    m.temporary = true;
    const u = levels.param(7);
    const v = levels.param(9);
    const names = [_]u32{ 7, 9 };
    const replacements = [_]u32{ levels.succ(0), levels.param(11) };
    const head = m.cnst(3, m.list(&.{ u, levels.succ(v) }));
    // The inserted values mention the substituted parameter names. They must
    // survive unchanged: only the instantiated body's universes are replaced.
    const values = [_]Expr{ m.cnst(5, m.list(&.{u})), m.app(m.cnst(6, m.list(&.{v})), m.sort(u)) };
    // fun (y : head #0) => head #1 y (Sort (max u v)) #2, with two loose variables.
    var body = m.apps(head, &.{ m.bvar(1), m.bvar(0), m.sort(levels.max(u, v)), m.bvar(2) });
    // Cross the memoization threshold with shared constants and universe
    // lists at binder depths zero and one (their keys share one table).
    for (0..40) |index| body = m.app(m.app(head, body), if (index % 2 == 0) m.bvar(1) else m.sort(u));
    const open = m.binder(.lam, m.app(head, m.bvar(0)), body);
    const terms = [_]Expr{ open, m.app(open, m.app(head, m.bvar(1))), m.binder(.pi, open, m.app(open, m.bvar(0))), m.bvar(0), m.bvar(1), m.bvar(5), head, m.sort(v) };
    for (terms) |term| {
        const expected = m.instantiateReverse(m.substLevels(term, &names, &replacements), &values);
        try std.testing.expectEqual(expected, m.instantiateLevels(term, &values, &names, &replacements));
        // Degenerate requests reduce to the single transformations.
        try std.testing.expectEqual(m.substLevels(term, &names, &replacements), m.instantiateLevels(term, &.{}, &names, &replacements));
        try std.testing.expectEqual(m.instantiateReverse(term, &values), m.instantiateLevels(term, &values, &.{}, &.{}));
        try std.testing.expectEqual(m.instantiateReverse(term, &values), m.instantiateLevels(term, &values, &names, &.{ u, v }));
    }
    // A substituted variable under a binder is lifted, never universe-substituted.
    const lifted = m.instantiateLevels(m.binder(.lam, m.sort(u), m.app(m.bvar(1), m.bvar(0))), &.{m.app(m.bvar(0), m.sort(u))}, &names, &replacements);
    try std.testing.expectEqual(m.binder(.lam, m.sort(levels.succ(0)), m.app(m.app(m.bvar(1), m.sort(u)), m.bvar(0))), lifted);
}

test "packed global words round-trip every payload width and exact range" {
    const nodes = [_]Node{
        .{ .kind = .app, .a = payload_mask, .b = payload_mask, .range = 62, .flags = 1 },
        .{ .kind = .app, .a = payload_mask + 1, .b = 17, .range = 61 },
        .{ .kind = .pi, .a = 19, .b = payload_mask + 1, .range = 63, .flags = 1 },
        .{ .kind = .lam, .a = std.math.maxInt(u32), .b = std.math.maxInt(u32), .range = std.math.maxInt(u32), .flags = 1 },
        .{ .kind = .letE, .a = 23, .b = 29, .c = std.math.maxInt(u32), .range = 64 },
        .{ .kind = .proj, .a = std.math.maxInt(u32), .b = std.math.maxInt(u32), .c = std.math.maxInt(u32), .range = std.math.maxInt(u32) },
        .{ .kind = .nat, .a = std.math.maxInt(u32), .b = std.math.maxInt(u32) },
        .{ .kind = .str, .a = std.math.maxInt(u32) },
        .{ .kind = .app, .a = 31, .b = 37, .range = 63, .flags = 1 },
        .{ .kind = .app, .a = 41, .b = 43, .range = std.math.maxInt(u32), .flags = 1 },
        .{ .kind = .letE, .a = 47, .b = 53, .range = 62 },
    };
    inline for (.{ false, true }) |virtual| {
        var store: Store(false) = .{ .virtual = virtual };
        defer store.deinit(std.testing.allocator);
        var ids: [nodes.len]u32 = undefined;
        for (nodes, &ids) |node, *id| id.* = store.insert(std.testing.allocator, node);
        for (nodes, ids) |node, id| {
            try std.testing.expectEqualDeep(node, store.get(id));
            inline for (.{ "a", "b", "c", "kind", "range", "flags" }) |field| {
                try std.testing.expectEqual(@field(node, field), store.scalar(id, field));
            }
            try std.testing.expectEqual(id, store.insert(std.testing.allocator, node));
        }
        try std.testing.expectEqual(@as(usize, 0), store.wide_ranges.count());
        try std.testing.expectEqual(@as(usize, 9), store.extra_payloads.items.len);
    }
}
