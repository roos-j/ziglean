const std = @import("std");
const c = @import("common.zig");
pub const DeclKind = enum { axiom, definition, theorem, opaque_decl, inductive, ctor, recursor, quotient };
pub const Rule = struct { ctor: u32, fields: u32, rhs: u32 };
pub const Decl = struct {
    name: u32,
    kind: DeclKind,
    ty: u32,
    value: ?u32 = null,
    params: []const u32 = &.{},
    unsafe_: bool = false,
    // Derived from the body at import, never supplied by input metadata.
    projection_function: bool = false,
    nonproof_result: bool = false,
    height: u32 = 0,
    hint_kind: enum { regular, opaque_hint, abbrev } = .regular,
    num_params: u32 = 0,
    num_indices: u32 = 0,
    num_fields: u32 = 0,
    num_motives: u32 = 0,
    num_minors: u32 = 0,
    parent: u32 = 0,
    ctor_index: u32 = 0,
    ctors: []const u32 = &.{},
    all: []const u32 = &.{},
    rules: []const Rule = &.{},
    recursive: bool = false,
    reflexive: bool = false,
    k: bool = false,
    nested: u32 = 0,
    quot_kind: enum { type, mk, lift, ind } = .type,
};
/// Both textual and numeric components use interned strings. Numeric names
/// remain exact even when their natural-number component exceeds 64 bits.
pub const NameNode = struct { pre: u32, atom: u32, numeric: bool };
/// Canonical names used on reduction hot paths, interned once per environment.
const Builtins = struct {
    Nat: u32 = 0,
    @"Nat.zero": u32 = 0,
    @"Nat.succ": u32 = 0,
    @"Nat.add": u32 = 0,
    @"Nat.sub": u32 = 0,
    @"Nat.mul": u32 = 0,
    @"Nat.div": u32 = 0,
    @"Nat.mod": u32 = 0,
    @"Nat.pow": u32 = 0,
    @"Nat.gcd": u32 = 0,
    @"Nat.beq": u32 = 0,
    @"Nat.ble": u32 = 0,
    @"Nat.land": u32 = 0,
    @"Nat.lor": u32 = 0,
    @"Nat.xor": u32 = 0,
    @"Nat.shiftLeft": u32 = 0,
    @"Nat.shiftRight": u32 = 0,
    @"Bool.true": u32 = 0,
    @"Bool.false": u32 = 0,
    String: u32 = 0,
    @"String.mk": u32 = 0,
    @"String.ofList": u32 = 0,
    Char: u32 = 0,
    @"Char.ofNat": u32 = 0,
    @"List.nil": u32 = 0,
    @"List.cons": u32 = 0,
    Quot: u32 = 0,
    @"Quot.mk": u32 = 0,
    @"Quot.lift": u32 = 0,
    @"Quot.ind": u32 = 0,
    Eq: u32 = 0,
    eagerReduce: u32 = 0,
};
pub const Environment = struct {
    builtins: Builtins = .{},
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    strings: c.List([]const u8) = .{},
    string_map: std.StringHashMapUnmanaged(u32) = .{},
    names: c.List(NameNode) = .{},
    name_map: std.AutoHashMapUnmanaged(NameNode, u32) = .{},
    decls: c.List(Decl) = .{},
    // Names are internally assigned dense IDs. Zero denotes an absent
    // declaration; other entries encode its index plus one.
    decl_map: c.List(u32) = .{},
    borrowed: bool = false,
    owns_names: bool = true,
    owns_strings: bool = true,
    extra_names: c.List(NameNode) = .{},
    extra_name_map: std.AutoHashMapUnmanaged(NameNode, u32) = .{},
    extra_strings: c.List([]const u8) = .{},
    extra_string_map: std.StringHashMapUnmanaged(u32) = .{},
    visible: u32 = std.math.maxInt(u32),
    overlay: std.AutoHashMapUnmanaged(u32, Decl) = .{},
    pub fn init(a: std.mem.Allocator) Environment {
        var self: Environment = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a) };
        c.append(NameNode, &self.names, a, .{ .pre = 0, .atom = 0, .numeric = false });
        inline for (std.meta.fields(Builtins)) |field| @field(self.builtins, field.name) = self.named(field.name);
        return self;
    }
    pub fn builtin(self: *const Environment, comptime spelling: []const u8) u32 {
        return @field(self.builtins, spelling);
    }
    pub fn deinit(self: *Environment) void {
        self.extra_names.deinit(self.allocator);
        self.extra_name_map.deinit(self.allocator);
        self.extra_strings.deinit(self.allocator);
        self.extra_string_map.deinit(self.allocator);
        if (self.owns_strings) {
            self.strings.deinit(self.allocator);
            self.string_map.deinit(self.allocator);
        }
        if (self.owns_names) {
            self.names.deinit(self.allocator);
            self.name_map.deinit(self.allocator);
        }
        if (!self.borrowed) {
            self.decls.deinit(self.allocator);
            self.decl_map.deinit(self.allocator);
        }
        self.overlay.deinit(self.allocator);
        self.arena.deinit();
    }
    pub fn fork(self: *const Environment) Environment {
        return .{
            .allocator = self.allocator,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .builtins = self.builtins,
            .strings = self.strings,
            .string_map = self.string_map,
            .names = self.names,
            .name_map = self.name_map,
            .decls = self.decls,
            .decl_map = self.decl_map,
            .borrowed = true,
            .owns_names = false,
            .owns_strings = false,
        };
    }
    pub fn snapshot(self: *const Environment) Environment {
        var result = self.fork();
        result.borrowed = false;
        result.owns_names = true;
        result.owns_strings = true;
        result.names = .fromOwnedSlice(self.allocator.dupe(NameNode, self.names.items) catch c.oom());
        result.name_map = self.name_map.clone(self.allocator) catch c.oom();
        result.strings = .fromOwnedSlice(self.allocator.dupe([]const u8, self.strings.items) catch c.oom());
        result.string_map = self.string_map.clone(self.allocator) catch c.oom();
        result.decls = .fromOwnedSlice(self.allocator.dupe(Decl, self.decls.items) catch c.oom());
        result.decl_map = .fromOwnedSlice(self.allocator.dupe(u32, self.decl_map.items) catch c.oom());
        return result;
    }
    pub fn beginView(self: *Environment, visible: u32) void {
        self.visible = visible;
        self.overlay.clearRetainingCapacity();
    }
    pub fn copy(self: *Environment, comptime T: type, values: []const T) []const T {
        return self.arena.allocator().dupe(T, values) catch c.oom();
    }
    pub fn string(self: *Environment, s: []const u8) u32 {
        if (self.string_map.get(s)) |id| return id;
        if (!self.owns_strings) {
            if (self.extra_string_map.get(s)) |id| return id;
            const owned = self.copy(u8, s);
            const id = @as(u32, @intCast(self.extra_strings.items.len)) | 0x80000000;
            c.append([]const u8, &self.extra_strings, self.allocator, owned);
            self.extra_string_map.put(self.allocator, owned, id) catch c.oom();
            return id;
        }
        const copy_ = self.copy(u8, s);
        const id: u32 = @intCast(self.strings.items.len);
        c.append([]const u8, &self.strings, self.allocator, copy_);
        self.string_map.put(self.allocator, copy_, id) catch c.oom();
        return id;
    }
    pub fn name(self: *Environment, pre: u32, atom: u32, numeric: bool) u32 {
        const n = NameNode{ .pre = pre, .atom = atom, .numeric = numeric };
        if (self.name_map.get(n)) |id| return id;
        if (!self.owns_names) {
            const result = self.extra_name_map.getOrPut(self.allocator, n) catch c.oom();
            if (result.found_existing) return result.value_ptr.*;
            const id = @as(u32, @intCast(self.extra_names.items.len)) | 0x80000000;
            result.value_ptr.* = id;
            c.append(NameNode, &self.extra_names, self.allocator, n);
            return id;
        }
        const r = self.name_map.getOrPut(self.allocator, n) catch c.oom();
        if (r.found_existing) return r.value_ptr.*;
        const id: u32 = @intCast(self.names.items.len);
        r.value_ptr.* = id;
        c.append(NameNode, &self.names, self.allocator, n);
        return id;
    }
    pub fn child(self: *Environment, pre: u32, s: []const u8) u32 {
        return self.name(pre, self.string(s), false);
    }
    pub fn named(self: *Environment, s: []const u8) u32 {
        var it = std.mem.splitScalar(u8, s, '.');
        var r: u32 = 0;
        while (it.next()) |p| r = self.child(r, p);
        return r;
    }
    pub fn printName(self: *const Environment, n: u32) void {
        if (n == 0) return;
        const x = if (n & 0x80000000 == 0) self.names.items[n] else self.extra_names.items[n & 0x7fffffff];
        if (x.pre != 0) {
            self.printName(x.pre);
            std.debug.print(".", .{});
        }
        std.debug.print("{s}", .{self.getString(x.atom)});
    }
    pub fn getString(self: *const Environment, id: u32) []const u8 {
        return if (id & 0x80000000 == 0) self.strings.items[id] else self.extra_strings.items[id & 0x7fffffff];
    }
    /// Borrowed until the next declaration insertion or overlay update.
    pub fn find(self: *const Environment, n: u32) ?*const Decl {
        if (self.borrowed and self.overlay.count() != 0) {
            if (self.overlay.getPtr(n)) |decl| return decl;
        }
        if (n >= self.decl_map.items.len or self.decl_map.items[n] == 0) return null;
        const i = self.decl_map.items[n] - 1;
        if (i >= self.visible) return null;
        return &self.decls.items[i];
    }
    pub fn add(self: *Environment, d: Decl) c.Error!void {
        if (d.name == 0) return error.InvalidInput;
        if (self.borrowed) {
            if (self.find(d.name) != null) return error.DuplicateDeclaration;
            self.overlay.put(self.allocator, d.name, d) catch c.oom();
            return;
        }
        if (d.name >= self.decl_map.items.len) {
            const old_length = self.decl_map.items.len;
            self.decl_map.resize(self.allocator, @as(usize, d.name) + 1) catch c.oom();
            @memset(self.decl_map.items[old_length..], 0);
        } else if (self.decl_map.items[d.name] != 0) return error.DuplicateDeclaration;
        const id: u32 = @intCast(self.decls.items.len);
        c.append(Decl, &self.decls, self.allocator, d);
        self.decl_map.items[d.name] = id + 1;
    }
    pub fn update(self: *Environment, d: Decl) void {
        if (self.borrowed) {
            std.debug.assert(self.overlay.contains(d.name));
            self.overlay.put(self.allocator, d.name, d) catch c.oom();
            return;
        }
        self.decls.items[self.decl_map.items[d.name] - 1] = d;
    }
};
