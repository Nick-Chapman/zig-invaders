const std = @import("std");
const os = std.os;

pub const Mode = enum {
    test0,
    test1,
    test2,
    speed,
    graphics,
};

pub fn parse_mode() Mode {
    const n_args = os.argv.len - 1;
    if (n_args == 0) return .graphics;
    if (n_args > 1) @panic("need at most one arg");
    const arg1 = std.mem.span(os.argv[1]);
    return std.meta.stringToEnum(Mode, arg1) orelse @panic("mode");
}
