//! The brightness levels the EC chose itself -- the Fn keys -- as `glim run`
//! announces them to whoever listens: `glim follow`, in each desktop session.
//! Each listener is first told the level as it stands when it connects.
//!
//! A SOCK_SEQPACKET socket at /run/glim/fn.sock, so each level is one message:
//! its decimal digits and a newline. Anyone may connect -- all it tells is the
//! keyboard's brightness -- and listening is all a client can do.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.events);

/// In the unit's RuntimeDirectory.
pub const socket_path = "/run/glim/fn.sock";

pub const max_clients = 8;

pub const Server = struct {
    fd: posix.fd_t,
    clients: [max_clients]posix.fd_t = [_]posix.fd_t{-1} ** max_clients,

    pub fn listen(path: []const u8) !Server {
        const addr = try address(path);
        // Left by a glim that did not get to clean up.
        posix.unlink(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.SEQPACKET | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, max_clients);
        // Connecting to a unix socket takes write permission on it.
        var path_z: [108:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        switch (posix.errno(linux.fchmodat(posix.AT.FDCWD, path_z[0..path.len :0], 0o666, 0))) {
            .SUCCESS => {},
            else => |e| return posix.unexpectedErrno(e),
        }
        return .{ .fd = fd };
    }

    pub fn close(self: *Server) void {
        for (&self.clients) |*c| self.drop(c);
        posix.close(self.fd);
    }

    /// Takes a waiting connection and tells it `level`, the one it would
    /// otherwise only learn at the next change. Past `max_clients`, the
    /// newcomer is turned away: more sessions than that on one laptop is not
    /// a real case.
    pub fn accept(self: *Server, level: u8) void {
        const fd = posix.accept(self.fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch return;
        for (&self.clients) |*c| {
            if (c.* == -1) {
                c.* = fd;
                self.send(c, level);
                return;
            }
        }
        log.warn("more than {d} listeners; turning one away", .{max_clients});
        posix.close(fd);
    }

    /// Sends `level` to every listener, dropping any that has gone.
    pub fn announce(self: *Server, level: u8) void {
        for (&self.clients) |*c| {
            if (c.* != -1) self.send(c, level);
        }
    }

    fn send(self: *Server, client: *posix.fd_t, level: u8) void {
        var buf: [4]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{d}\n", .{level}) catch unreachable;
        _ = posix.send(client.*, msg, posix.MSG.NOSIGNAL) catch self.drop(client);
    }

    pub fn drop(self: *Server, client: *posix.fd_t) void {
        _ = self;
        if (client.* == -1) return;
        posix.close(client.*);
        client.* = -1;
    }
};

pub fn connect(path: []const u8) !posix.fd_t {
    const addr = try address(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.SEQPACKET | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    return fd;
}

/// The next level announced. error.Disconnected when glim has gone.
pub fn receive(fd: posix.fd_t) !u8 {
    var buf: [16]u8 = undefined;
    const n = try posix.read(fd, &buf);
    if (n == 0) return error.Disconnected;
    return parse(buf[0..n]);
}

fn parse(msg: []const u8) !u8 {
    return std.fmt.parseInt(u8, std.mem.trimRight(u8, msg, "\n"), 10) catch error.BadMessage;
}

fn address(path: []const u8) !posix.sockaddr.un {
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = [_]u8{0} ** 108 };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

test "levels go from the server to every listener, one message each" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try dir.dir.realpath(".", &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/fn.sock", .{dir_path});
    if (path.len >= 108) return error.SkipZigTest;

    var server = try Server.listen(path);
    defer server.close();
    const a = try connect(path);
    defer posix.close(a);
    const b = try connect(path);
    server.accept(120);
    server.accept(120);
    // Each first hears the level as it was when it came.
    try std.testing.expectEqual(@as(u8, 120), try receive(a));
    try std.testing.expectEqual(@as(u8, 120), try receive(b));

    server.announce(165);
    server.announce(0);
    try std.testing.expectEqual(@as(u8, 165), try receive(a));
    try std.testing.expectEqual(@as(u8, 0), try receive(a));
    try std.testing.expectEqual(@as(u8, 165), try receive(b));

    // A listener that has gone is dropped, not a reason to fail the others.
    posix.close(b);
    server.announce(30);
    server.announce(45);
    try std.testing.expectEqual(@as(u8, 30), try receive(a));
    try std.testing.expectEqual(@as(u8, 45), try receive(a));
}

test "a malformed message is refused, not misread" {
    try std.testing.expectEqual(@as(u8, 7), try parse("7\n"));
    try std.testing.expectError(error.BadMessage, parse("256\n"));
    try std.testing.expectError(error.BadMessage, parse("x\n"));
}
