//! OpenPort device state machine: sequence-numbered command/response over a
//! Transport, with the verified `\r\n`-then-payload framing.

const std = @import("std");
const openport = @import("openport.zig");
const Transport = @import("transport.zig").Transport;

pub const Protocol = openport.Protocol;

pub const Error = error{
    Timeout,
    UnexpectedReply,
    CommandTooLong,
    SpinsExhausted,
};

/// A received bus frame with owned backing storage.
pub const StoredFrame = struct {
    proto: u8,
    rx_status: u8,
    timestamp_us: u32,
    can_id: u32,
    len: u8,
    buf: [256]u8 = undefined,

    pub fn data(self: *const StoredFrame) []const u8 {
        return self.buf[0..self.len];
    }
};

const FrameQueue = struct {
    items: [32]StoredFrame = undefined,
    head: usize = 0,
    tail: usize = 0,

    fn push(self: *FrameQueue, f: openport.Frame) void {
        if ((self.head + 1) % self.items.len == self.tail) {
            self.tail = (self.tail + 1) % self.items.len; // drop oldest
        }
        const s = &self.items[self.head];
        s.proto = f.proto;
        s.rx_status = f.rx_status;
        s.timestamp_us = f.timestamp_us;
        s.can_id = f.can_id;
        s.len = @intCast(@min(f.data.len, s.buf.len));
        @memcpy(s.buf[0..s.len], f.data[0..s.len]);
        self.head = (self.head + 1) % self.items.len;
    }

    fn pop(self: *FrameQueue) ?StoredFrame {
        if (self.tail == self.head) return null;
        const s = self.items[self.tail];
        self.tail = (self.tail + 1) % self.items.len;
        return s;
    }

    fn isEmpty(self: *const FrameQueue) bool {
        return self.tail == self.head;
    }
};

pub const Device = struct {
    transport: Transport,
    seq: openport.Seq = .{},
    parser: openport.Parser = .{},
    read_buf: [1024]u8 = undefined,
    frames: FrameQueue = .{},

    pub fn init(transport: Transport) Device {
        return .{ .transport = transport };
    }

    pub fn deinit(self: *Device) void {
        self.transport.close();
    }

    /// Write an ASCII command line (framing CRLF appended here).
    fn sendLine(self: *Device, line: []const u8) !void {
        var buf: [320]u8 = undefined;
        if (line.len + 2 > buf.len) return error.CommandTooLong;
        @memcpy(buf[0..line.len], line);
        buf[line.len] = '\r';
        buf[line.len + 1] = '\n';
        try self.transport.writeAll(buf[0 .. line.len + 2]);
    }

    /// Write an ASCII command line followed immediately by a binary payload.
    fn sendLineWithBody(self: *Device, line: []const u8, body: []const u8) !void {
        try self.sendLine(line);
        if (body.len != 0) try self.transport.writeAll(body);
    }

    fn pump(self: *Device) !?openport.Reply {
        if (try self.parser.next()) |r| return r;
        const n = try self.transport.read(&self.read_buf);
        if (n == 0) return null; // timeout
        try self.parser.feed(self.read_buf[0..n]);
        return self.parser.next();
    }

    /// Wait for the reply matching `seq`. Bus frames and stale replies are
    /// skipped (frames are dropped until a logger sink is wired in).
    fn await(self: *Device, seq: u16) !openport.Reply {
        var spins: usize = 0;
        while (spins < 100_000) : (spins += 1) {
            const reply = (try self.pump()) orelse return error.Timeout;
            switch (reply) {
                .ok => |s| if (s == seq) return reply,
                .err => |e| if (e.seq == seq) return reply,
                .analog => |a| if (a.seq == seq) return reply,
                .config => |c| if (c.seq == seq) return reply,
                .filter => |f| if (f.seq == seq) return reply,
                .frame => |f| self.frames.push(f),
                .identify, .unknown_line => {},
            }
        }
        return error.SpinsExhausted;
    }

    /// Send `line` (with no framing) and await its sequence-matched reply.
    fn command(self: *Device, line: []const u8) !openport.Reply {
        const seq = self.seq.next();
        var buf: [320]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s} {d}", .{ line, seq }) catch return error.CommandTooLong;
        try self.sendLine(full);
        return self.await(seq);
    }

    /// `ati` identify. Returned slice aliases internal storage.
    pub fn identify(self: *Device) ![]const u8 {
        const seq = self.seq.next();
        var buf: [32]u8 = undefined;
        try self.sendLine(try openport.identify(seq, &buf));
        var spins: usize = 0;
        while (spins < 100_000) : (spins += 1) {
            const reply = (try self.pump()) orelse return error.Timeout;
            switch (reply) {
                .identify => |s| return s,
                else => {},
            }
        }
        return error.SpinsExhausted;
    }

    pub fn closeAll(self: *Device) !void {
        _ = try self.command("ata");
    }

    pub fn openChannel(self: *Device, proto: u8, flags: u32, baud: u32, chan: u8) !void {
        var line: [64]u8 = undefined;
        const seq = self.seq.next();
        const s = try openport.open(proto, flags, baud, chan, seq, &line);
        try self.sendLine(s);
        _ = try self.await(seq);
    }

    pub fn closeChannel(self: *Device, proto: u8) !void {
        var line: [32]u8 = undefined;
        const seq = self.seq.next();
        try self.sendLine(try openport.close(proto, seq, &line));
        _ = try self.await(seq);
    }

    /// Read an analog pin (16 = VBATT, 17 = programming voltage), in mV.
    pub fn readAnalog(self: *Device, pin: u8) !u32 {
        var line: [32]u8 = undefined;
        const seq = self.seq.next();
        try self.sendLine(try openport.readAnalog(pin, seq, &line));
        return switch (try self.await(seq)) {
            .analog => |a| a.millivolts,
            else => error.UnexpectedReply,
        };
    }

    /// Install a message filter (mandatory before the device forwards any RX).
    /// `mask` and `pattern` are protocol-specific selectors (4 bytes for CAN).
    pub fn installFilter(self: *Device, proto: u8, ftype: u32, mask: []const u8, pattern: []const u8) !void {
        var line: [64]u8 = undefined;
        var body: [32]u8 = undefined;
        if (mask.len + pattern.len > body.len) return error.CommandTooLong;
        const seq = self.seq.next();
        const h = try openport.filterHeader(proto, ftype, @intCast(mask.len), @intCast(pattern.len), seq, &line);
        @memcpy(body[0..mask.len], mask);
        @memcpy(body[mask.len .. mask.len + pattern.len], pattern);
        try self.sendLineWithBody(h, body[0 .. mask.len + pattern.len]);
        _ = try self.await(seq);
    }

    /// Return the next received frame, or null when the device goes quiet.
    pub fn waitFrame(self: *Device) !?StoredFrame {
        var spins: usize = 0;
        while (spins < 100_000) : (spins += 1) {
            if (self.frames.pop()) |f| return f;
            const reply = (try self.pump()) orelse return null;
            switch (reply) {
                .frame => |f| {
                    self.frames.push(f);
                    return self.frames.pop();
                },
                else => {},
            }
        }
        return null;
    }

    pub fn hasFrame(self: *const Device) bool {
        return !self.frames.isEmpty();
    }

    /// Bring-up helper: write `line` + CRLF and collect bytes until the device
    /// goes quiet. Returns the number of bytes copied into `out`.
    pub fn rawExchange(self: *Device, line: []const u8, out: []u8) !usize {
        return self.rawExchangeBody(line, &.{}, out);
    }

    /// Like `rawExchange`, but appends a binary payload after the CRLF.
    pub fn rawExchangeBody(self: *Device, line: []const u8, body: []const u8, out: []u8) !usize {
        try self.sendLineWithBody(line, body);
        var total: usize = 0;
        while (total < out.len) {
            const n = try self.transport.read(out[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    /// Transmit a raw frame on an open channel and await the `aro` ack.
    pub fn sendFrame(self: *Device, proto: u8, payload: []const u8, tx_flags: u32, timeout_us: u32) !void {
        var line: [96]u8 = undefined;
        const seq = self.seq.next();
        const s = try openport.txHeader(proto, @intCast(payload.len), tx_flags, timeout_us, seq, &line);
        try self.sendLineWithBody(s, payload);
        _ = try self.await(seq);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Mock = @import("transport.zig").Mock;

fn testDevice(mock: *Mock) Device {
    return Device.init(mock.transport());
}

test "identify parses firmware string" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    try m.inject("ari main code version : 1.17.4877\r\n");
    var d = testDevice(&m);
    const fw = try d.identify();
    try testing.expect(std.mem.endsWith(u8, fw, "1.17.4877"));
    try testing.expectEqualStrings("ati 1\r\n", m.written());
}

test "open then analog read" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    try m.inject("aro 1\r\narr 16 12300 2\r\n");
    var d = testDevice(&m);
    try d.openChannel(@intFromEnum(Protocol.iso9141), 0x1, 4800, 0);
    const mv = try d.readAnalog(16);
    try testing.expectEqual(@as(u32, 12300), mv);
    try testing.expectEqualStrings("ato3 1 4800 0 1\r\natr 16 2\r\n", m.written());
}

test "error reply surfaces as err" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    try m.inject("are 9 1\r\n");
    var d = testDevice(&m);
    const r = try d.command("atz");
    try testing.expectEqual(@as(u16, 9), r.err.code);
}

test "waitFrame returns a stored receive frame" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    const payload = [_]u8{ 0x80, 0xF0, 0x10, 0x03, 0xE8, 0x7D, 0xB1, 0x99 };
    const frame = [_]u8{ 'a', 'r', '3', 17, 0, 0, 0, 0, 1, 0, 0, 0, 0 } ++ payload;
    try m.inject(&frame);
    var d = testDevice(&m);
    const f = (try d.waitFrame()).?;
    try testing.expectEqual(@as(u8, 3), f.proto);
    try testing.expectEqualSlices(u8, &payload, f.data());
}

test "installFilter frames header then mask+pattern" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    try m.inject("aro 1\r\n");
    var d = testDevice(&m);
    try d.installFilter(3, 0, &.{ 0, 0, 0, 0 }, &.{ 0, 0, 0, 0 });
    try testing.expectEqualStrings(
        "atf3 0 4 4 1\r\n\x00\x00\x00\x00\x00\x00\x00\x00",
        m.written(),
    );
}

test "transmit writes payload right after CRLF" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    try m.inject("aro 1\r\n");
    var d = testDevice(&m);
    try d.sendFrame(@intFromEnum(Protocol.iso9141), &.{ 0x80, 0x10, 0xF0, 0x01, 0xBF, 0x40 }, 0, 100000);
    try testing.expectEqualStrings(
        "att3 6 0 100000 1\r\n\x80\x10\xF0\x01\xBF\x40",
        m.written(),
    );
}
