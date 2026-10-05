//! Subaru Select Monitor (SSM/SSM2) K-line packet framing.
//!
//! Wire format, little-endian-neutral, ISO9141 @ 4800 8N1:
//!
//!   0x80  dst  src  len  cmd  data...  checksum
//!
//! `len` counts the command byte plus the data bytes (i.e. 1 + data.len).
//! `checksum` is the 8-bit LSB of the sum of every preceding byte, so a valid
//! frame sums to 0 across all bytes including the checksum.
//!
//! Source: RomRaider "SSM Protocol" reference (see docs in repo history).

const std = @import("std");

pub const HEADER: u8 = 0x80;

pub const ADDR_ECU: u8 = 0x10;
pub const ADDR_TCU: u8 = 0x18;
pub const ADDR_TOOL: u8 = 0xF0;

pub const CMD_INIT: u8 = 0xBF;
pub const CMD_BLOCK_READ: u8 = 0xA0;
pub const CMD_ADDR_READ: u8 = 0xA8;
pub const CMD_BLOCK_WRITE: u8 = 0xB0;
pub const CMD_ADDR_WRITE: u8 = 0xB8;

pub const RESP_INIT: u8 = 0xFF;
pub const RESP_BLOCK_READ: u8 = 0xE0;
pub const RESP_ADDR_READ: u8 = 0xE8;
pub const RESP_BLOCK_WRITE: u8 = 0xF0;
pub const RESP_ADDR_WRITE: u8 = 0xF8;

pub const Error = error{
    BadHeader,
    TooShort,
    BadChecksum,
    Truncated,
    PacketTooLong,
    NoSpaceLeft,
};

/// 8-bit LSB of the wrapping sum of `bytes`.
pub fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum;
}

pub const Packet = struct {
    dst: u8,
    src: u8,
    cmd: u8,
    data: []const u8,
};

/// Encode `pkt` into `buf`, returning the slice that was written.
pub fn encode(pkt: Packet, buf: []u8) Error![]u8 {
    if (pkt.data.len > 254) return error.PacketTooLong;
    const total = 5 + pkt.data.len + 1;
    if (buf.len < total) return error.NoSpaceLeft;

    buf[0] = HEADER;
    buf[1] = pkt.dst;
    buf[2] = pkt.src;
    buf[3] = @intCast(1 + pkt.data.len);
    buf[4] = pkt.cmd;
    @memcpy(buf[5 .. 5 + pkt.data.len], pkt.data);
    buf[total - 1] = checksum(buf[0 .. total - 1]);
    return buf[0..total];
}

pub const Decoded = struct {
    dst: u8,
    src: u8,
    cmd: u8,
    data: []const u8,
};

/// Decode and validate a single frame. `data` aliases `frame`.
pub fn decode(frame: []const u8) Error!Decoded {
    if (frame.len < 6) return error.TooShort;
    if (frame[0] != HEADER) return error.BadHeader;
    const total = 5 + @as(usize, frame[3]);
    if (frame.len < total) return error.Truncated;
    if (checksum(frame[0 .. total - 1]) != frame[total - 1]) return error.BadChecksum;
    return .{
        .dst = frame[1],
        .src = frame[2],
        .cmd = frame[4],
        .data = frame[5 .. 4 + @as(usize, frame[3])],
    };
}

/// `BF` ECU init request (sent to 0x10 from the tool).
pub fn init(buf: []u8) Error![]u8 {
    return encode(.{ .dst = ADDR_ECU, .src = ADDR_TOOL, .cmd = CMD_INIT, .data = &.{} }, buf);
}

pub fn addrBytes(addr: u24) [3]u8 {
    return .{
        @intCast((addr >> 16) & 0xFF),
        @intCast((addr >> 8) & 0xFF),
        @intCast(addr & 0xFF),
    };
}

/// `A8` address-read request for a single 24-bit address, single response.
pub fn addrRead(addr: u24, buf: []u8) Error![]u8 {
    const a = addrBytes(addr);
    const data = [_]u8{0x00} ++ a; // 0x00 = single response
    return encode(.{ .dst = ADDR_ECU, .src = ADDR_TOOL, .cmd = CMD_ADDR_READ, .data = &data }, buf);
}

/// `A8` address-read request for one or more 24-bit addresses in one packet.
/// `scratch` must hold `1 + 3 * addrs.len` bytes.
pub fn addrReadMany(addrs: []const u24, scratch: []u8, buf: []u8) Error![]u8 {
    const n = 1 + 3 * addrs.len;
    if (scratch.len < n) return error.NoSpaceLeft;
    scratch[0] = 0x00; // single response
    for (addrs, 0..) |addr, i| {
        scratch[1 + 3 * i ..][0..3].* = addrBytes(addr);
    }
    return encode(.{
        .dst = ADDR_ECU,
        .src = ADDR_TOOL,
        .cmd = CMD_ADDR_READ,
        .data = scratch[0..n],
    }, buf);
}

// ---------------------------------------------------------------- tests

test "checksum of init request" {
    // 0x80 + 0x10 + 0xF0 + 0x01 + 0xBF = 0x240 -> 0x40
    try std.testing.expectEqual(@as(u8, 0x40), checksum(&.{ 0x80, 0x10, 0xF0, 0x01, 0xBF }));
}

test "encode init matches documented example" {
    var buf: [32]u8 = undefined;
    const got = try init(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x10, 0xF0, 0x01, 0xBF, 0x40 }, got);
}

test "encode address read matches documented example" {
    var buf: [32]u8 = undefined;
    const got = try addrRead(0x000008, &buf);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x80, 0x10, 0xF0, 0x05, 0xA8, 0x00, 0x00, 0x00, 0x08, 0x35 },
        got,
    );
}

test "encode address read of two addresses matches documented example" {
    var buf: [32]u8 = undefined;
    var scratch: [16]u8 = undefined;
    const got = try addrReadMany(&.{ 0x000008, 0x00001C }, &scratch, &buf);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x80, 0x10, 0xF0, 0x08, 0xA8, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x1C, 0x54 },
        got,
    );
}

test "decode address read response" {
    const frame = [_]u8{ 0x80, 0xF0, 0x10, 0x03, 0xE8, 0x7D, 0xB1, 0x99 };
    const d = try decode(&frame);
    try std.testing.expectEqual(ADDR_TOOL, d.dst);
    try std.testing.expectEqual(ADDR_ECU, d.src);
    try std.testing.expectEqual(RESP_ADDR_READ, d.cmd);
    try std.testing.expectEqualSlices(u8, &.{ 0x7D, 0xB1 }, d.data);
}

test "decode rejects bad checksum" {
    const frame = [_]u8{ 0x80, 0xF0, 0x10, 0x03, 0xE8, 0x7D, 0xB1, 0x00 };
    try std.testing.expectError(error.BadChecksum, decode(&frame));
}

test "decode rejects bad header and short frames" {
    try std.testing.expectError(error.TooShort, decode(&.{ 0x80, 0x10 }));
    try std.testing.expectError(error.BadHeader, decode(&.{ 0x81, 0x10, 0xF0, 0x01, 0xBF, 0x00 }));
}
