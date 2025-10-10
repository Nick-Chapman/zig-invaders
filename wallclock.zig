const std = @import("std");
const billion = 1_000_000_000;

pub fn time() u64 { // do time computation in nano-seconds.
    const linux = std.os.linux;
    const clock_id = linux.clockid_t.MONOTONIC;
    const ts : linux.timespec = std.posix.clock_gettime(clock_id) catch unreachable;
    const n : i64 = ts.sec * billion + ts.nsec;
    return @intCast(n);
}
