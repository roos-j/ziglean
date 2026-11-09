//! Bounded observations of constant-type substitutions, never checker results.
//! Repetition counts cover only keys retained by the capped diagnostic table.
const std = @import("std");

pub const Totals = struct {
    nonidentity_misses: u64 = 0,
    generated_nodes: u64 = 0,
    repeated_misses: u64 = 0,
    repeated_nodes: u64 = 0,
    tracked_keys: u64 = 0,
    untracked_misses: u64 = 0,
    identity_misses: u64 = 0,
    permanent_misses: u64 = 0,
    excluded_misses: u64 = 0,

    pub fn add(self: *Totals, other: Totals) void {
        inline for (std.meta.fields(Totals)) |field| @field(self, field.name) += @field(other, field.name);
    }

    pub fn print(self: Totals) void {
        std.debug.print("profile: constant-type substitution misses: nonidentity temporary={d}; generated nodes={d}; tracked cross-declaration repeats={d}; repeated generated nodes={d}\n", .{
            self.nonidentity_misses, self.generated_nodes, self.repeated_misses, self.repeated_nodes,
        });
        std.debug.print("profile: substitution tracking: keys={d} (4096 per worker/batch); untracked misses={d}; identity={d}; other permanent={d}; excluded signatures={d}\n", .{
            self.tracked_keys, self.untracked_misses, self.identity_misses, self.permanent_misses, self.excluded_misses,
        });
    }
};

pub const Outcome = enum { temporary, identity, permanent, excluded };

pub const Profile = struct {
    pub const key_limit = 4096;
    enabled: bool = false,
    declaration: u64 = 0,
    last_declaration: std.AutoHashMapUnmanaged(u64, u64) = .{},
    totals: Totals = .{},

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        self.last_declaration.deinit(allocator);
    }

    pub fn beginDeclaration(self: *Profile) void {
        if (self.enabled) self.declaration += 1;
    }

    pub fn record(self: *Profile, allocator: std.mem.Allocator, key: u64, nodes: usize, outcome: Outcome) void {
        if (!self.enabled) return;
        switch (outcome) {
            .identity => {
                self.totals.identity_misses += 1;
                return;
            },
            .permanent => {
                self.totals.permanent_misses += 1;
                return;
            },
            .excluded => {
                self.totals.excluded_misses += 1;
                return;
            },
            .temporary => {},
        }
        self.totals.nonidentity_misses += 1;
        self.totals.generated_nodes += nodes;
        if (self.last_declaration.getPtr(key)) |previous| {
            if (previous.* != self.declaration) {
                self.totals.repeated_misses += 1;
                self.totals.repeated_nodes += nodes;
                previous.* = self.declaration;
            }
            return;
        }
        if (self.last_declaration.count() == key_limit) {
            self.totals.untracked_misses += 1;
            return;
        }
        self.last_declaration.put(allocator, key, self.declaration) catch {
            // Diagnostics must not change whether checking can proceed.
            self.totals.untracked_misses += 1;
            return;
        };
        self.totals.tracked_keys += 1;
    }
};

test "substitution profiling distinguishes declaration reuse and non-temporary results" {
    var profile: Profile = .{};
    defer profile.deinit(std.testing.allocator);
    profile.record(std.testing.allocator, 11, 9, .temporary);
    try std.testing.expectEqual(@as(u64, 0), profile.totals.nonidentity_misses);
    try std.testing.expectEqual(@as(u32, 0), profile.last_declaration.capacity());
    profile.enabled = true;
    profile.beginDeclaration();
    profile.record(std.testing.allocator, 11, 5, .temporary);
    profile.record(std.testing.allocator, 11, 2, .temporary);
    profile.record(std.testing.allocator, 13, 0, .identity);
    profile.record(std.testing.allocator, 17, 0, .permanent);
    profile.record(std.testing.allocator, 19, 100, .excluded);
    profile.beginDeclaration();
    profile.record(std.testing.allocator, 11, 7, .temporary);
    profile.record(std.testing.allocator, 23, 3, .temporary);
    try std.testing.expectEqual(@as(u64, 4), profile.totals.nonidentity_misses);
    try std.testing.expectEqual(@as(u64, 17), profile.totals.generated_nodes);
    try std.testing.expectEqual(@as(u64, 1), profile.totals.repeated_misses);
    try std.testing.expectEqual(@as(u64, 7), profile.totals.repeated_nodes);
    try std.testing.expectEqual(@as(u64, 2), profile.totals.tracked_keys);
    try std.testing.expectEqual(@as(u64, 1), profile.totals.identity_misses);
    try std.testing.expectEqual(@as(u64, 1), profile.totals.permanent_misses);
    try std.testing.expectEqual(@as(u64, 1), profile.totals.excluded_misses);
}

test "substitution profiling caps keys while continuing to count tracked repeats" {
    var profile: Profile = .{ .enabled = true };
    defer profile.deinit(std.testing.allocator);
    profile.beginDeclaration();
    for (0..Profile.key_limit) |key| profile.record(std.testing.allocator, key, 1, .temporary);
    profile.record(std.testing.allocator, std.math.maxInt(u64), 3, .temporary);
    profile.beginDeclaration();
    profile.record(std.testing.allocator, 0, 2, .temporary);
    try std.testing.expectEqual(@as(u32, Profile.key_limit), profile.last_declaration.count());
    try std.testing.expectEqual(@as(u64, Profile.key_limit), profile.totals.tracked_keys);
    try std.testing.expectEqual(@as(u64, 1), profile.totals.untracked_misses);
    try std.testing.expectEqual(@as(u64, 1), profile.totals.repeated_misses);
    try std.testing.expectEqual(@as(u64, 2), profile.totals.repeated_nodes);
    try std.testing.expectEqual(@as(u64, Profile.key_limit + 5), profile.totals.generated_nodes);
}
