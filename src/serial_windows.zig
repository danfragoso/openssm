//! Windows serial transport to the OpenPort 2.0's USB CDC-ACM interface
//! (a virtual COM port), via the Win32 comm API.
//!
//! The Win32 `DCB` has C bitfields, which `@cImport` translates to an opaque
//! type, so the DCB and COMMTIMEOUTS layouts are declared explicitly here.

const std = @import("std");
const win = std.os.windows;
const Transport = @import("transport.zig").Transport;

const HANDLE = win.HANDLE;
const DWORD = win.DWORD;
const BOOL = win.BOOL;

extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommState(h: HANDLE, dcb: *DCB) callconv(.winapi) BOOL;
extern "kernel32" fn SetCommState(h: HANDLE, dcb: *const DCB) callconv(.winapi) BOOL;
extern "kernel32" fn SetCommTimeouts(h: HANDLE, t: *const COMMTIMEOUTS) callconv(.winapi) BOOL;
extern "kernel32" fn PurgeComm(h: HANDLE, flags: DWORD) callconv(.winapi) BOOL;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const PURGE_TXCLEAR: DWORD = 0x0004;
const PURGE_RXCLEAR: DWORD = 0x0008;
const CBR_115200: DWORD = 115200;
const NOPARITY: u8 = 0;
const ONESTOPBIT: u8 = 0;
const INVALID_HANDLE_VALUE = @as(HANDLE, @ptrFromInt(std.math.maxInt(usize)));

// fBinary=1, fDtrControl=1 (ENABLE), fRtsControl=1 (ENABLE)
const DCB_FLAGS: u32 = (1 << 0) | (1 << 4) | (1 << 12);

const DCB = extern struct {
    DCBlength: u32,
    BaudRate: u32,
    flags: u32,
    wReserved: u16,
    XonLim: u16,
    XoffLim: u16,
    ByteSize: u8,
    Parity: u8,
    StopBits: u8,
    XonChar: u8,
    XoffChar: u8,
    ErrorChar: u8,
    EofChar: u8,
    EvtChar: u8,
    wReserved1: u16,
};

const COMMTIMEOUTS = extern struct {
    ReadIntervalTimeout: u32,
    ReadTotalTimeoutMultiplier: u32,
    ReadTotalTimeoutConstant: u32,
    WriteTotalTimeoutMultiplier: u32,
    WriteTotalTimeoutConstant: u32,
};

comptime {
    if (@sizeOf(DCB) != 28) @compileError("DCB layout mismatch");
    if (@sizeOf(COMMTIMEOUTS) != 20) @compileError("COMMTIMEOUTS layout mismatch");
}

pub const Serial = struct {
    handle: HANDLE = INVALID_HANDLE_VALUE,

    pub fn open(path: []const u8) !Serial {
        var full_buf: [64]u8 = undefined;
        const full = try comPath(path, &full_buf);

        var wide: [128]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, full) catch return error.BadPath;
        wide[n] = 0;

        const h = win.kernel32.CreateFileW(
            @ptrCast(&wide),
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == INVALID_HANDLE_VALUE) return error.OpenFailed;
        errdefer _ = CloseHandle(h);

        var dcb: DCB = std.mem.zeroes(DCB);
        dcb.DCBlength = @sizeOf(DCB);
        _ = GetCommState(h, &dcb);
        dcb.DCBlength = @sizeOf(DCB);
        dcb.BaudRate = CBR_115200; // CDC ignores line coding; keep it legal
        dcb.flags = DCB_FLAGS;
        dcb.ByteSize = 8;
        dcb.Parity = NOPARITY;
        dcb.StopBits = ONESTOPBIT;
        if (SetCommState(h, &dcb) == 0) return error.TermiosFailed;

        // Block up to 500 ms, then return whatever is available (0 = quiet).
        const to = COMMTIMEOUTS{
            .ReadIntervalTimeout = 0xFFFFFFFF,
            .ReadTotalTimeoutMultiplier = 0,
            .ReadTotalTimeoutConstant = 500,
            .WriteTotalTimeoutMultiplier = 0,
            .WriteTotalTimeoutConstant = 0,
        };
        _ = SetCommTimeouts(h, &to);
        _ = PurgeComm(h, PURGE_RXCLEAR | PURGE_TXCLEAR);

        return .{ .handle = h };
    }

    pub fn deinit(self: *Serial) void {
        if (self.handle != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(self.handle);
            self.handle = INVALID_HANDLE_VALUE;
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
            var wrote: DWORD = 0;
            if (win.kernel32.WriteFile(self.handle, bytes.ptr + done, @intCast(bytes.len - done), &wrote, null) == 0)
                return error.WriteFailed;
            if (wrote == 0) return error.WriteFailed;
            done += wrote;
        }
    }

    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Serial = @ptrCast(@alignCast(ptr));
        var got: DWORD = 0;
        if (win.kernel32.ReadFile(self.handle, @ptrCast(buf.ptr), @intCast(buf.len), &got, null) == 0)
            return error.ReadFailed;
        return got;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self: *Serial = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

fn comPath(path: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "\\\\.\\")) return path;
    return std.fmt.bufPrint(buf, "\\\\.\\{s}", .{path});
}

/// Probe COM1..COM32 and return the first that opens, copied into `buf`.
pub fn firstCandidate(buf: []u8) !?[]const u8 {
    var i: u32 = 1;
    while (i <= 32) : (i += 1) {
        const name = try std.fmt.bufPrint(buf, "COM{d}", .{i});
        var full_buf: [64]u8 = undefined;
        const full = comPath(name, &full_buf) catch continue;

        var wide: [128]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, full) catch continue;
        wide[n] = 0;

        const h = win.kernel32.CreateFileW(
            @ptrCast(&wide),
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(h);
            return name;
        }
    }
    return null;
}
