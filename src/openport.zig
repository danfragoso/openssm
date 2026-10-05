//! Tactrix OpenPort 2.0 line-oriented AT command protocol.
//!
//! The vendor Windows stack (op20pt32.dll) talks to the device over a USB
//! CDC-ACM byte stream with ASCII commands and a mix of ASCII replies and
//! length-prefixed binary receive records. This module is a clean-room
//! implementation of the command grammar and reply parser, based on the
//! reverse-engineering notes in `roffe/libj2534_openport2` (Apache-2.0).
//!
//! Commands (every one except `ati` carries a sequence number 1..0xFFFF that
//! the device echoes back):
//!
//!   ati                       identify (reply: "ari main code version : X")
//!   ata <seq>                 close all channels
//!   atz <seq>                 reset
//!   ato<proto> <flags> <baud> <chan> <seq>   open (flags BEFORE baud!)
//!   atc<proto> <seq>          close channel
//!   att<proto> <len> <txflags> <timeout_us> <seq> + payload
//!   atf<proto> <type> <mask_len> <pattern_len> <seq> + mask + pattern
//!   atg<proto> <param> <seq>  get config
//!   ats<proto> <param> <value> <seq>
//!   atr <pin> <seq>           analog read (16 = VBATT) -> "arr <pin> <mV> <seq>"
//!   atp <pin> <mV> <seq>      programming voltage
//!
//! Binary receive record:
//!   'a' 'r' <proto-digit> <len> <RxStatus:1> <Timestamp:4 BE us> <CAN-ID:4 BE> <data...>
//!   where len = 9 + data.len.

const std = @import("std");

/// J2534 protocol identifiers, as encoded in `ato<proto>` / `ar<proto>`.
pub const Protocol = enum(u8) {
    j1850vpw = 1,
    j1850pwm = 2,
    iso9141 = 3,
    iso14230 = 4,
    can = 5,
    iso15765 = 6,
};

/// Monotonic 16-bit sequence generator; the device echoes it back.
pub const Seq = struct {
    n: u16 = 0,

    /// Returns the next sequence number, wrapping 0xFFFF -> 1 (never 0).
    pub fn next(self: *Seq) u16 {
        self.n +%= 1;
        if (self.n == 0) self.n = 1;
        return self.n;
    }
};

// ------------------------------------------------------------ command builders

pub fn identify(seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "ati {d}", .{seq});
}

pub fn closeAll(seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "ata {d}", .{seq});
}

pub fn reset(seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "atz {d}", .{seq});
}

pub fn open(proto: u8, flags: u32, baud: u32, chan: u8, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "ato{d} {d} {d} {d} {d}", .{ proto, flags, baud, chan, seq });
}

pub fn close(proto: u8, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "atc{d} {d}", .{ proto, seq });
}

/// Header for a transmit command. The payload is written immediately after it.
pub fn txHeader(proto: u8, len: u32, tx_flags: u32, timeout_us: u32, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "att{d} {d} {d} {d} {d}", .{ proto, len, tx_flags, timeout_us, seq });
}

/// Header for a filter command. Mask and pattern bytes follow it back to back.
pub fn filterHeader(proto: u8, ftype: u32, mask_len: u32, pattern_len: u32, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "atf{d} {d} {d} {d} {d}", .{ proto, ftype, mask_len, pattern_len, seq });
}

pub fn getConfig(proto: u8, param: u32, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "atg{d} {d} {d}", .{ proto, param, seq });
}

pub fn setConfig(proto: u8, param: u32, value: u32, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "ats{d} {d} {d} {d}", .{ proto, param, value, seq });
}

pub fn readAnalog(pin: u8, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "atr {d} {d}", .{ pin, seq });
}

pub fn progVoltage(pin: u8, millivolts: u32, seq: u16, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "atp {d} {d} {d}", .{ pin, millivolts, seq });
}

// ------------------------------------------------------------ reply parser

pub const Frame = struct {
    proto: u8,
    rx_status: u8,
    timestamp_us: u32,
    can_id: u32,
    data: []const u8,
};

pub const Reply = union(enum) {
    ok: u16,
    err: struct { code: u16, seq: u16 },
    identify: []const u8,
    analog: struct { pin: u8, millivolts: u32, seq: u16 },
    config: struct { proto: u8, param: u32, value: u32, seq: u16 },
    filter: struct { proto: u8, filter_id: u32, seq: u16 },
    frame: Frame,
    unknown_line: []const u8,
};

pub const ParseError = error{ BufferFull, MalformedFrame };

/// Streaming parser. `feed` raw device bytes, then call `next` until it returns
/// null (meaning more bytes are required). Returned slices remain valid until
/// the following call to `next`.
pub const Parser = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    data_buf: [1024]u8 = undefined,
    text_buf: [256]u8 = undefined,

    pub fn feed(self: *Parser, bytes: []const u8) ParseError!void {
        if (self.len + bytes.len > self.buf.len) return error.BufferFull;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn next(self: *Parser) ParseError!?Reply {
        if (self.len < 2) return null;

        // Binary receive record: "ar" + digit.
        if (self.buf[0] == 'a' and self.buf[1] == 'r' and
            self.len >= 3 and self.buf[2] >= '1' and self.buf[2] <= '9')
        {
            if (self.len < 4) return null;
            const flen: usize = self.buf[3];
            if (flen < 9) return error.MalformedFrame;
            const total = 4 + flen;
            if (self.len < total) return null;

            const proto = self.buf[2] - '0';
            const rx_status = self.buf[4];
            const ts = std.mem.readInt(u32, self.buf[5..9], .big);
            const can_id = std.mem.readInt(u32, self.buf[9..13], .big);
            const dlen = flen - 9;
            @memcpy(self.data_buf[0..dlen], self.buf[13 .. 13 + dlen]);
            const data = self.data_buf[0..dlen];
            self.shift(total);
            return Reply{ .frame = .{
                .proto = proto,
                .rx_status = rx_status,
                .timestamp_us = ts,
                .can_id = can_id,
                .data = data,
            } };
        }

        // ASCII reply terminated by CRLF.
        const idx = std.mem.indexOf(u8, self.buf[0..self.len], "\r\n") orelse return null;
        const reply = try self.parseLine(self.buf[0..idx]);
        self.shift(idx + 2);
        return reply;
    }

    fn shift(self: *Parser, n: usize) void {
        std.mem.copyForwards(u8, self.buf[0 .. self.len - n], self.buf[n..self.len]);
        self.len -= n;
    }

    fn copyText(self: *Parser, line: []const u8) []const u8 {
        const n = @min(line.len, self.text_buf.len);
        @memcpy(self.text_buf[0..n], line[0..n]);
        return self.text_buf[0..n];
    }

    fn parseLine(self: *Parser, line: []const u8) ParseError!Reply {
        if (std.mem.startsWith(u8, line, "aro")) {
            var i: usize = 3;
            const seq = parseTok(u16, line, &i) orelse return self.unknown(line);
            return .{ .ok = seq };
        }
        if (std.mem.startsWith(u8, line, "are")) {
            var i: usize = 3;
            const code = parseTok(u16, line, &i) orelse return self.unknown(line);
            const seq = parseTok(u16, line, &i) orelse return self.unknown(line);
            return .{ .err = .{ .code = code, .seq = seq } };
        }
        if (std.mem.startsWith(u8, line, "ari")) {
            const rest = std.mem.trimLeft(u8, line[3..], " ");
            return .{ .identify = self.copyText(rest) };
        }
        if (std.mem.startsWith(u8, line, "arr")) {
            var i: usize = 3;
            const pin = parseTok(u8, line, &i) orelse return self.unknown(line);
            const mv = parseTok(u32, line, &i) orelse return self.unknown(line);
            const seq = parseTok(u16, line, &i) orelse return self.unknown(line);
            return .{ .analog = .{ .pin = pin, .millivolts = mv, .seq = seq } };
        }
        if (std.mem.startsWith(u8, line, "arg") and line.len >= 4 and isDigit(line[3])) {
            const proto = line[3] - '0';
            var i: usize = 4;
            const param = parseTok(u32, line, &i) orelse return self.unknown(line);
            const value = parseTok(u32, line, &i) orelse return self.unknown(line);
            const seq = parseTok(u16, line, &i) orelse return self.unknown(line);
            return .{ .config = .{ .proto = proto, .param = param, .value = value, .seq = seq } };
        }
        if (std.mem.startsWith(u8, line, "arf") and line.len >= 4 and isDigit(line[3])) {
            const proto = line[3] - '0';
            var i: usize = 4;
            const fid = parseTok(u32, line, &i) orelse return self.unknown(line);
            const seq = parseTok(u16, line, &i) orelse return self.unknown(line);
            return .{ .filter = .{ .proto = proto, .filter_id = fid, .seq = seq } };
        }
        return self.unknown(line);
    }

    fn unknown(self: *Parser, line: []const u8) Reply {
        return .{ .unknown_line = self.copyText(line) };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn nextTok(s: []const u8, i: *usize) ?[]const u8 {
    while (i.* < s.len and s[i.*] == ' ') i.* += 1;
    if (i.* >= s.len) return null;
    const start = i.*;
    while (i.* < s.len and s[i.*] != ' ') i.* += 1;
    return s[start..i.*];
}

fn parseTok(comptime T: type, s: []const u8, i: *usize) ?T {
    const t = nextTok(s, i) orelse return null;
    return std.fmt.parseInt(T, t, 10) catch null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "sequence generator wraps 0xFFFF to 1" {
    var s = Seq{ .n = 0xFFFE };
    try testing.expectEqual(@as(u16, 0xFFFF), s.next());
    try testing.expectEqual(@as(u16, 1), s.next());
    try testing.expectEqual(@as(u16, 2), s.next());
}

test "open command puts flags before baud" {
    var buf: [64]u8 = undefined;
    const got = try open(@intFromEnum(Protocol.can), 0x1, 500000, 0, 42, &buf);
    try testing.expectEqualStrings("ato5 1 500000 0 42", got);
}

test "transmit header and analog read" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "att6 8 0 100000 7",
        try txHeader(@intFromEnum(Protocol.iso15765), 8, 0, 100000, 7, &buf),
    );
    try testing.expectEqualStrings("atr 16 9", try readAnalog(16, 9, &buf));
}

test "parse ok and error replies" {
    var p = Parser{};
    try p.feed("aro 12\r\nare 9 12\r\n");
    const a = (try p.next()).?;
    try testing.expectEqual(@as(u16, 12), a.ok);
    const b = (try p.next()).?;
    try testing.expectEqual(@as(u16, 9), b.err.code);
    try testing.expectEqual(@as(u16, 12), b.err.seq);
    try testing.expect((try p.next()) == null);
}

test "parse identify, analog, config and filter" {
    var p = Parser{};
    try p.feed("ari main code version : 1.17.4877\r\narr 16 12300 5\r\narg5 2 500000 6\r\narf6 3 7\r\n");
    const id = (try p.next()).?;
    try testing.expect(std.mem.endsWith(u8, id.identify, "1.17.4877"));
    const an = (try p.next()).?;
    try testing.expectEqual(@as(u32, 12300), an.analog.millivolts);
    const cfg = (try p.next()).?;
    try testing.expectEqual(@as(u8, 5), cfg.config.proto);
    try testing.expectEqual(@as(u32, 500000), cfg.config.value);
    const f = (try p.next()).?;
    try testing.expectEqual(@as(u32, 3), f.filter.filter_id);
}

test "parse binary receive frame" {
    var p = Parser{};
    const frame = [_]u8{
        'a', 'r', '5', 13, // proto 5 (CAN), len = 9 + 4 data bytes
        0x00, // rx status
        0x00, 0x00, 0x01, 0x00, // timestamp 0x100 us
        0x00, 0x00, 0x07, 0xE0, // CAN id 0x7E0
        0xDE, 0xAD, 0xBE, 0xEF, // payload
    };
    try p.feed(&frame);
    const r = (try p.next()).?;
    try testing.expectEqual(@as(u8, 5), r.frame.proto);
    try testing.expectEqual(@as(u32, 0x100), r.frame.timestamp_us);
    try testing.expectEqual(@as(u32, 0x7E0), r.frame.can_id);
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, r.frame.data);
}

test "partial frame waits for more bytes" {
    var p = Parser{};
    try p.feed("aro 3");
    try testing.expect((try p.next()) == null);
    try p.feed("\r\n");
    const r = (try p.next()).?;
    try testing.expectEqual(@as(u16, 3), r.ok);
}

test "binary frame split across feeds" {
    var p = Parser{};
    try p.feed("ar5\x0d\x00\x00");
    try testing.expect((try p.next()) == null);
    try p.feed("\x00\x01\x00\x00\x00\x07\xE0\x11\x22\x33\x44");
    const r = (try p.next()).?;
    try testing.expectEqual(@as(u32, 0x7E0), r.frame.can_id);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, r.frame.data);
}
