const std = @import("std");

pub const ssm = @import("ssm.zig");
pub const openport = @import("openport.zig");
pub const transport = @import("transport.zig");
pub const device = @import("device.zig");
pub const serial = @import("serial.zig");
pub const platform = @import("platform.zig");
pub const ipc = @import("ipc.zig");
pub const session = @import("session.zig");

const Device = device.Device;
const AutoMock = transport.AutoMock;

pub fn main() !void {
    ignoreSigpipe();
    const gpa = std.heap.page_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        usage();
        return;
    }

    const cmd = args[1];
    var opts = try Options.parse(gpa, args[2..]);

    if (std.mem.eql(u8, cmd, "probe")) {
        return runProbe(gpa, &opts);
    }
    if (std.mem.eql(u8, cmd, "raw")) {
        return runRaw(gpa, &opts);
    }
    if (std.mem.eql(u8, cmd, "kline")) {
        return runKline(gpa, &opts);
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        return runServe(gpa, &opts, false);
    }
    if (std.mem.eql(u8, cmd, "mock-serve")) {
        return runServe(gpa, &opts, true);
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) {
        usage();
        return;
    }
    print("unknown command: {s}\n", .{cmd});
    usage();
}

fn runProbe(gpa: std.mem.Allocator, opts: *Options) !void {
    var path_buf: [256]u8 = undefined;
    const path = try resolveSerialPath(opts, &path_buf);
    var ser = serial.Serial.open(path) catch {
        print("failed to open {s}\n", .{path});
        return error.OpenFailed;
    };
    var dev = Device.init(ser.transport());

    const fw = try dev.identify();
    print("device: {s}\n", .{path});
    print("firmware: {s}\n", .{fw});
    const mv = try dev.readAnalog(16);
    print("vbatt: {d} mV\n", .{mv});
    _ = gpa;
}

fn runRaw(gpa: std.mem.Allocator, opts: *Options) !void {
    const line = opts.positional orelse {
        print("usage: openssm raw \"<at command>\" [--serial PATH]\n", .{});
        return error.NoCommand;
    };
    var path_buf: [256]u8 = undefined;
    const path = try resolveSerialPath(opts, &path_buf);
    var ser = serial.Serial.open(path) catch {
        print("failed to open {s}\n", .{path});
        return error.OpenFailed;
    };
    var dev = Device.init(ser.transport());

    var body: [512]u8 = undefined;
    var body_len: usize = 0;
    if (opts.hex) |h| {
        body_len = try decodeHex(h, &body);
    }
    var out: [4096]u8 = undefined;
    const n = try dev.rawExchangeBody(line, body[0..body_len], &out);
    print("tx: {s}", .{line});
    if (body_len != 0) {
        print(" + ", .{});
        for (body[0..body_len]) |b| print("{x:0>2} ", .{b});
    }
    print("\n", .{});
    print("rx {d} bytes:\n", .{n});
    print("  hex: ", .{});
    for (out[0..n]) |b| print("{x:0>2} ", .{b});
    print("\n  txt: ", .{});
    for (out[0..n]) |b| {
        if (b >= 0x20 and b < 0x7f) print("{c}", .{b}) else print(".", .{});
    }
    print("\n", .{});
    _ = gpa;
}

fn runKline(gpa: std.mem.Allocator, opts: *Options) !void {
    var path_buf: [256]u8 = undefined;
    const path = try resolveSerialPath(opts, &path_buf);
    var ser = serial.Serial.open(path) catch {
        print("failed to open {s}\n", .{path});
        return error.OpenFailed;
    };
    var dev = Device.init(ser.transport());

    const fw = try dev.identify();
    print("device: {s}\nfirmware: {s}\n", .{ path, fw });
    const vbatt = try dev.readAnalog(16);
    print("vbatt: {d} mV\n", .{vbatt});

    dev.closeAll() catch {}; // clear any channels a prior session left open
    var link = session.Link.openKline(&dev) catch |e| {
        print("open K-line failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer link.close();
    print("K-line open (ISO9141 @ 4800). Sending SSM init...\n", .{});

    var buf: [16]u8 = undefined;
    try link.sendSsm(try ssm.init(&buf));

    var got: usize = 0;
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        const f = (try link.recv()) orelse break;
        const d = f.data();
        print("rx frame: ", .{});
        for (d) |b| print("{x:0>2} ", .{b});
        print("\n", .{});
        if (ssm.decode(d)) |pkt| {
            if (pkt.cmd == ssm.RESP_INIT) {
                print("  SSM init response, ecu id = ", .{});
                for (pkt.data[0..@min(5, pkt.data.len)]) |b| print("{x:0>2}", .{b});
                print("\n", .{});
                got += 1;
            }
        } else |_| {
            print("  (not an SSM packet)\n", .{});
        }
    }
    print("decoded SSM init responses: {d}\n", .{got});
    _ = gpa;
}

fn runServe(gpa: std.mem.Allocator, opts: *Options, mock: bool) !void {
    const address = try buildAddress(gpa, opts);

    if (mock) {
        var m = AutoMock.init(gpa);
        var dev = Device.init(m.transport());
        var ctx = ipc.Context{ .gpa = gpa, .dev = &dev };
        print("openssm mock server listening on {s}\n", .{opts.describe()});
        try ipc.serve(&ctx, address);
        return;
    }

    var path_buf: [256]u8 = undefined;
    const path = try resolveSerialPath(opts, &path_buf);
    var ser = serial.Serial.open(path) catch {
        print("failed to open {s}\n", .{path});
        return error.OpenFailed;
    };
    var dev = Device.init(ser.transport());
    var ctx = ipc.Context{ .gpa = gpa, .dev = &dev };
    print("openssm server listening on {s} (serial {s})\n", .{ opts.describe(), path });
    try ipc.serve(&ctx, address);
}

fn resolveSerialPath(opts: *Options, buf: []u8) ![]const u8 {
    if (opts.serial) |p| return p;
    return (try serial.firstCandidate(buf)) orelse {
        print("no OpenPort serial device found; pass --serial PATH\n", .{});
        return error.NoDevice;
    };
}

fn buildAddress(gpa: std.mem.Allocator, opts: *Options) !std.net.Address {
    _ = gpa;
    if (opts.tcp) |hostport| {
        const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.BadAddress;
        const host = hostport[0..colon];
        const port = try std.fmt.parseInt(u16, hostport[colon + 1 ..], 10);
        const h = if (host.len == 0) "127.0.0.1" else host;
        return std.net.Address.parseIp(h, port);
    }
    if (comptime platform.is_windows) {
        if (opts.unix != null) return error.UnixSocketsUnsupported;
        return std.net.Address.parseIp("127.0.0.1", 7878);
    }
    const path = opts.unix orelse "/tmp/openssm.sock";
    std.fs.deleteFileAbsolute(path) catch {};
    return std.net.Address.initUnix(path);
}

const Options = struct {
    serial: ?[]const u8 = null,
    unix: ?[]const u8 = null,
    tcp: ?[]const u8 = null,
    hex: ?[]const u8 = null,
    positional: ?[]const u8 = null,

    fn parse(_: std.mem.Allocator, argv: []const []const u8) !Options {
        var o = Options{};
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const a = argv[i];
            if (std.mem.eql(u8, a, "--serial") and i + 1 < argv.len) {
                i += 1;
                o.serial = argv[i];
            } else if (std.mem.eql(u8, a, "--unix") and i + 1 < argv.len) {
                i += 1;
                o.unix = argv[i];
            } else if (std.mem.eql(u8, a, "--tcp") and i + 1 < argv.len) {
                i += 1;
                o.tcp = argv[i];
            } else if (std.mem.eql(u8, a, "--hex") and i + 1 < argv.len) {
                i += 1;
                o.hex = argv[i];
            } else if (o.positional == null) {
                o.positional = a;
            }
        }
        return o;
    }

    fn describe(self: Options) []const u8 {
        if (self.tcp) |t| return t;
        return self.unix orelse "/tmp/openssm.sock (unix)";
    }
};

fn decodeHex(s: []const u8, out: []u8) !usize {
    var n: usize = 0;
    var hi: ?u8 = null;
    for (s) |ch| {
        const v: u8 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            ' ', 'x', 'X', ':', ',' => continue,
            else => return error.BadHex,
        };
        if (hi) |h| {
            if (n == out.len) return error.BadHex;
            out[n] = (h << 4) | v;
            n += 1;
            hi = null;
        } else {
            hi = v;
        }
    }
    return n;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    platform.stdoutWrite(s);
}

fn usage() void {
    print(
        \\openssm - Subaru Select Monitor (SSM) reader
        \\
        \\usage:
        \\  openssm probe [--serial PATH]
        \\  openssm raw "<at command>" [--hex AABBCC] [--serial PATH]
        \\  openssm kline [--serial PATH]
        \\  openssm serve [--serial PATH] [--unix PATH | --tcp HOST:PORT]
        \\  openssm mock-serve [--unix PATH | --tcp HOST:PORT]
        \\
        \\--serial defaults to the first /dev/cu.usbmodem* / usbserial* node.
        \\serves JSON-lines IPC; see ipc.zig for the method contract.
        \\
    , .{});
}

/// Ignore SIGPIPE so a dropped IPC client cannot kill the daemon.
fn ignoreSigpipe() void {
    platform.ignoreSigpipe();
}

test {
    _ = @import("ssm.zig");
    _ = @import("openport.zig");
    _ = @import("transport.zig");
    _ = @import("device.zig");
    _ = @import("serial.zig");
    _ = @import("ipc.zig");
    _ = @import("session.zig");
}
