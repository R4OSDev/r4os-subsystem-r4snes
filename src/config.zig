const builtin = @import("builtin");
const root = @import("root");

/// Tests/reference tools retain their observations. ReleaseFast products and
/// performance runs omit them; explicit diagnostic executables may opt in.
pub const diagnostics = if (@hasDecl(root, "r4snes_trace_enabled"))
    root.r4snes_trace_enabled
else
    builtin.is_test or builtin.mode != .ReleaseFast;
