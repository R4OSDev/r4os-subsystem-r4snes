const board = @import("board.zig");

pub const Registry = struct {
    selected: board.Enhancement = .none,

    pub fn implemented(self: *const Registry) bool {
        return board.capability(self.selected).disposition == .base_implemented;
    }
};
