//! Optional boundary samples, not estimates of processor residency. This module
//! queries topology and thread accounting without changing scheduling policy.
const std = @import("std");
const builtin = @import("builtin");

const Processor = struct {
    group: u16,
    number: u8,
    core: u8,
    efficiency_class: u8,
};
const Location = struct { group: u16, number: u8 };
const Backend = if (builtin.os.tag == .windows) Windows else Unsupported;

pub const Topology = struct {
    backend: Backend = .{},
    processors: []const Processor = &.{},

    pub fn init(allocator: std.mem.Allocator) Topology {
        const backend = Backend.load();
        return .{ .backend = backend, .processors = backend.query(allocator) };
    }

    pub fn deinit(self: *Topology, allocator: std.mem.Allocator) void {
        allocator.free(self.processors);
    }

    pub fn print(self: *const Topology) void {
        if (builtin.os.tag != .windows) return;
        if (self.processors.len == 0) {
            std.debug.print("profile: processor topology unavailable\n", .{});
            return;
        }
        std.debug.print("profile: processor topology (group:CPU/core/class)", .{});
        for (self.processors) |processor| std.debug.print(" {d}:{d}/{d}/{d}", .{ processor.group, processor.number, processor.core, processor.efficiency_class });
        std.debug.print("\n", .{});
    }
};

/// One thread writes each sampler. Its topology must outlive it; read and print
/// producer samples only after joining that thread.
pub const Sampler = struct {
    topology: ?*const Topology = null,
    counts: []u64 = &.{},
    samples: u64 = 0,
    unknown: u64 = 0,
    migrations: u64 = 0,
    last: ?Location = null,
    start_cpu_ns: ?u64 = null,
    cpu_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, topology: *const Topology) Sampler {
        const counts = allocator.alloc(u64, topology.processors.len) catch return .{ .topology = topology };
        @memset(counts, 0);
        return .{ .topology = topology, .counts = counts };
    }

    pub fn deinit(self: *Sampler, allocator: std.mem.Allocator) void {
        allocator.free(self.counts);
    }

    pub fn start(self: *Sampler) void {
        const topology = self.topology orelse return;
        self.start_cpu_ns = topology.backend.threadCpuNs();
    }

    pub fn finish(self: *Sampler) void {
        const topology = self.topology orelse return;
        const start_ns = self.start_cpu_ns orelse return;
        const end_ns = topology.backend.threadCpuNs() orelse return;
        if (end_ns >= start_ns) self.cpu_ns = end_ns - start_ns;
    }

    pub fn sample(self: *Sampler) void {
        const topology = self.topology orelse return;
        const location = topology.backend.current() orelse return;
        self.observe(location);
    }

    fn observe(self: *Sampler, location: Location) void {
        const topology = self.topology orelse return;
        self.samples += 1;
        if (self.last) |previous| {
            if (previous.group != location.group or previous.number != location.number) self.migrations += 1;
        }
        self.last = location;
        for (topology.processors, 0..) |processor, index| {
            if (processor.group == location.group and processor.number == location.number and index < self.counts.len) {
                self.counts[index] += 1;
                return;
            }
        }
        self.unknown += 1;
    }

    pub fn print(self: *const Sampler, role: []const u8) void {
        if (builtin.os.tag != .windows) return;
        const topology = self.topology orelse return;
        std.debug.print("profile: {s} thread CPU=", .{role});
        if (self.cpu_ns) |cpu_ns| std.debug.print("{d:.3}s", .{@as(f64, @floatFromInt(cpu_ns)) / 1e9}) else std.debug.print("unavailable", .{});
        std.debug.print("; boundary samples={d}; observed migrations={d}; unknown={d}\n", .{ self.samples, self.migrations, self.unknown });
        if (self.samples == 0) return;
        var classes = [_]u64{0} ** 256;
        std.debug.print("profile: {s} processor samples", .{role});
        for (self.counts, 0..) |count, index| {
            if (count == 0) continue;
            const processor = topology.processors[index];
            classes[processor.efficiency_class] += count;
            std.debug.print(" {d}:{d}={d}", .{ processor.group, processor.number, count });
        }
        std.debug.print("; class samples", .{});
        for (classes, 0..) |count, index| if (count != 0) {
            std.debug.print(" {d}={d}", .{ index, count });
        };
        std.debug.print("\n", .{});
    }
};

const Unsupported = struct {
    fn load() Unsupported {
        return .{};
    }
    fn query(_: Unsupported, _: std.mem.Allocator) []const Processor {
        return &.{};
    }
    fn current(_: Unsupported) ?Location {
        return null;
    }
    fn threadCpuNs(_: Unsupported) ?u64 {
        return null;
    }
};

const Windows = struct {
    const windows = std.os.windows;
    const Number = extern struct { group: u16, number: u8, reserved: u8 };
    const FileTime = extern struct { low: u32, high: u32 };
    const CurrentFn = *const fn (*Number) callconv(.winapi) void;
    const TimesFn = *const fn (windows.HANDLE, *FileTime, *FileTime, *FileTime, *FileTime) callconv(.winapi) windows.BOOL;
    const SetsFn = *const fn (?[*]u8, u32, *u32, ?windows.HANDLE, u32) callconv(.winapi) windows.BOOL;
    current_fn: ?CurrentFn = null,
    times_fn: ?TimesFn = null,
    sets_fn: ?SetsFn = null,

    fn load() Windows {
        const module = windows.kernel32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return .{};
        return .{
            .current_fn = @ptrCast(windows.kernel32.GetProcAddress(module, "GetCurrentProcessorNumberEx")),
            .times_fn = @ptrCast(windows.kernel32.GetProcAddress(module, "GetThreadTimes")),
            .sets_fn = @ptrCast(windows.kernel32.GetProcAddress(module, "GetSystemCpuSetInformation")),
        };
    }

    fn current(self: Windows) ?Location {
        const function = self.current_fn orelse return null;
        var number: Number = undefined;
        function(&number);
        return .{ .group = number.group, .number = number.number };
    }

    fn threadCpuNs(self: Windows) ?u64 {
        const function = self.times_fn orelse return null;
        var creation: FileTime = undefined;
        var exit_time: FileTime = undefined;
        var kernel: FileTime = undefined;
        var user: FileTime = undefined;
        if (function(windows.GetCurrentThread(), &creation, &exit_time, &kernel, &user) == 0) return null;
        const kernel_ticks = (@as(u64, kernel.high) << 32) | kernel.low;
        const user_ticks = (@as(u64, user.high) << 32) | user.low;
        const ticks = std.math.add(u64, kernel_ticks, user_ticks) catch return null;
        return std.math.mul(u64, ticks, 100) catch null;
    }

    fn query(self: Windows, allocator: std.mem.Allocator) []const Processor {
        const function = self.sets_fn orelse return &.{};
        var required: u32 = 0;
        _ = function(null, 0, &required, windows.GetCurrentProcess(), 0);
        // A bounded diagnostic buffer, independent of the accepted input size.
        // Retry a changing topology; failures leave profiling unavailable.
        for (0..3) |_| {
            if (required == 0 or required > 1024 * 1024) return &.{};
            const storage = allocator.alloc(u64, (@as(usize, required) + 7) / 8) catch return &.{};
            defer allocator.free(storage);
            const bytes = std.mem.sliceAsBytes(storage);
            const success = function(bytes.ptr, @intCast(bytes.len), &required, windows.GetCurrentProcess(), 0);
            if (success != 0) {
                if (required > bytes.len) return &.{};
                return parseTopology(allocator, bytes[0..required]) catch &.{};
            }
            if (required <= bytes.len) return &.{};
        }
        return &.{};
    }
};

/// SYSTEM_CPU_SET_INFORMATION is variable-sized. Its documented prefix is
/// decoded explicitly so unknown record types/extensions can be skipped safely.
/// https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-system_cpu_set_information
fn parseTopology(allocator: std.mem.Allocator, bytes: []const u8) ![]const Processor {
    var result = std.ArrayList(Processor).init(allocator);
    errdefer result.deinit();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes[offset..];
        if (remaining.len < 8) return error.InvalidTopology;
        const size = std.mem.readInt(u32, remaining[0..4], .little);
        if (size < 8 or size > remaining.len) return error.InvalidTopology;
        const kind = std.mem.readInt(u32, remaining[4..8], .little);
        if (kind == 0) {
            if (size < 32 or remaining[14] >= 64) return error.InvalidTopology;
            const processor: Processor = .{
                .group = std.mem.readInt(u16, remaining[12..14], .little),
                .number = remaining[14],
                .core = remaining[15],
                .efficiency_class = remaining[18],
            };
            for (result.items) |prior| {
                if (prior.group == processor.group and prior.number == processor.number) return error.InvalidTopology;
            }
            try result.append(processor);
        }
        offset += size;
    }
    return result.toOwnedSlice();
}

test "processor topology parser skips extensions and preserves group-relative classes" {
    var bytes = [_]u8{0} ** 80;
    std.mem.writeInt(u32, bytes[0..4], 40, .little);
    std.mem.writeInt(u16, bytes[12..14], 2, .little);
    bytes[14] = 3;
    bytes[15] = 1;
    bytes[18] = 9;
    std.mem.writeInt(u32, bytes[40..44], 8, .little);
    std.mem.writeInt(u32, bytes[44..48], 17, .little);
    std.mem.writeInt(u32, bytes[48..52], 32, .little);
    bytes[62] = 3;
    bytes[63] = 3;
    const processors = try parseTopology(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(processors);
    try std.testing.expectEqual(@as(usize, 2), processors.len);
    try std.testing.expectEqual(@as(u16, 2), processors[0].group);
    try std.testing.expectEqual(@as(u8, 9), processors[0].efficiency_class);
    try std.testing.expectEqual(@as(u16, 0), processors[1].group);
    try std.testing.expectEqual(@as(u8, 3), processors[1].number);
}

test "processor topology parser rejects truncated malformed and duplicate entries" {
    var bytes = [_]u8{0} ** 64;
    try std.testing.expectError(error.InvalidTopology, parseTopology(std.testing.allocator, bytes[0..7]));
    try std.testing.expectError(error.InvalidTopology, parseTopology(std.testing.allocator, &bytes));
    std.mem.writeInt(u32, bytes[0..4], 32, .little);
    try std.testing.expectError(error.InvalidTopology, parseTopology(std.testing.allocator, bytes[0..31]));
    std.mem.writeInt(u32, bytes[32..36], 32, .little);
    try std.testing.expectError(error.InvalidTopology, parseTopology(std.testing.allocator, &bytes));
}

test "processor samples distinguish groups and count only observed migrations" {
    const processors = [_]Processor{
        .{ .group = 2, .number = 3, .core = 1, .efficiency_class = 9 },
        .{ .group = 0, .number = 3, .core = 1, .efficiency_class = 0 },
    };
    const topology: Topology = .{ .processors = &processors };
    var sampler = Sampler.init(std.testing.allocator, &topology);
    defer sampler.deinit(std.testing.allocator);
    sampler.observe(.{ .group = 2, .number = 3 });
    sampler.observe(.{ .group = 2, .number = 3 });
    sampler.observe(.{ .group = 0, .number = 3 });
    sampler.observe(.{ .group = 4, .number = 0 });
    try std.testing.expectEqual(@as(u64, 4), sampler.samples);
    try std.testing.expectEqual(@as(u64, 2), sampler.migrations);
    try std.testing.expectEqual(@as(u64, 1), sampler.unknown);
    try std.testing.expectEqualSlices(u64, &.{ 2, 1 }, sampler.counts);
}
