test {
    _ = @import("tests/kernel_tests.zig");
    _ = @import("tests/conversion_tests.zig");
    _ = @import("tests/pipeline_tests.zig");
    _ = @import("tests/storage_tests.zig");
    _ = @import("tests/name_snapshot_tests.zig");
    _ = @import("tests/parsed_stream_tests.zig");
    _ = @import("tests/universe_substitution_tests.zig");
    _ = @import("tests/leaf_lookup_tests.zig");
    _ = @import("tests/declaration_storage_tests.zig");
    _ = @import("tests/storage8_tests.zig");
    _ = @import("tests/cache_trim_tests.zig");
    _ = @import("tests/name_refs_tests.zig");
    _ = @import("tests/scratch_trim_tests.zig");
}
