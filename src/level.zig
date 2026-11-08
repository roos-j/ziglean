// microlean's indexed, hash-consed universe manager, extended with normalization
// and substitution. Offsets are compressed instead of allocating succ chains.
const std = @import("std");
const c = @import("common.zig");
pub const Level = c.Level;
pub const Kind = enum(u8) { zero, param, max, imax, offset };
pub const Node = extern struct { a: u32 = 0, b: u32 = 0, kind: Kind, has_param: u8 = 0, positive: u8 = 0, reserved: u8 = 0 };
pub const Pool = struct {
    allocator: std.mem.Allocator,
    nodes: c.List(Node) = .{},
    map: std.AutoHashMapUnmanaged(Node, Level) = .{},
    norms: std.AutoHashMapUnmanaged(Level, Level) = .{},
    parent: ?*const Pool = null,
    base_length: u32 = 0,
    pub fn init(a: std.mem.Allocator) Pool {
        var self: Pool = .{ .allocator = a };
        _ = self.intern(.{ .kind = .zero });
        return self;
    }
    pub fn deinit(self: *Pool) void {
        self.nodes.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.norms.deinit(self.allocator);
    }
    pub fn fork(self: *const Pool) Pool {
        std.debug.assert(self.parent == null);
        return .{
            .allocator = self.allocator,
            .nodes = .fromOwnedSlice(self.allocator.dupe(Node, self.nodes.items) catch c.oom()),
            .map = self.map.clone(self.allocator) catch c.oom(),
        };
    }
    /// Workers share the immutable imported prefix and intern only newly
    /// derived levels in their own overlay. The parent must outlive the view.
    pub fn view(self: *const Pool) Pool {
        std.debug.assert(self.parent == null);
        return .{ .allocator = self.allocator, .parent = self, .base_length = @intCast(self.nodes.items.len) };
    }
    fn intern(self: *Pool, node: Node) Level {
        var n = node;
        switch (n.kind) {
            .zero => {},
            .param => n.has_param = 1,
            .offset => {
                n.has_param = @intFromBool(self.hasParam(n.a));
                n.positive = @intFromBool(n.b != 0 or self.nonzero(n.a));
            },
            .max, .imax => {
                n.has_param = @intFromBool(self.hasParam(n.a) or self.hasParam(n.b));
                n.positive = @intFromBool(self.nonzero(n.b) or (n.kind == .max and self.nonzero(n.a)));
            },
        }
        if (self.parent) |base_| if (base_.map.get(n)) |id| return id;
        const r = self.map.getOrPut(self.allocator, n) catch c.oom();
        if (r.found_existing) return r.value_ptr.*;
        const id: u32 = std.math.add(u32, self.base_length, @intCast(self.nodes.items.len)) catch c.oom();
        r.value_ptr.* = id;
        c.append(Node, &self.nodes, self.allocator, n);
        return id;
    }
    pub fn get(self: *const Pool, l: Level) Node {
        if (l < self.base_length) return self.parent.?.nodes.items[l];
        return self.nodes.items[l - self.base_length];
    }
    pub fn param(self: *Pool, name: u32) Level {
        return self.intern(.{ .kind = .param, .a = name });
    }
    pub fn offset(self: *Pool, l: Level, k: u32) Level {
        if (k == 0) return l;
        const n = self.get(l);
        if (n.kind == .offset) return self.intern(.{ .kind = .offset, .a = n.a, .b = std.math.add(u32, n.b, k) catch c.oom() });
        return self.intern(.{ .kind = .offset, .a = l, .b = k });
    }
    pub fn succ(self: *Pool, l: Level) Level {
        return self.offset(l, 1);
    }
    pub fn nonzero(self: *const Pool, l: Level) bool {
        return self.get(l).positive != 0;
    }
    pub fn hasParam(self: *const Pool, l: Level) bool {
        return self.get(l).has_param != 0;
    }
    fn base(self: *const Pool, l: Level) Level {
        const n = self.get(l);
        return if (n.kind == .offset) n.a else l;
    }
    fn off(self: *const Pool, l: Level) u32 {
        const n = self.get(l);
        return if (n.kind == .offset) n.b else 0;
    }
    pub fn max(self: *Pool, a: Level, b: Level) Level {
        if (a == b or b == 0) return a;
        if (a == 0) return b;
        if (self.base(a) == self.base(b)) return if (self.off(a) >= self.off(b)) a else b;
        if (self.base(a) == 0 and self.off(a) <= self.off(b)) return b;
        if (self.base(b) == 0 and self.off(b) <= self.off(a)) return a;
        return self.intern(.{ .kind = .max, .a = a, .b = b });
    }
    pub fn imax(self: *Pool, a: Level, b: Level) Level {
        if (self.nonzero(b)) return self.max(a, b);
        if (b == 0) return 0;
        if (a == 0 or a == b or (self.base(a) == 0 and self.off(a) == 1)) return b;
        return self.intern(.{ .kind = .imax, .a = a, .b = b });
    }
    fn flatten(self: *Pool, l: Level, k: u32, out: *c.List(Level)) void {
        const n = self.get(l);
        if (n.kind == .max) {
            self.flatten(n.a, k, out);
            self.flatten(n.b, k, out);
        } else if (n.kind == .offset) self.flatten(n.a, k + n.b, out) else c.append(Level, out, self.allocator, self.offset(self.normalize(l), k));
    }
    fn less(self: *Pool, a: Level, b: Level) bool {
        const aa = self.base(a);
        const bb = self.base(b);
        return if (aa == bb) self.off(a) < self.off(b) else aa < bb;
    }
    pub fn normalize(self: *Pool, l: Level) Level {
        if (self.norms.get(l)) |v| return v;
        const n = self.get(l);
        const result: Level = switch (n.kind) {
            .zero, .param => l,
            .imax => self.imax(self.normalize(n.a), self.normalize(n.b)),
            .max, .offset => blk: {
                var args: c.List(Level) = .{};
                defer args.deinit(self.allocator);
                if (n.kind == .max) {
                    self.flatten(n.a, 0, &args);
                    self.flatten(n.b, 0, &args);
                } else {
                    const nn = self.normalize(n.a);
                    if (self.get(nn).kind != .max) break :blk self.offset(nn, n.b);
                    self.flatten(nn, n.b, &args);
                }
                std.mem.sort(Level, args.items, self, less);
                var used: usize = 0;
                for (args.items) |a| {
                    if (used > 0 and self.base(args.items[used - 1]) == self.base(a)) args.items[used - 1] = a else {
                        args.items[used] = a;
                        used += 1;
                    }
                }
                var start: usize = 0;
                if (used > 1 and self.base(args.items[0]) == 0) for (args.items[1..used]) |a| {
                    if (self.off(a) >= self.off(args.items[0])) {
                        start = 1;
                        break;
                    }
                };
                var r = args.items[used - 1];
                var i = used - 1;
                while (i > start) {
                    i -= 1;
                    r = self.max(args.items[i], r);
                }
                break :blk r;
            },
        };
        self.norms.put(self.allocator, l, result) catch c.oom();
        return result;
    }
    pub fn equal(self: *Pool, a: Level, b: Level) bool {
        return a == b or self.normalize(a) == self.normalize(b);
    }
    pub fn geq(self: *Pool, a0: Level, b0: Level) bool {
        const a = self.normalize(a0);
        const b = self.normalize(b0);
        if (a == b or b == 0) return true;
        const x = self.get(a);
        const y = self.get(b);
        if (y.kind == .max) return self.geq(a, y.a) and self.geq(a, y.b);
        if (x.kind == .max and (self.geq(x.a, b) or self.geq(x.b, b))) return true;
        if (y.kind == .imax) return self.geq(a, y.a) and self.geq(a, y.b);
        if (x.kind == .imax) return self.geq(x.b, b);
        if (self.base(a) == self.base(b) or self.base(b) == 0) return self.off(a) >= self.off(b);
        if (self.off(a) > 0 and self.off(a) == self.off(b)) return self.geq(self.base(a), self.base(b));
        return false;
    }
    pub fn subst(self: *Pool, l: Level, names: []const u32, values: []const Level) Level {
        const n = self.get(l);
        return switch (n.kind) {
            .zero => 0,
            .param => blk: {
                for (names, values) |name, v| {
                    if (name == n.a) break :blk v;
                }
                break :blk l;
            },
            .offset => self.offset(self.subst(n.a, names, values), n.b),
            .max => self.max(self.subst(n.a, names, values), self.subst(n.b, names, values)),
            .imax => self.imax(self.subst(n.a, names, values), self.subst(n.b, names, values)),
        };
    }
    pub fn valid(self: *const Pool, l: Level, names: []const u32) bool {
        const n = self.get(l);
        return switch (n.kind) {
            .zero => true,
            .param => std.mem.indexOfScalar(u32, names, n.a) != null,
            .offset => self.valid(n.a, names),
            .max, .imax => self.valid(n.a, names) and self.valid(n.b, names),
        };
    }
};
