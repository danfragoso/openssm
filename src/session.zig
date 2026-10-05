//! SSM link session over the OpenPort: opens the ISO9141 (K-line) or ISO15765
//! (CAN) channel, installs the mandatory pass-all filter, and exchanges SSM
//! packets as raw bus frames.

const std = @import("std");
const Device = @import("device.zig").Device;
const StoredFrame = @import("device.zig").StoredFrame;
const ssm = @import("ssm.zig");

pub const ISO9141: u8 = 3;
pub const ISO15765: u8 = 6;

pub const Link = struct {
    dev: *Device,
    proto: u8,

    /// Open the classic SSM K-line channel (ISO9141, 4800 8N1).
    ///
    /// No message filter is installed: the CAN-style 4-byte selector filter is
    /// rejected on ISO9141 (`are 22` = ERR_INVALID_FILTER_ID), and the firmware
    /// forwards K-line replies without one.
    pub fn openKline(dev: *Device) !Link {
        try dev.openChannel(ISO9141, 0x1, 4800, 0);
        return .{ .dev = dev, .proto = ISO9141 };
    }

    /// Open the SSM-over-CAN channel (ISO15765 @ 500 kbit).
    pub fn openCan(dev: *Device, baud: u32) !Link {
        try dev.openChannel(ISO15765, 0x1, baud, 0);
        try dev.installFilter(ISO15765, 0, &.{ 0, 0, 0, 0 }, &.{ 0, 0, 0, 0 });
        return .{ .dev = dev, .proto = ISO15765 };
    }

    pub fn close(self: *Link) void {
        self.dev.closeChannel(self.proto) catch {};
    }

    pub fn sendSsm(self: *Link, packet: []const u8) !void {
        try self.dev.sendFrame(self.proto, packet, 0, 100_000);
    }

    /// Wait for the next bus frame (null when quiet).
    pub fn recv(self: *Link) !?StoredFrame {
        return self.dev.waitFrame();
    }

    /// Send an SSM request and return the first response that decodes as an SSM
    /// packet of the expected response command, or null on timeout.
    pub fn request(self: *Link, packet: []const u8, want_cmd: u8) !?ssm.Decoded {
        try self.sendSsm(packet);
        var spins: usize = 0;
        while (spins < 100_000) : (spins += 1) {
            const f = (try self.recv()) orelse return null;
            const d = ssm.decode(f.data()) catch continue;
            if (d.cmd == want_cmd) return d;
        }
        return null;
    }
};

const testing = std.testing;
const Mock = @import("transport.zig").Mock;

test "kline init receives and decodes an SSM response frame" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();

    // SSM init response: 80 F0 10 07 FF <5-byte ECU id> <cap> <sum>
    var pkt: [12]u8 = .{ 0x80, 0xF0, 0x10, 0x07, 0xFF, 0x7A, 0x46, 0x58, 0x54, 0x01, 0xFF, 0x00 };
    pkt[11] = ssm.checksum(pkt[0..11]);

    // acks: ato(1), att(2); then the binary frame
    try m.inject("aro 1\r\naro 2\r\n");
    var fr: [64]u8 = undefined;
    fr[0] = 'a';
    fr[1] = 'r';
    fr[2] = '3';
    fr[3] = @intCast(9 + pkt.len);
    fr[4] = 0;
    std.mem.writeInt(u32, fr[5..9], 1, .big);
    std.mem.writeInt(u32, fr[9..13], 0, .big);
    @memcpy(fr[13 .. 13 + pkt.len], &pkt);
    try m.inject(fr[0 .. 13 + pkt.len]);

    var dev = Device.init(m.transport());
    var link = try Link.openKline(&dev);

    var buf: [16]u8 = undefined;
    const init_pkt = try ssm.init(&buf);
    const d = (try link.request(init_pkt, ssm.RESP_INIT)).?;
    try testing.expectEqual(ssm.RESP_INIT, d.cmd);
    try testing.expectEqualSlices(u8, &.{ 0x7A, 0x46, 0x58, 0x54, 0x01 }, d.data[0..5]);
}
