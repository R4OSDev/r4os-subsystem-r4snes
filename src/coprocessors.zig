pub const Kind = enum {
    none,
    dsp1,
    dsp2,
    dsp3,
    dsp4,
    super_fx,
    sa1,
    sdd1,
    spc7110,
    cx4,
    obc1,
    st010,
    st011,
    st018,
    rtc,
    msu1,
};

pub const Registry = struct {
    selected: Kind = .none,

    /// Enhancement chips are explicit capability owners. The foundation
    /// supports none yet and therefore cannot silently substitute a base board.
    pub fn implemented(self: *const Registry) bool {
        return self.selected == .none;
    }
};
