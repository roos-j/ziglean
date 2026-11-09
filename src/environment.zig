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
    // Most declarations are regular definitions or theorems. Their hot fields
    // stay inline; immutable inductive metadata is shared by snapshots.
    details: *const Details = &.{},
};
pub const Details = struct {
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
const NameIndex = @import("name_index.zig").Index(NameNode, struct {
    pub fn hash(name_: NameNode) u32 {
        var value = @as(u64, name_.pre) *% 0x9e3779b185ebca87;
        value ^= @as(u64, name_.atom) *% 0xc2b2ae3d27d4eb4f;
        value ^= @as(u64, @intFromBool(name_.numeric)) *% 0x165667b19e3779f9;
        value = (value ^ (value >> 32)) *% 0x165667b19e3779f9;
        return @truncate(value ^ (value >> 32));
    }
    pub fn eql(left: NameNode, right: NameNode) bool {
        return left.pre == right.pre and left.atom == right.atom and left.numeric == right.numeric;
    }
});
const StringIndex = @import("name_index.zig").Index([]const u8, struct {
    pub fn hash(bytes: []const u8) u32 {
        return @truncate(std.hash.Wyhash.hash(0, bytes));
    }
    pub fn eql(left: []const u8, right: []const u8) bool {
        return std.mem.eql(u8, left, right);
    }
});
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
    string_map: StringIndex = .{},
    names: c.List(NameNode) = .{},
    name_map: NameIndex = .{},
    decls: c.List(Decl) = .{},
    // Asynchronous import only appends these vectors. Stable addresses let jobs
    // borrow their immutable prefixes. Declaration-index entries publish once.
    declaration_region: @import("reserved_buffer.zig").Buffer = .{ .granularity = 64 * 1024 },
    name_region: @import("reserved_buffer.zig").Buffer = .{ .granularity = 64 * 1024 },
    string_region: @import("reserved_buffer.zig").Buffer = .{ .granularity = 64 * 1024 },
    declaration_index_region: @import("reserved_buffer.zig").Buffer = .{ .granularity = 64 * 1024 },
    stable_storage: bool = false,
    owns_declarations: bool = true,
    owns_name_storage: bool = true,
    owns_string_storage: bool = true,
    owns_declaration_index: bool = true,
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
    // Cache the intersection of task visibility and the frozen declaration
    // prefix once per view, rather than testing both bounds on every lookup.
    lookup_limit: u32 = std.math.maxInt(u32),
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
            if (self.owns_string_storage) {
                if (self.stable_storage) self.string_region.deinit() else self.strings.deinit(self.allocator);
            }
            self.string_map.deinit(self.allocator);
        }
        if (self.owns_names) {
            if (self.owns_name_storage) {
                if (self.stable_storage) self.name_region.deinit() else self.names.deinit(self.allocator);
            }
            self.name_map.deinit(self.allocator);
        }
        if (!self.borrowed) {
            if (self.owns_declarations) {
                if (self.stable_storage) self.declaration_region.deinit() else self.decls.deinit(self.allocator);
            }
            if (self.owns_declaration_index) {
                if (self.stable_storage) self.declaration_index_region.deinit() else self.decl_map.deinit(self.allocator);
            }
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
            .visible = self.visible,
            .lookup_limit = @min(self.visible, @as(u32, @intCast(self.decls.items.len))),
        };
    }
    pub fn snapshot(self: *const Environment) Environment {
        var result = self.fork();
        result.borrowed = false;
        result.owns_names = true;
        result.owns_strings = true;
        result.name_map = if (self.stable_storage) self.name_map.share() else self.name_map.clone(self.allocator, self.names.items.len) catch c.oom();
        result.string_map = if (self.stable_storage) self.string_map.share() else self.string_map.clone(self.allocator, self.strings.items.len) catch c.oom();
        if (self.stable_storage) {
            result.owns_declarations = false;
            result.owns_name_storage = false;
            result.owns_string_storage = false;
            result.owns_declaration_index = false;
        } else {
            result.decls = .fromOwnedSlice(self.allocator.dupe(Decl, self.decls.items) catch c.oom());
            result.names = .fromOwnedSlice(self.allocator.dupe(NameNode, self.names.items) catch c.oom());
            result.strings = .fromOwnedSlice(self.allocator.dupe([]const u8, self.strings.items) catch c.oom());
            result.decl_map = self.copyDeclarationIndex();
            // An independent copy may append its own declarations. Its map
            // cannot acquire later entries from the original importing thread.
            result.lookup_limit = self.visible;
        }
        return result;
    }
    fn copyDeclarationIndex(self: *const Environment) c.List(u32) {
        const entries = self.allocator.alloc(u32, self.decl_map.items.len) catch c.oom();
        for (entries, 0..) |*entry, index| {
            const encoded = @atomicLoad(u32, &self.decl_map.items[index], .acquire);
            // A frozen view can share a slot that was subsequently published.
            // Its independent clone must retain the original absence instead.
            entry.* = if (encoded <= self.decls.items.len) encoded else 0;
        }
        return .fromOwnedSlice(entries);
    }
    /// Enable append-only table storage before launching asynchronous
    /// jobs. The importing environment must outlive every snapshot. Updating
    /// an existing declaration is then restricted to worker-private overlays.
    pub fn enableConcurrentSnapshots(self: *Environment) void {
        if (self.stable_storage) return;
        std.debug.assert(!self.borrowed and self.owns_declarations and self.owns_name_storage and self.owns_string_storage and self.owns_declaration_index);
        self.stable_storage = true;
        moveToStable(Decl, self.allocator, &self.declaration_region, &self.decls);
        moveToStable(NameNode, self.allocator, &self.name_region, &self.names);
        moveToStable([]const u8, self.allocator, &self.string_region, &self.strings);
        moveToStable(u32, self.allocator, &self.declaration_index_region, &self.decl_map);
    }
    fn ensureDeclarationCapacity(self: *Environment, length: usize) void {
        ensureStableCapacity(Decl, &self.declaration_region, &self.decls, length);
    }
    pub fn beginView(self: *Environment, visible: u32) void {
        self.visible = visible;
        self.lookup_limit = if (self.borrowed or !self.owns_declarations)
            @min(visible, @as(u32, @intCast(self.decls.items.len)))
        else
            visible;
        self.overlay.clearRetainingCapacity();
    }
    pub fn copy(self: *Environment, comptime T: type, values: []const T) []const T {
        return self.arena.allocator().dupe(T, values) catch c.oom();
    }
    /// A derived declaration must receive a fresh record before changing any
    /// metadata. The environment arena outlives its declaration overlays.
    pub fn copyDetails(self: *Environment, value: Details) *const Details {
        const result = self.arena.allocator().create(Details) catch c.oom();
        result.* = value;
        return result;
    }
    pub fn string(self: *Environment, s: []const u8) u32 {
        if (!self.owns_strings or !self.owns_string_storage) {
            if (self.string_map.get(s, self.strings.items)) |id| return id;
            if (self.extra_string_map.get(s)) |id| return id;
            const owned = self.copy(u8, s);
            const id = @as(u32, @intCast(self.extra_strings.items.len)) | 0x80000000;
            c.append([]const u8, &self.extra_strings, self.allocator, owned);
            self.extra_string_map.put(self.allocator, owned, id) catch c.oom();
            return id;
        }
        const entry = self.string_map.getOrPut(self.allocator, s, self.strings.items) catch c.oom();
        if (entry.found_existing) return entry.id;
        const copy_ = self.copy(u8, s);
        const id: u32 = @intCast(self.strings.items.len);
        if (id & 0x80000000 != 0) c.oom();
        if (self.stable_storage) {
            ensureStableCapacity([]const u8, &self.string_region, &self.strings, self.strings.items.len + 1);
            self.strings.appendAssumeCapacity(copy_);
        } else c.append([]const u8, &self.strings, self.allocator, copy_);
        entry.publish(id);
        return id;
    }
    pub fn name(self: *Environment, pre: u32, atom: u32, numeric: bool) u32 {
        const n = NameNode{ .pre = pre, .atom = atom, .numeric = numeric };
        if (!self.owns_names or !self.owns_name_storage) {
            if (self.name_map.get(n, self.names.items)) |id| return id;
            const result = self.extra_name_map.getOrPut(self.allocator, n) catch c.oom();
            if (result.found_existing) return result.value_ptr.*;
            const id = @as(u32, @intCast(self.extra_names.items.len)) | 0x80000000;
            result.value_ptr.* = id;
            c.append(NameNode, &self.extra_names, self.allocator, n);
            return id;
        }
        const entry = self.name_map.getOrPut(self.allocator, n, self.names.items) catch c.oom();
        if (entry.found_existing) return entry.id;
        const id: u32 = @intCast(self.names.items.len);
        if (id & 0x80000000 != 0) c.oom();
        if (self.stable_storage) {
            ensureStableCapacity(NameNode, &self.name_region, &self.names, self.names.items.len + 1);
            self.names.appendAssumeCapacity(n);
        } else c.append(NameNode, &self.names, self.allocator, n);
        entry.publish(id);
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
        if (n >= self.decl_map.items.len) return null;
        const encoded = @atomicLoad(u32, &self.decl_map.items[n], .acquire);
        if (encoded == 0) return null;
        const i = encoded - 1;
        // Slots inside a snapshot's map prefix can be filled by later import.
        // Its declaration prefix and each task's predecessor bound stay frozen.
        if (i >= self.lookup_limit) return null;
        return &self.decls.items[i];
    }
    pub fn add(self: *Environment, d: Decl) c.Error!void {
        if (d.name == 0) return error.InvalidInput;
        if (self.borrowed) {
            if (self.find(d.name) != null) return error.DuplicateDeclaration;
            self.overlay.put(self.allocator, d.name, d) catch c.oom();
            return;
        }
        std.debug.assert(self.owns_declarations and self.owns_declaration_index);
        if (d.name >= self.decl_map.items.len) {
            const old_length = self.decl_map.items.len;
            const length = @as(usize, d.name) + 1;
            if (self.stable_storage) {
                ensureStableCapacity(u32, &self.declaration_index_region, &self.decl_map, length);
                self.decl_map.items.len = length;
            } else self.decl_map.resize(self.allocator, length) catch c.oom();
            // No existing snapshot can address this newly exposed tail.
            @memset(self.decl_map.items[old_length..], 0);
        } else if (@atomicLoad(u32, &self.decl_map.items[d.name], .acquire) != 0) return error.DuplicateDeclaration;
        const id: u32 = @intCast(self.decls.items.len);
        if (self.stable_storage) {
            self.ensureDeclarationCapacity(self.decls.items.len + 1);
            self.decls.appendAssumeCapacity(d);
        } else c.append(Decl, &self.decls, self.allocator, d);
        // The complete immutable declaration precedes its published index.
        @atomicStore(u32, &self.decl_map.items[d.name], id + 1, .release);
    }
    pub fn update(self: *Environment, d: Decl) void {
        if (self.borrowed) {
            std.debug.assert(self.overlay.contains(d.name));
            self.overlay.put(self.allocator, d.name, d) catch c.oom();
            return;
        }
        std.debug.assert(!self.stable_storage and self.owns_declarations);
        self.decls.items[@atomicLoad(u32, &self.decl_map.items[d.name], .acquire) - 1] = d;
    }
};

fn moveToStable(comptime T: type, allocator: std.mem.Allocator, region: *@import("reserved_buffer.zig").Buffer, list: *c.List(T)) void {
    const old = list.*;
    list.* = .{};
    ensureStableCapacity(T, region, list, old.items.len);
    list.appendSliceAssumeCapacity(old.items);
    allocator.free(old.allocatedSlice());
}

fn ensureStableCapacity(comptime T: type, region: *@import("reserved_buffer.zig").Buffer, list: *c.List(T), length: usize) void {
    if (length <= list.capacity) return;
    region.ensure(length * @sizeOf(T)) catch c.oom();
    const memory: [*]T = @ptrCast(@alignCast(region.pointer.?));
    list.items = memory[0..list.items.len];
    list.capacity = region.committed / @sizeOf(T);
}
