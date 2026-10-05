//! macOS/Linux serial transport to the OpenPort 2.0's USB CDC-ACM interface.
//!
//! The OpenPort presents interface 0/1 as CDC-ACM, so on macOS it appears as
//! `/dev/cu.usbmodem*` (FTDI-based clones as `/dev/cu.usbserial*`). No libusb
//! and no kext are required on that path.

const std = @import("std");
const posix = std.posix;
const Transport = @import("transport.zig").Transport;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
});

pub const Serial = struct {
    fd: posix.fd_t = -1,

    pub fn open(path: []const u8) !Serial {
        var pz: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= pz.len) return error.PathTooLong;
        @memcpy(pz[0..path.len], path);
        pz[path.len] = 0;

        const fd = c.open(&pz, c.O_RDWR | c.O_NOCTTY | c.O_NONBLOCK);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = c.close(fd);

        var tio: c.struct_termios = undefined;
        if (c.tcgetattr(fd, &tio) != 0) return error.TermiosFailed;
        c.cfmakeraw(&tio);
        _ = c.cfsetispeed(&tio, c.B115200); // CDC ignores line coding; keep it legal
        _ = c.cfsetospeed(&tio, c.B115200);
        tio.c_cflag |= c.CLOCAL | c.CREAD;
        tio.c_cflag &= ~@as(c_uint, c.CRTSCTS);
        tio.c_cc[c.VMIN] = 0;
        tio.c_cc[c.VTIME] = 0;
        if (c.tcsetattr(fd, c.TCSANOW, &tio) != 0) return error.TermiosFailed;

        // Assert DTR + RTS, as the vendor DLL does.
        var flags: c_int = c.TIOCM_DTR | c.TIOCM_RTS;
        _ = c.ioctl(fd, c.TIOCMBIS, &flags);

        _ = c.tcflush(fd, c.TCIOFLUSH);
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Serial) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn transport(self: *Serial) Transport {
        return .{ .ptr = self, .vtable = &.{
            .writeAll = writeAll,
            .read = read,
            .close = closeFn,
        } };
    }

    fn writeAll(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Serial = @ptrCast(@alignCast(ptr));
        var done: usize = 0;
        while (done < bytes.len) {
            const n = posix.write(self.fd, bytes[done..]) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return e,
            };
            done += n;
        }
    }

    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Serial = @ptrCast(@alignCast(ptr));
        var pfd = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = try posix.poll(&pfd, 2000);
        if (ready == 0) return 0; // timeout, no data
        if (pfd[0].revents & posix.POLL.IN == 0) return 0;
        return try posix.read(self.fd, buf);
    }

    fn closeFn(ptr: *anyopaque) void {
        const self: *Serial = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Does `name` look like an OpenPort serial node?
pub fn isCandidateName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "cu.usbmodem") or
        std.mem.startsWith(u8, name, "cu.usbserial") or
        std.mem.startsWith(u8, name, "ttyACM") or
        std.mem.startsWith(u8, name, "ttyUSB") or
        std.mem.indexOf(u8, name, "OpenPort") != null;
}

/// Return the first plausible OpenPort serial node, copied into `buf`.
/// Prefers `usbmodem` (CDC-ACM) over `usbserial` (FTDI VCP).
pub fn firstCandidate(buf: []u8) !?[]const u8 {
    var dir = try std.fs.openDirAbsolute("/dev", .{ .iterate = true });
    defer dir.close();

    var fallback: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .character_device and entry.kind != .sym_link) continue;
        if (!isCandidateName(entry.name)) continue;
        const full = try std.fmt.bufPrint(buf, "/dev/{s}", .{entry.name});
        if (std.mem.indexOf(u8, entry.name, "usbmodem") != null or
            std.mem.startsWith(u8, entry.name, "ttyACM"))
        {
            return full;
        }
        if (fallback == null) fallback = full;
    }
    return fallback;
}

test "candidate name predicate" {
    try std.testing.expect(isCandidateName("cu.usbmodem14201"));
    try std.testing.expect(isCandidateName("ttyACM0"));
    try std.testing.expect(isCandidateName("cu.usbserial-ABC"));
    try std.testing.expect(!isCandidateName("cu.Bluetooth-Incoming-Port"));
    try std.testing.expect(!isCandidateName("tty.debug-console"));
}
