//! A kernel LED whose brightness is driven from userspace: /dev/uleds.
//!
//! Writing a name and a maximum registers /sys/class/leds/<name>, which the
//! rest of the system -- UPower, and through it the desktop -- treats as any
//! other LED. Whatever sets its brightness wakes a read() on the same fd with
//! the new value. Closing the fd unregisters it.

const std = @import("std");
const posix = std.posix;

/// <linux/uleds.h>
const UserDev = extern struct {
    name: [64]u8,
    max_brightness: c_int,
};

pub const Led = struct {
    fd: posix.fd_t,
    /// "/sys/class/leds/<name>/brightness"
    brightness_path_buf: [128]u8,
    brightness_path_len: usize,

    pub fn create(name: []const u8, max_brightness: u8) !Led {
        const fd = try posix.open("/dev/uleds", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        errdefer posix.close(fd);

        var dev: UserDev = .{ .name = [_]u8{0} ** 64, .max_brightness = max_brightness };
        if (name.len >= dev.name.len) return error.NameTooLong;
        @memcpy(dev.name[0..name.len], name);
        _ = try posix.write(fd, std.mem.asBytes(&dev));

        var led: Led = .{ .fd = fd, .brightness_path_buf = undefined, .brightness_path_len = 0 };
        led.brightness_path_len = (try std.fmt.bufPrint(&led.brightness_path_buf, "/sys/class/leds/{s}/brightness", .{name})).len;
        return led;
    }

    pub fn close(self: *Led) void {
        posix.close(self.fd);
    }

    /// Blocks until something sets a brightness different from the last one.
    ///
    /// The first read after registering returns at once, with 0: uleds marks a
    /// new LED as having news. Setting the brightness before that first read
    /// replaces the 0 rather than queueing behind it -- there is one slot, not
    /// a queue -- which is how `set` below keeps that 0 from ever being seen.
    pub fn next(self: *Led) !u8 {
        var value: c_int = 0;
        const n = try posix.read(self.fd, std.mem.asBytes(&value));
        if (n != @sizeOf(c_int)) return error.ShortRead;
        return @intCast(std.math.clamp(value, 0, 255));
    }

    /// Sets the LED's brightness as any other writer would, so that UPower
    /// reads the level the keyboard is actually at. It comes back through
    /// `next` like any other change.
    pub fn set(self: *Led, level: u8) !void {
        const file = try std.fs.openFileAbsolute(self.brightness_path_buf[0..self.brightness_path_len], .{ .mode = .write_only });
        defer file.close();
        var buf: [4]u8 = undefined;
        try file.writeAll(try std.fmt.bufPrint(&buf, "{d}", .{level}));
    }
};

test "the registration struct is the kernel's 68 bytes" {
    try std.testing.expectEqual(@as(usize, 68), @sizeOf(UserDev));
}
