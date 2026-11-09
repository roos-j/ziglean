test {
    _ = @import("tests/unit/nbe_tests.zig");
    _ = @import("tests/unit/kernel_tests.zig");
    _ = @import("tests/unit/conversion_tests.zig");
    _ = @import("tests/unit/pipeline_tests.zig");
    _ = @import("tests/unit/storage_tests.zig");
    _ = @import("tests/unit/name_snapshot_tests.zig");
    _ = @import("tests/unit/parsed_stream_tests.zig");
    _ = @import("tests/unit/universe_substitution_tests.zig");
    _ = @import("tests/unit/leaf_lookup_tests.zig");
    _ = @import("tests/unit/declaration_storage_tests.zig");
    _ = @import("tests/unit/storage8_tests.zig");
    _ = @import("tests/unit/cache_trim_tests.zig");
    _ = @import("tests/unit/name_refs_tests.zig");
    _ = @import("tests/unit/scratch_trim_tests.zig");
}
