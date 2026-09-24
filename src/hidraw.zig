//! Finding the EC's control interface among /dev/hidraw*, and exchanging
//! feature reports with it.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const razer = @import("razer.zig");

const log = std.log.scoped(.hidraw);

/// A feature report on the wire: the report number, then the report. The EC
/// uses report 0, which hidraw still wants spelled out as the first byte.
const feature_len = 1 + razer.report_len;

pub const Device = struct {
    fd: posix.fd_t,
    model: razer.Model,
    /// e.g. "hidraw6", for the log.
    name_buf: [32]u8,
    name_len: usize,

    pub fn name(self: *const Device) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn close(self: *Device) void {
        posix.close(self.fd);
    }

    pub fn brightness(self: *Device) !u8 {
        const response = try self.exchange(razer.request(razer.get_brightness, &.{0x01}), razer.get_brightness);
        return razer.payload(&response)[1];
    }

    pub fn setBrightness(self: *Device, level: u8) !void {
        _ = try self.exchange(razer.request(razer.set_brightness, &.{ 0x01, level }), razer.set_brightness);
    }

    /// Send `report` and read the EC's answer back. OpenRazer waits 600-800us
    /// between the two; an EC still working on it says `busy`, and is asked
    /// again rather than written to again.
    fn exchange(self: *Device, report: [razer.report_len]u8, command: razer.Command) ![razer.report_len]u8 {
        var out = [_]u8{0} ** feature_len;
        out[1..].* = report;
        try ioctl(self.fd, hidiocsfeature, &out);

        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            std.Thread.sleep(800 * std.time.ns_per_us);
            var in = [_]u8{0} ** feature_len;
            try ioctl(self.fd, hidiocgfeature, &in);
            const response: [razer.report_len]u8 = in[1..].*;
            if (razer.answers(&response, command)) return response;
            switch (razer.status(&response)) {
                .busy => continue,
                else => |s| {
                    log.debug("{s}: {s} for class 0x{x:0>2} id 0x{x:0>2}", .{ self.name(), @tagName(s), command.class, command.id });
                    return error.Refused;
                },
            }
        }
        return error.Busy;
    }
};

/// _IOC(_IOC_WRITE|_IOC_READ, 'H', nr, len), as <linux/hidraw.h> defines
/// HIDIOCSFEATURE and HIDIOCGFEATURE.
fn iocWR(nr: u8, len: u14) u32 {
    return (3 << 30) | (@as(u32, len) << 16) | (@as(u32, 'H') << 8) | nr;
}
const hidiocsfeature = iocWR(0x06, feature_len);
const hidiocgfeature = iocWR(0x07, feature_len);

fn ioctl(fd: posix.fd_t, request: u32, buf: *[feature_len]u8) !void {
    const rc = linux.ioctl(fd, request, @intFromPtr(buf));
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .NODEV, .IO, .NXIO => return error.Gone,
        else => |e| return posix.unexpectedErrno(e),
    }
}

pub const HidId = struct { bus: u16, vendor: u16, product: u16 };

/// The HID_ID line of a hidraw device's uevent, "HID_ID=0003:00001532:0000029F":
/// bus, vendor and product, the last two zero-padded to 32 bits.
pub fn parseHidId(uevent: []const u8) ?HidId {
    var lines = std.mem.tokenizeScalar(u8, uevent, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "HID_ID=")) continue;
        const value = line["HID_ID=".len..];
        var fields = std.mem.splitScalar(u8, value, ':');
        const bus = fields.next() orelse return null;
        const vendor = fields.next() orelse return null;
        const product = fields.next() orelse return null;
        return .{
            .bus = std.fmt.parseInt(u16, bus, 16) catch return null,
            .vendor = std.fmt.parseInt(u16, vendor, 16) catch return null,
            .product = std.fmt.parseInt(u16, product, 16) catch return null,
        };
    }
    return null;
}

/// The first hidraw node belonging to a known Blade that answers a brightness
/// query. A Blade has three HID interfaces; which of them takes control
/// reports is not something to hard-code when the answer is one query away.
pub fn find() !?Device {
    var dir = std.fs.openDirAbsolute("/sys/class/hidraw", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const uevent_path = try std.fmt.bufPrint(&path_buf, "{s}/device/uevent", .{entry.name});
        var uevent_buf: [1024]u8 = undefined;
        const uevent = dir.readFile(uevent_path, &uevent_buf) catch continue;
        const id = parseHidId(uevent) orelse continue;
        if (id.vendor != razer.razer_vendor_id) continue;
        const model = razer.model(id.product) orelse continue;

        const dev_path = try std.fmt.bufPrint(&path_buf, "/dev/{s}", .{entry.name});
        const fd = posix.open(dev_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch |err| {
            log.warn("{s}: {s}", .{ dev_path, @errorName(err) });
            continue;
        };
        var device: Device = .{ .fd = fd, .model = model, .name_buf = undefined, .name_len = entry.name.len };
        @memcpy(device.name_buf[0..entry.name.len], entry.name);
        if (device.brightness()) |_| {
            return device;
        } else |_| {
            device.close();
        }
    }
    return null;
}

test "HID_ID is read from anywhere in the uevent" {
    const uevent =
        \\DRIVER=hid-generic
        \\HID_ID=0003:00001532:0000029F
        \\HID_NAME=Razer Razer Blade
        \\
    ;
    const id = parseHidId(uevent).?;
    try std.testing.expectEqual(@as(u16, 0x0003), id.bus);
    try std.testing.expectEqual(@as(u16, 0x1532), id.vendor);
    try std.testing.expectEqual(@as(u16, 0x029F), id.product);
}

test "a uevent without HID_ID, or with a mangled one, is not a device" {
    try std.testing.expect(parseHidId("DRIVER=hid-generic\n") == null);
    try std.testing.expect(parseHidId("HID_ID=0003:00001532\n") == null);
    try std.testing.expect(parseHidId("HID_ID=0003:zz:0000029F\n") == null);
}

test "the feature ioctls match <linux/hidraw.h> for a 91-byte buffer" {
    // HIDIOCSFEATURE(91) and HIDIOCGFEATURE(91), as the C macros expand them.
    try std.testing.expectEqual(@as(u32, 0xC05B4806), hidiocsfeature);
    try std.testing.expectEqual(@as(u32, 0xC05B4807), hidiocgfeature);
}
