//! JSON-lines IPC server. One request object per line, one response per line,
//! over a Unix domain socket or TCP. This is the contract clients build against.
//!
//!   -> {"id":1,"method":"probe"}
//!   <- {"id":1,"result":{"firmware":"...","vbatt_mv":12300}}
//!   -> {"id":2,"method":"analog","params":{"pin":16}}
//!   <- {"id":2,"result":{"pin":16,"millivolts":12300}}
//!   -> {"id":3,"method":"open","params":{"proto":3,"flags":1,"baud":4800,"chan":0}}
//!   <- {"id":3,"result":{"ok":true}}
//! errors: {"id":3,"error":{"message":"Timeout"}}

const std = @import("std");
const posix = std.posix;
const Device = @import("device.zig").Device;
const openport = @import("openport.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    dev: *Device,
    mutex: std.Thread.Mutex = .{},
};

const Request = struct {
    id: std.json.Value = .null,
    method: []const u8,
    params: std.json.Value = .null,
};

pub fn serve(ctx: *Context, address: std.net.Address) !void {
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    while (true) {
        const conn = server.accept() catch continue;
        const t = std.Thread.spawn(.{}, handleConn, .{ ctx, conn }) catch {
            conn.stream.close();
            continue;
        };
        t.detach();
    }
}

fn handleConn(ctx: *Context, conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    var buf: [16384]u8 = undefined;
    var len: usize = 0;
    while (true) {
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |idx| {
            const line = std.mem.trim(u8, buf[0..idx], " \r\t");
            if (line.len != 0) {
                const resp = dispatch(ctx, line) catch |e| {
                    std.debug.print("ipc dispatch error: {s}\n", .{@errorName(e)});
                    return;
                };
                defer ctx.gpa.free(resp);
                writeAll(conn.stream.handle, resp) catch return;
                writeAll(conn.stream.handle, "\n") catch return;
            }
            const rest = len - (idx + 1);
            std.mem.copyForwards(u8, buf[0..rest], buf[idx + 1 .. len]);
            len = rest;
        }
        if (len == buf.len) {
            len = 0; // oversize line: drop it
            continue;
        }
        const n = posix.read(conn.stream.handle, buf[len..]) catch return;
        if (n == 0) return;
        len += n;
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        done += try posix.write(fd, bytes[done..]);
    }
}

fn success(gpa: std.mem.Allocator, id: std.json.Value, result: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{ .id = id, .result = result }, .{});
}

const Failure = struct {
    id: std.json.Value,
    @"error": struct { message: []const u8 },
};

fn failure(gpa: std.mem.Allocator, id: std.json.Value, msg: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, Failure{ .id = id, .@"error" = .{ .message = msg } }, .{});
}

fn dispatch(ctx: *Context, line: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(Request, ctx.gpa, line, .{}) catch {
        return failure(ctx.gpa, .null, "invalid json");
    };
    defer parsed.deinit();
    const req = parsed.value;
    const id = req.id;

    if (std.mem.eql(u8, req.method, "ping")) {
        return success(ctx.gpa, id, .{ .pong = true });
    }

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    const m = req.method;
    if (std.mem.eql(u8, m, "identify")) {
        const fw = ctx.dev.identify() catch |e| return failure(ctx.gpa, id, @errorName(e));
        return success(ctx.gpa, id, .{ .firmware = fw });
    }
    if (std.mem.eql(u8, m, "probe")) {
        const fw = ctx.dev.identify() catch |e| return failure(ctx.gpa, id, @errorName(e));
        const mv = ctx.dev.readAnalog(16) catch |e| return failure(ctx.gpa, id, @errorName(e));
        return success(ctx.gpa, id, .{ .firmware = fw, .vbatt_mv = mv });
    }
    if (std.mem.eql(u8, m, "analog")) {
        const pin = getInt(req.params, "pin") orelse return failure(ctx.gpa, id, "missing integer 'pin'");
        const mv = ctx.dev.readAnalog(@intCast(pin)) catch |e| return failure(ctx.gpa, id, @errorName(e));
        return success(ctx.gpa, id, .{ .pin = pin, .millivolts = mv });
    }
    if (std.mem.eql(u8, m, "open")) {
        const proto = getInt(req.params, "proto") orelse return failure(ctx.gpa, id, "missing 'proto'");
        const flags = getInt(req.params, "flags") orelse 0;
        const baud = getInt(req.params, "baud") orelse 4800;
        const chan = getInt(req.params, "chan") orelse 0;
        ctx.dev.openChannel(@intCast(proto), @intCast(flags), @intCast(baud), @intCast(chan)) catch |e|
            return failure(ctx.gpa, id, @errorName(e));
        return success(ctx.gpa, id, .{ .ok = true });
    }
    if (std.mem.eql(u8, m, "close")) {
        const proto = getInt(req.params, "proto") orelse return failure(ctx.gpa, id, "missing 'proto'");
        ctx.dev.closeChannel(@intCast(proto)) catch |e| return failure(ctx.gpa, id, @errorName(e));
        return success(ctx.gpa, id, .{ .ok = true });
    }
    if (std.mem.eql(u8, m, "closeAll")) {
        ctx.dev.closeAll() catch |e| return failure(ctx.gpa, id, @errorName(e));
        return success(ctx.gpa, id, .{ .ok = true });
    }
    return failure(ctx.gpa, id, "unknown method");
}

fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const x = obj.get(key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 0) catch null,
        else => null,
    };
}

test "dispatch ping and unknown method" {
    var mock = @import("transport.zig").AutoMock.init(std.testing.allocator);
    defer mock.deinit();
    var dev = Device.init(mock.transport());
    var ctx = Context{ .gpa = std.testing.allocator, .dev = &dev };

    const pong = try dispatch(&ctx, "{\"id\":1,\"method\":\"ping\"}");
    defer std.testing.allocator.free(pong);
    try std.testing.expect(std.mem.indexOf(u8, pong, "\"pong\":true") != null);

    const bad = try dispatch(&ctx, "{\"id\":2,\"method\":\"nope\"}");
    defer std.testing.allocator.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "unknown method") != null);
}

test "dispatch probe returns firmware and vbatt" {
    var mock = @import("transport.zig").AutoMock.init(std.testing.allocator);
    defer mock.deinit();
    var dev = Device.init(mock.transport());
    var ctx = Context{ .gpa = std.testing.allocator, .dev = &dev };

    const r = try dispatch(&ctx, "{\"id\":7,\"method\":\"probe\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "1.17.4877") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "12300") != null);
}
