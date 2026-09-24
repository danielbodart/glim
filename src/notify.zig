//! sd_notify(3) without libsystemd: one datagram to $NOTIFY_SOCKET.
//!
//! glim says READY=1 once the LED exists and carries the keyboard's real
//! level, so a unit ordered Before=upower.service really is done by the time
//! UPower looks for keyboard backlights -- which it does once, at startup.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.notify);

/// Does nothing when not started by systemd, or not as Type=notify.
pub fn ready() void {
    send("READY=1") catch |err| log.warn("could not tell systemd we are ready: {s}", .{@errorName(err)});
}

fn send(message: []const u8) !void {
    const path = posix.getenv("NOTIFY_SOCKET") orelse return;
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = [_]u8{0} ** 108 };
    if (path.len == 0 or path.len >= addr.path.len) return error.BadSocketPath;
    @memcpy(addr.path[0..path.len], path);
    // An abstract socket is spelled with a leading '@' and addressed with a
    // leading NUL, and its length counts exactly the name, no terminator.
    if (path[0] == '@') addr.path[0] = 0;
    const len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len);

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(fd);
    _ = try posix.sendto(fd, message, 0, @ptrCast(&addr), len);
}
