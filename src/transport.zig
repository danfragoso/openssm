//! Byte-stream transport abstraction shared by the real serial device and the
//! in-memory mock used for tests and client development.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A duplex byte stream. `read` returns 0 to mean "no data within the timeout".
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeAll: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn writeAll(self: Transport, bytes: []const u8) anyerror!void {
        return self.vtable.writeAll(self.ptr, bytes);
    }

    pub fn read(self: Transport, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

/// Scripted in-memory transport. `inject` supplies bytes the device would
/// send; `written` captures everything the host sent.
pub const Mock = struct {
    gpa: Allocator,
    in: std.ArrayList(u8) = .empty,
    in_pos: usize = 0,
    out: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Mock {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Mock) void {
        self.in.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    pub fn inject(self: *Mock, bytes: []const u8) !void {
        try self.in.appendSlice(self.gpa, bytes);
    }

    pub fn written(self: *const Mock) []const u8 {
        return self.out.items;
    }

    pub fn transport(self: *Mock) Transport {
        return .{ .ptr = self, .vtable = &.{
            .writeAll = writeAll,
            .read = read,
            .close = closeFn,
        } };
    }

    fn writeAll(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        try self.out.appendSlice(self.gpa, bytes);
    }

    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        const avail = self.in.items.len - self.in_pos;
        if (avail == 0) return 0;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.in.items[self.in_pos .. self.in_pos + n]);
        self.in_pos += n;
        if (self.in_pos == self.in.items.len) {
            self.in.clearRetainingCapacity();
            self.in_pos = 0;
        }
        return n;
    }

    fn closeFn(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// Like `Mock`, but synthesizes plausible OpenPort replies from the AT commands
/// it observes, so clients can be developed and tested with no hardware.
pub const AutoMock = struct {
    gpa: Allocator,
    in: std.ArrayList(u8) = .empty,
    in_pos: usize = 0,
    out: std.ArrayList(u8) = .empty,
    firmware: []const u8 = "main code version : 1.17.4877 (mock)",
    vbatt_mv: u32 = 12300,

    pub fn init(gpa: Allocator) AutoMock {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *AutoMock) void {
        self.in.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    pub fn transport(self: *AutoMock) Transport {
        return .{ .ptr = self, .vtable = &.{
            .writeAll = writeAll,
            .read = read,
            .close = closeFn,
        } };
    }

    fn writeAll(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *AutoMock = @ptrCast(@alignCast(ptr));
        try self.out.appendSlice(self.gpa, bytes);
        if (bytes.len >= 2 and bytes[0] == 'a' and bytes[1] == 't') {
            try self.respond(bytes);
        }
    }

    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *AutoMock = @ptrCast(@alignCast(ptr));
        const avail = self.in.items.len - self.in_pos;
        if (avail == 0) return 0;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.in.items[self.in_pos .. self.in_pos + n]);
        self.in_pos += n;
        if (self.in_pos == self.in.items.len) {
            self.in.clearRetainingCapacity();
            self.in_pos = 0;
        }
        return n;
    }

    fn closeFn(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn respond(self: *AutoMock, line: []const u8) !void {
        // last whitespace-delimited token is the sequence number
        const seq = lastToken(line) orelse return;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse return;

        if (std.mem.eql(u8, cmd, "ati")) {
            try self.replyFmt("ari {s}\r\n", .{self.firmware});
        } else if (std.mem.startsWith(u8, cmd, "ato") or
            std.mem.startsWith(u8, cmd, "atc") or
            std.mem.eql(u8, cmd, "ata") or
            std.mem.eql(u8, cmd, "atz") or
            std.mem.startsWith(u8, cmd, "att"))
        {
            try self.replyFmt("aro {s}\r\n", .{seq});
        } else if (std.mem.eql(u8, cmd, "atr")) {
            const pin = it.next() orelse return;
            if (std.mem.eql(u8, pin, "16")) {
                try self.replyFmt("arr 16 {d} {s}\r\n", .{ self.vbatt_mv, seq });
            } else {
                try self.replyFmt("arr {s} 500 {s}\r\n", .{ pin, seq });
            }
        }
    }

    fn replyFmt(self: *AutoMock, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, fmt, args);
        try self.in.appendSlice(self.gpa, s);
    }
};

fn lastToken(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \r\n\t");
    var last: ?[]const u8 = null;
    while (it.next()) |t| last = t;
    return last;
}

test "automock answers identify and vbatt" {
    var m = AutoMock.init(std.testing.allocator);
    defer m.deinit();
    const t = m.transport();
    try t.writeAll("ati 1\r\n");
    try t.writeAll("atr 16 2\r\n");
    var buf: [128]u8 = undefined;
    const n = try t.read(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "ari ") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "arr 16 12300 2") != null);
}

test "mock captures writes and replays injections" {
    var m = Mock.init(std.testing.allocator);
    defer m.deinit();
    try m.inject("ari hello\r\n");
    const t = m.transport();
    try t.writeAll("ati\r\n");
    var buf: [32]u8 = undefined;
    const n = try t.read(&buf);
    try std.testing.expectEqualStrings("ari hello\r\n", buf[0..n]);
    try std.testing.expectEqualStrings("ati\r\n", m.written());
    try std.testing.expectEqual(@as(usize, 0), try t.read(&buf));
}
