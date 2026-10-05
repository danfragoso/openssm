//! Platform selection for the serial transport.
//!
//! POSIX (macOS + Linux) and Windows share the same `Serial` surface:
//! `open`, `deinit`, `transport`, plus a `firstCandidate` autodetector.

const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("serial_windows.zig"),
    else => @import("serial_posix.zig"),
};

pub const Serial = impl.Serial;

/// Return the first plausible OpenPort serial device, copied into `buf`.
pub fn firstCandidate(buf: []u8) !?[]const u8 {
    return impl.firstCandidate(buf);
}

test {
    _ = impl;
}
