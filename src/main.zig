const std = @import("std");
const LevelPool = @import("level.zig").Pool;
const ExprPool = @import("expr.zig").Pool;
const Environment = @import("environment.zig").Environment;
const Importer = @import("import.zig").Importer;
const processor_profile = @import("processor_profile.zig");

const Options = struct {
    path: []const u8 = "-",
    max_steps: u64 = 100_000_000,
    max_temporary_nodes: u32 = 64_000_000,
    progress: bool = false,
    profile: bool = false,
    sync_import: bool = false,
    threads: u8 = 1,
    batch_size: u32 = 16384,
};

fn usage() void {
    std.debug.print(
        \\Usage: ziglean [-j N] [--batch-size N] [--max-steps N] [--max-temporary-nodes N] [--progress] [--profile] [--sync-import] [FILE|-]
        \\Checks a lean4export 3.x NDJSON stream.
        \\  --max-steps N  Checking budget per declaration (default: 100000000).
        \\  --max-temporary-nodes N  Scratch expression budget (default: 64000000).
        \\  --progress     Report progress every 10000 declarations.
        \\  --profile      Report phase and batch timings.
        \\  --sync-import  Parse input on the importing thread.
        \\  -j N           Check declarations with N workers (1..32, default: 1).
        \\  --batch-size N  Initial parallel batch size, growing adaptively (default: 16384).
        \\Exit 0 accepted, 1 rejected, 2 declined, 3 I/O or command-line error.
        \\
    , .{});
}

pub fn main() void {
    run() catch |err| {
        std.debug.print("ziglean: {s}\n", .{@errorName(err)});
        std.process.exit(3);
    };
}
fn run() !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var options: Options = .{};
    var have_path = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help")) {
            usage();
            return;
        } else if (std.mem.eql(u8, argument, "--progress")) {
            options.progress = true;
        } else if (std.mem.eql(u8, argument, "--profile")) {
            options.profile = true;
        } else if (std.mem.eql(u8, argument, "--sync-import")) {
            options.sync_import = true;
        } else if (std.mem.eql(u8, argument, "-j")) {
            index += 1;
            if (index == args.len) return error.MissingThreadCount;
            options.threads = try std.fmt.parseInt(u8, args[index], 10);
            if (options.threads == 0 or options.threads > 32) return error.InvalidThreadCount;
        } else if (std.mem.eql(u8, argument, "--batch-size")) {
            index += 1;
            if (index == args.len) return error.MissingBatchSize;
            options.batch_size = try std.fmt.parseInt(u32, args[index], 10);
            if (options.batch_size == 0) return error.InvalidBatchSize;
        } else if (std.mem.eql(u8, argument, "--max-steps")) {
            index += 1;
            if (index == args.len) return error.MissingStepBudget;
            options.max_steps = try std.fmt.parseInt(u64, args[index], 10);
            if (options.max_steps == 0) return error.InvalidStepBudget;
        } else if (std.mem.eql(u8, argument, "--max-temporary-nodes")) {
            index += 1;
            if (index == args.len) return error.MissingTemporaryNodeBudget;
            options.max_temporary_nodes = try std.fmt.parseInt(u32, args[index], 10);
            if (options.max_temporary_nodes == 0) return error.InvalidTemporaryNodeBudget;
        } else {
            if (have_path or (std.mem.startsWith(u8, argument, "-") and !std.mem.eql(u8, argument, "-"))) return error.InvalidArgument;
            options.path = argument;
            have_path = true;
        }
    }
    const file = if (std.mem.eql(u8, options.path, "-")) std.io.getStdIn() else try std.fs.cwd().openFile(options.path, .{});
    defer file.close();
    var levels = LevelPool.init(allocator);
    defer levels.deinit();
    var expressions = ExprPool.init(allocator, &levels);
    expressions.global.virtual = true;
    expressions.profile = options.profile;
    defer expressions.deinit();
    var environment = Environment.init(allocator);
    defer environment.deinit();
    var importer = Importer.init(&expressions, &environment);
    importer.max_ticks = options.max_steps;
    importer.max_temporary_nodes = options.max_temporary_nodes;
    importer.profile = options.profile;
    importer.threads = options.threads;
    importer.batch_size = options.batch_size;
    defer importer.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var timer = try std.time.Timer.start();
    var next_progress: u64 = 10000;
    var topology: processor_profile.Topology = if (options.profile) .init(allocator) else .{};
    defer if (options.profile) topology.deinit(allocator);
    var consumer_samples: processor_profile.Sampler = if (options.profile) .init(allocator, &topology) else .{};
    defer if (options.profile) consumer_samples.deinit(allocator);
    if (options.profile) consumer_samples.start();
    const concurrent_input = options.threads > 1 and !options.sync_import and !std.mem.eql(u8, options.path, "-") and (try file.stat()).kind == .file;
    if (concurrent_input) {
        var producer_samples: processor_profile.Sampler = if (options.profile) .init(allocator, &topology) else .{};
        defer if (options.profile) producer_samples.deinit(allocator);
        const stream = try @import("parsed_stream.zig").Stream(std.fs.File.Reader).create(allocator, file.reader(), .{
            .profile = options.profile,
            .processor_sampler = if (options.profile) &producer_samples else null,
        });
        defer stream.deinit();
        while (true) {
            const batch = stream.next();
            defer stream.release(batch);
            if (options.profile) consumer_samples.sample();
            var items = batch.iterator();
            while (items.next()) |item| {
                const result = switch (item) {
                    .scanned => |value| importer.scanned(value.record(), value.text()),
                    .json => |value| importer.line(value.*),
                    .raw => |value| importer.lineBytes(arena.allocator(), value),
                    .invalid => error.InvalidInput,
                };
                result catch |err| reject(&importer, &environment, err);
                if (arena.state.end_index != 0) _ = arena.reset(.retain_capacity);
                progress(&importer, options, &timer, &next_progress);
            }
            if (options.profile) consumer_samples.sample();
            if (batch.io_error) |err| return err;
            if (batch.finished) break;
        }
        if (options.profile) {
            consumer_samples.finish();
            const input_profile = stream.finish();
            std.debug.print("profile: input batches={d}; read/parse={d:.3}s; producer wait={d:.3}s; consumer wait={d:.3}s; oversized fallbacks={d}\n", .{
                input_profile.batches,
                @as(f64, @floatFromInt(input_profile.read_parse_ns)) / 1e9,
                @as(f64, @floatFromInt(input_profile.producer_wait_ns)) / 1e9,
                @as(f64, @floatFromInt(input_profile.consumer_wait_ns)) / 1e9,
                input_profile.oversized_fallbacks,
            });
            topology.print();
            consumer_samples.print("importer");
            producer_samples.print("producer");
        }
    } else {
        var reader = @import("line_reader.zig").LineReader(std.fs.File.Reader, 256 * 1024).init(file.reader(), allocator, 256 * 1024 * 1024);
        defer reader.deinit();
        if (options.profile) consumer_samples.sample();
        while (try reader.next()) |line| {
            if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
            importer.lineBytes(arena.allocator(), line) catch |err| reject(&importer, &environment, err);
            if (arena.state.end_index != 0) _ = arena.reset(.retain_capacity);
            progress(&importer, options, &timer, &next_progress);
        }
        if (options.profile) {
            consumer_samples.sample();
            consumer_samples.finish();
            topology.print();
            consumer_samples.print("synchronous importer");
        }
    }
    if (!importer.header) {
        std.debug.print("rejected: empty input\n", .{});
        std.process.exit(1);
    }
    importer.finish() catch |err| {
        std.debug.print("{s}: {s} at line {d}, declaration ", .{ if (err == error.ResourceLimit) "declined" else "rejected", @errorName(err), importer.lines });
        environment.printName(importer.last_name);
        std.debug.print("\n", .{});
        std.process.exit(if (err == error.ResourceLimit) 2 else 1);
    };
    std.debug.print("accepted {d} declarations; {d} expression nodes; {d:.3}s\n", .{ importer.declarations, expressions.global.nodes.items.len, @as(f64, @floatFromInt(timer.read())) / 1e9 });
    if (options.profile) {
        if (options.threads > 1) {
            std.debug.print("profile: checking batches {d:.3}s (overlapped with import)\n", .{@as(f64, @floatFromInt(importer.check_ns)) / 1e9});
        } else std.debug.print("profile: import {d:.3}s; kernel {d:.3}s\n", .{ @as(f64, @floatFromInt(timer.read() - importer.check_ns)) / 1e9, @as(f64, @floatFromInt(importer.check_ns)) / 1e9 });
    }
    if (options.profile and options.threads == 1) std.debug.print("transforms ns={any}; calls={any}\n", .{ expressions.transform_ns, expressions.transform_calls });
}

fn reject(importer: *const Importer, environment: *const Environment, err: @import("common.zig").Error) noreturn {
    const declined = err == error.Unsupported or err == error.ResourceLimit or err == error.UnsafeDeclaration;
    std.debug.print("{s}: {s} at line {d}, declaration ", .{ if (declined) "declined" else "rejected", @errorName(err), importer.lines });
    environment.printName(importer.last_name);
    std.debug.print("\n", .{});
    std.process.exit(if (declined) 2 else 1);
}

fn progress(importer: *const Importer, options: Options, timer: *std.time.Timer, next_progress: *u64) void {
    if (options.progress and importer.declarations >= next_progress.*) {
        std.debug.print("{s} {d} declarations; {d} nodes; {d:.1}s\n", .{ if (options.threads > 1) "imported" else "checked", importer.declarations, importer.expressions.global.nodes.items.len, @as(f64, @floatFromInt(timer.read())) / 1e9 });
        next_progress.* = importer.declarations + 10000;
    }
}
