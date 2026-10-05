//! Small OS shims so the core stays portable across macOS, Linux, and Windows.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

/// Write bytes to stdout, cross-platform.
pub fn stdoutWrite(bytes: []const u8) void {
    std.fs.File.stdout().writeAll(bytes) catch {};
}

/// Ignore SIGPIPE so a dropped IPC client cannot kill the daemon (POSIX only).
pub fn ignoreSigpipe() void {
    if (comptime is_windows) return;
    const posix = std.posix;
    const act = posix.Sigaction{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}
