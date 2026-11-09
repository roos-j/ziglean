//! Bounded single-producer parsing for seekable file input. The consumer alone
//! mutates the kernel; published batches own every string they reference.
const std = @import("std");
const scan = @import("scan.zig");

/// Only constants need universe storage; keeping their used IDs in the batch
/// arena avoids transferring a sixteen-element array for every ordinary node.
pub const Scanned = struct {
    // Names use UTF-8 bytes; constants use native u32 bytes. The existing kind
    // discriminates them, so another union tag would only enlarge the queue.
    payload: []const u8,
    id: u32,
    a: u32,
    b: u32,
    c: u32,
    d: u32,
    kind: scan.Kind,

    fn init(allocator: std.mem.Allocator, source: scan.Record, bytes: []const u8) !Scanned {
        var result: Scanned = .{
            .payload = &.{},
            .kind = source.kind,
            .id = source.id,
            .a = source.a,
            .b = source.b,
            .c = source.c,
            .d = source.d,
        };
        switch (source.kind) {
            .name_str => {
                const text_bytes = try allocator.dupe(u8, bytes[source.b..source.c]);
                result.payload = text_bytes;
                result.b = 0;
                result.c = @intCast(text_bytes.len);
            },
            .cnst => result.payload = try allocator.dupe(u8, std.mem.sliceAsBytes(source.universes[0..source.universe_count])),
            else => {},
        }
        return result;
    }

    pub inline fn record(self: Scanned) scan.Record {
        var result: scan.Record = .{ .kind = self.kind, .id = self.id, .a = self.a, .b = self.b, .c = self.c, .d = self.d };
        if (self.kind == .cnst) {
            std.debug.assert(self.payload.len % @sizeOf(u32) == 0);
            result.universe_count = @intCast(self.payload.len / @sizeOf(u32));
            @memcpy(std.mem.sliceAsBytes(result.universes[0..result.universe_count]), self.payload);
        }
        return result;
    }

    pub inline fn text(self: Scanned) []const u8 {
        return if (self.kind == .name_str) self.payload else &.{};
    }
};

pub const Item = union(enum) {
    scanned: Scanned,
    json: *const std.json.Value,
    raw: []const u8,
    invalid,
};

// The queue stores offsets rather than native pointers. Only name strings and
// constants need extra bytes; their otherwise unused b/c words hold offset/len.
// Item remains the decoded interface and is never allocated as a batch array.
const StoredItem = struct {
    id: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    kind: scan.Kind = .app,
    form: std.meta.Tag(Item),
};
comptime {
    std.debug.assert(@sizeOf(StoredItem) == 24);
}

pub const Options = struct {
    records_per_batch: usize = 8192,
    arena_bytes: usize = 4 * 1024 * 1024,
    line_limit: usize = 256 * 1024 * 1024,
    profile: bool = false,
    processor_sampler: ?*@import("processor_profile.zig").Sampler = null,
};

pub const Profile = struct {
    producer_wait_ns: u64 = 0,
    consumer_wait_ns: u64 = 0,
    read_parse_ns: u64 = 0,
    batches: u64 = 0,
    oversized_fallbacks: u64 = 0,
};

pub const Batch = struct {
    storage: []StoredItem,
    memory: []u8,
    length: usize = 0,
    io_error: ?anyerror = null,
    finished: bool = false,
    owned_raw: ?[]u8 = null,

    pub const Iterator = struct {
        batch: *const Batch,
        index: usize = 0,
        pub inline fn next(self: *Iterator) ?Item {
            if (self.index == self.batch.length) return null;
            const item = self.batch.get(self.index);
            self.index += 1;
            return item;
        }
    };

    pub fn iterator(self: *const Batch) Iterator {
        return .{ .batch = self };
    }

    pub inline fn get(self: *const Batch, index: usize) Item {
        std.debug.assert(index < self.length);
        const stored = self.storage[index];
        return switch (stored.form) {
            .scanned => blk: {
                var value: Scanned = .{
                    .payload = &.{},
                    .kind = stored.kind,
                    .id = stored.id,
                    .a = stored.a,
                    .b = stored.b,
                    .c = stored.c,
                    .d = stored.d,
                };
                if (stored.kind == .name_str or stored.kind == .cnst) {
                    value.payload = self.memory[stored.b..][0..stored.c];
                    value.b = 0;
                    if (stored.kind == .cnst) value.c = 0;
                }
                break :blk .{ .scanned = value };
            },
            .json => .{ .json = @ptrCast(@alignCast(self.memory[stored.a..][0..@sizeOf(std.json.Value)].ptr)) },
            .raw => .{ .raw = self.owned_raw.? },
            .invalid => .invalid,
        };
    }

    inline fn offset(self: *const Batch, pointer: [*]const u8) u32 {
        const address = @intFromPtr(pointer);
        const start = @intFromPtr(self.memory.ptr);
        std.debug.assert(address >= start and address - start <= self.memory.len);
        return @intCast(address - start);
    }

    inline fn write(self: *Batch, item: Item) void {
        self.storage[self.length] = switch (item) {
            .scanned => |value| blk: {
                var stored: StoredItem = .{
                    .form = .scanned,
                    .kind = value.kind,
                    .id = value.id,
                    .a = value.a,
                    .b = value.b,
                    .c = value.c,
                    .d = value.d,
                };
                if (value.kind == .name_str or value.kind == .cnst) {
                    std.debug.assert(value.b == 0);
                    std.debug.assert(value.c == if (value.kind == .name_str) value.payload.len else 0);
                    stored.b = if (value.payload.len == 0) 0 else self.offset(value.payload.ptr);
                    stored.c = @intCast(value.payload.len);
                }
                break :blk stored;
            },
            .json => |value| .{ .form = .json, .a = self.offset(@ptrCast(value)) },
            .raw => .{ .form = .raw },
            .invalid => .{ .form = .invalid },
        };
    }
};

/// Reader must finish a pending read without consumer assistance. In particular,
/// callers must keep stdin and pipes on the synchronous import path: cancellation
/// cannot interrupt an arbitrary blocking Reader.read call.
pub fn Stream(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const slot_count = 3;

        allocator: std.mem.Allocator,
        reader: Reader,
        options: Options,
        batches: [slot_count]Batch,
        thread: ?std.Thread = null,
        canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        free: std.Thread.Semaphore = .{ .permits = slot_count },
        ready: std.Thread.Semaphore = .{},
        oversized_done: std.Thread.Semaphore = .{},
        read_index: usize = 0,
        outstanding: ?*Batch = null,
        profile: Profile = .{},

        pub fn create(allocator: std.mem.Allocator, reader: Reader, options: Options) !*Self {
            std.debug.assert(options.records_per_batch != 0 and options.arena_bytes != 0);
            std.debug.assert(options.arena_bytes <= std.math.maxInt(u32));
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .reader = reader, .options = options, .batches = undefined };
            var initialized: usize = 0;
            errdefer for (self.batches[0..initialized]) |batch| {
                allocator.free(batch.storage);
                allocator.free(batch.memory);
            };
            for (&self.batches) |*batch| {
                const storage = try allocator.alloc(StoredItem, options.records_per_batch);
                errdefer allocator.free(storage);
                const memory = try allocator.alloc(u8, options.arena_bytes);
                batch.* = .{ .storage = storage, .memory = memory };
                initialized += 1;
            }
            self.thread = try std.Thread.spawn(.{}, produce, .{self});
            return self;
        }

        /// Exactly one batch may be held at a time. Its data stays valid until
        /// release, including when declaration checking continues asynchronously.
        /// A finished batch is terminal: release it, then deinit the stream.
        pub fn next(self: *Self) *const Batch {
            std.debug.assert(self.outstanding == null);
            var timer = if (self.options.profile) std.time.Timer.start() catch unreachable else undefined;
            self.ready.wait();
            if (self.options.profile) self.profile.consumer_wait_ns += timer.read();
            const batch = &self.batches[self.read_index];
            self.read_index = (self.read_index + 1) % slot_count;
            self.outstanding = batch;
            return batch;
        }

        pub fn release(self: *Self, batch: *const Batch) void {
            std.debug.assert(self.outstanding == batch);
            const oversized = batch.owned_raw != null;
            self.outstanding = null;
            // Capture metadata before publishing the slot as reusable.
            if (oversized) self.oversized_done.post();
            self.free.post();
        }

        /// Call after releasing the terminal batch. Joining publishes the final
        /// producer counters; reading them earlier would race the producer.
        pub fn finish(self: *Self) Profile {
            std.debug.assert(self.outstanding == null);
            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            }
            return self.profile;
        }

        pub fn deinit(self: *Self) void {
            self.canceled.store(true, .release);
            // Either wait can block a producer after its consumer rejects input.
            self.free.post();
            self.oversized_done.post();
            if (self.thread) |thread| thread.join();
            for (self.batches) |batch| {
                if (batch.owned_raw) |raw| self.allocator.free(raw);
                self.allocator.free(batch.storage);
                self.allocator.free(batch.memory);
            }
            const allocator = self.allocator;
            allocator.destroy(self);
        }

        fn rawFallback(self: *Self, batch: *Batch, line: []const u8) void {
            if (self.options.profile) self.profile.oversized_fallbacks += 1;
            const raw = self.allocator.dupe(u8, line) catch {
                batch.write(.invalid);
                batch.length += 1;
                batch.finished = true;
                return;
            };
            batch.owned_raw = raw;
            batch.write(.{ .raw = raw });
            batch.length += 1;
        }

        fn produce(self: *Self) void {
            if (self.options.profile) {
                if (self.options.processor_sampler) |sampler| sampler.start();
            }
            defer if (self.options.profile) {
                if (self.options.processor_sampler) |sampler| sampler.finish();
            };
            var reader = @import("line_reader.zig").LineReader(Reader, 256 * 1024).init(self.reader, self.allocator, self.options.line_limit);
            defer reader.deinit();
            var write_index: usize = 0;
            while (true) {
                var wait_timer = if (self.options.profile) std.time.Timer.start() catch unreachable else undefined;
                self.free.wait();
                if (self.options.profile) self.profile.producer_wait_ns += wait_timer.read();
                if (self.canceled.load(.acquire)) return;
                if (self.options.profile) {
                    if (self.options.processor_sampler) |sampler| sampler.sample();
                }
                var parse_timer = if (self.options.profile) std.time.Timer.start() catch unreachable else undefined;
                const batch = &self.batches[write_index];
                batch.length = 0;
                batch.io_error = null;
                batch.finished = false;
                std.debug.assert(batch.owned_raw == null);
                var arena = std.heap.FixedBufferAllocator.init(batch.memory);
                while (batch.length < batch.storage.len) {
                    if (self.canceled.load(.acquire)) return;
                    const line = reader.next() catch |err| {
                        batch.io_error = err;
                        batch.finished = true;
                        break;
                    } orelse {
                        batch.finished = true;
                        break;
                    };
                    if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
                    if (scan.scan(line)) |scanned| {
                        const compact = Scanned.init(arena.allocator(), scanned, line) catch {
                            self.rawFallback(batch, line);
                            break;
                        };
                        batch.write(.{ .scanned = compact });
                    } else {
                        const saved = arena.end_index;
                        const parsed = parseJson(arena.allocator(), line) catch |err| {
                            arena.end_index = saved;
                            if (err == error.OutOfMemory) {
                                self.rawFallback(batch, line);
                            } else {
                                batch.write(.invalid);
                                batch.length += 1;
                                batch.finished = true;
                            }
                            break;
                        };
                        batch.write(.{ .json = parsed });
                    }
                    batch.length += 1;
                }
                if (self.options.profile) {
                    self.profile.read_parse_ns += parse_timer.read();
                    self.profile.batches += 1;
                    if (self.options.processor_sampler) |sampler| sampler.sample();
                }
                self.ready.post();
                if (batch.owned_raw != null) {
                    // Never queue several exceptional large records. The
                    // consumer uses its ordinary parser for this one record.
                    if (self.options.profile) wait_timer.reset();
                    self.oversized_done.wait();
                    if (self.options.profile) self.profile.producer_wait_ns += wait_timer.read();
                    if (self.canceled.load(.acquire)) return;
                    self.allocator.free(batch.owned_raw.?);
                    batch.owned_raw = null;
                }
                if (batch.finished) return;
                write_index = (write_index + 1) % slot_count;
            }
        }
    };
}

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !*const std.json.Value {
    const result = try allocator.create(std.json.Value);
    result.* = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
        .max_value_len = 256 * 1024 * 1024,
    });
    return result;
}

test "queued offsets preserve end-of-arena text unaligned universes and JSON pointers" {
    var memory: [256]u8 align(@alignOf(std.json.Value)) = undefined;
    var storage: [6]StoredItem = undefined;
    var raw = [_]u8{ 'r', 'a', 'w' };
    var batch: Batch = .{ .storage = &storage, .memory = &memory, .owned_raw = &raw };
    @memcpy(memory[253..], "λx");
    const text: Scanned = .{ .kind = .name_str, .id = 0xffffffff, .a = 0xfffffffe, .b = 0, .c = 3, .d = 0, .payload = memory[253..] };
    batch.write(.{ .scanned = text });
    batch.length += 1;

    var universes: [16]u32 = undefined;
    for (&universes, 0..) |*value, index| value.* = std.math.maxInt(u32) - @as(u32, @intCast(index));
    @memcpy(memory[7..71], std.mem.sliceAsBytes(&universes));
    batch.write(.{ .scanned = .{ .kind = .cnst, .id = 0xffffffff, .a = 0xfffffffd, .b = 0, .c = 0, .d = 0, .payload = memory[7..71] } });
    batch.length += 1;

    const value: *std.json.Value = @ptrCast(@alignCast(memory[128..][0..@sizeOf(std.json.Value)].ptr));
    value.* = .{ .string = memory[253..] };
    batch.write(.{ .json = value });
    batch.length += 1;
    batch.write(.{ .scanned = .{ .kind = .name_str, .id = 17, .a = 0, .b = 0, .c = 0, .d = 0, .payload = &.{} } });
    batch.length += 1;
    batch.write(.{ .raw = &raw });
    batch.length += 1;
    batch.write(.invalid);
    batch.length += 1;

    const name = batch.get(0).scanned;
    try std.testing.expectEqual(text.id, name.id);
    try std.testing.expectEqual(text.a, name.a);
    try std.testing.expectEqual(@as(u32, 0), name.b);
    try std.testing.expectEqual(@as(u32, 3), name.c);
    try std.testing.expectEqualStrings("λx", name.text());
    const constant = batch.get(1).scanned.record();
    try std.testing.expectEqual(@as(u32, 0), constant.b);
    try std.testing.expectEqual(@as(u32, 0), constant.c);
    try std.testing.expectEqual(@as(u8, 16), constant.universe_count);
    try std.testing.expectEqualSlices(u32, &universes, &constant.universes);
    try std.testing.expect(batch.get(2).json == value);
    try std.testing.expectEqualStrings("λx", batch.get(2).json.string);
    try std.testing.expectEqual(@as(usize, 0), batch.get(3).scanned.text().len);
    try std.testing.expectEqualStrings("raw", batch.get(4).raw);
    try std.testing.expect(batch.get(5) == .invalid);
    var items = batch.iterator();
    for (0..batch.length) |_| try std.testing.expect(items.next() != null);
    try std.testing.expect(items.next() == null);
    try std.testing.expect(items.next() == null);
}
