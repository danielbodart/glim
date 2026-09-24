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

/// A hidraw node that belongs to a known Blade.
const Node = struct {
    model: razer.Model,
    name_buf: [32]u8,
    name_len: usize,

    fn name(self: *const Node) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn open(self: *const Node, flags: posix.O) !posix.fd_t {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/dev/{s}", .{self.name()});
        return posix.open(path, flags, 0) catch |err| {
            log.warn("{s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    }

    /// Whether this interface is the one the EC sends its notifications on.
    fn notifies(self: *const Node, dir: std.fs.Dir) bool {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/device/report_descriptor", .{self.name()}) catch return false;
        var descriptor_buf: [4096]u8 = undefined;
        const descriptor = dir.readFile(path, &descriptor_buf) catch return false;
        return declaresInput(descriptor, razer.notification_report_id);
    }
};

/// The Blade's hidraw nodes, from /sys/class/hidraw. A Blade has three HID
/// interfaces; which does what is read from each rather than assumed.
const BladeNodes = struct {
    dir: std.fs.Dir,
    it: std.fs.Dir.Iterator,

    fn open() !?BladeNodes {
        var dir = std.fs.openDirAbsolute("/sys/class/hidraw", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return .{ .dir = dir, .it = dir.iterate() };
    }

    fn close(self: *BladeNodes) void {
        self.dir.close();
    }

    fn next(self: *BladeNodes) !?Node {
        while (try self.it.next()) |entry| {
            if (entry.name.len > 32) continue;
            var path_buf: [64]u8 = undefined;
            const uevent_path = try std.fmt.bufPrint(&path_buf, "{s}/device/uevent", .{entry.name});
            var uevent_buf: [1024]u8 = undefined;
            const uevent = self.dir.readFile(uevent_path, &uevent_buf) catch continue;
            const id = parseHidId(uevent) orelse continue;
            if (id.vendor != razer.razer_vendor_id) continue;
            const model = razer.model(id.product) orelse continue;
            var node: Node = .{ .model = model, .name_buf = undefined, .name_len = entry.name.len };
            @memcpy(node.name_buf[0..entry.name.len], entry.name);
            return node;
        }
        return null;
    }
};

/// The first of a known Blade's hidraw nodes that answers a brightness query.
/// All three of the Blade 16's do; probing costs one query and assumes
/// nothing about other models.
pub fn find() !?Device {
    var nodes = (try BladeNodes.open()) orelse return null;
    defer nodes.close();
    while (try nodes.next()) |node| {
        const fd = node.open(.{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch continue;
        var device: Device = .{ .fd = fd, .model = node.model, .name_buf = node.name_buf, .name_len = node.name_len };
        if (device.brightness()) |_| {
            return device;
        } else |_| {
            device.close();
        }
    }
    return null;
}

/// Whether a known Blade is here, judged from sysfs without opening anything.
pub fn bladePresent() !bool {
    var nodes = (try BladeNodes.open()) orelse return false;
    defer nodes.close();
    return try nodes.next() != null;
}

/// The EC's notification interface, open for reading: the node whose report
/// descriptor declares input report 0x05.
///
/// On the Blade 16 that interface is also a keyboard: every key press comes
/// through it as report 0x01, alongside the EC's reports. hidraw has no way to
/// ask for some reports and not others, so whoever reads it gets a copy of
/// each keystroke. `glim run` drops them unread, and it is the only reader --
/// `glim follow` hears from it over a socket, and is never given the device.
pub fn findNotifier() !?Notifier {
    var nodes = (try BladeNodes.open()) orelse return null;
    defer nodes.close();
    while (try nodes.next()) |node| {
        if (!node.notifies(nodes.dir)) continue;
        const fd = node.open(.{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch continue;
        return .{ .fd = fd, .name_buf = node.name_buf, .name_len = node.name_len };
    }
    return null;
}

pub const Notifier = struct {
    fd: posix.fd_t,
    name_buf: [32]u8,
    name_len: usize,

    pub fn name(self: *const Notifier) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn close(self: *Notifier) void {
        posix.close(self.fd);
    }

    /// One input report: hidraw hands over a whole report per read.
    pub fn read(self: *Notifier, buf: []u8) ![]const u8 {
        const n = try posix.read(self.fd, buf);
        if (n == 0) return error.Gone;
        return buf[0..n];
    }
};

/// Whether a HID report descriptor declares an input report with this ID.
/// Only short items are interpreted: a Report ID (global, tag 8) sets the
/// report the items after it belong to, and an Input (main, tag 8) under it is
/// the declaration. Long items are stepped over.
pub fn declaresInput(descriptor: []const u8, report_id: u8) bool {
    var report: u8 = 0;
    var i: usize = 0;
    while (i < descriptor.len) {
        const prefix = descriptor[i];
        if (prefix == 0xFE) {
            if (i + 1 >= descriptor.len) return false;
            i += 3 + @as(usize, descriptor[i + 1]);
            continue;
        }
        const size: usize = switch (prefix & 0x03) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 4,
        };
        if (i + 1 + size > descriptor.len) return false;
        switch (prefix & 0xFC) {
            0x84 => if (size > 0) {
                report = descriptor[i + 1];
            },
            0x80 => if (report == report_id) return true,
            else => {},
        }
        i += 1 + size;
    }
    return false;
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

test "the notification interface is told apart by its report descriptor" {
    // The Blade 16's three descriptors, trimmed to what matters: interface 1
    // declares input reports 1 to 5, interface 2 only a 90-byte feature
    // report, and interface 0 has no report IDs at all.
    const interface1 = [_]u8{
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x81, 0x02, 0xc0,
        0x05, 0x01, 0x09, 0x00, 0xa1, 0x01, 0x85, 0x04, 0x95, 0x0f, 0x81,
        0x00, 0xc0, 0x05, 0x01, 0x09, 0x00, 0xa1, 0x01, 0x85, 0x05, 0x09,
        0x03, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x0f, 0x81,
        0x00, 0xc0,
    };
    const interface2 = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x06, 0x00, 0xff, 0x09, 0x02,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x08, 0x95, 0x5a, 0xb1, 0x01, 0xc0,
    };
    const interface0 = [_]u8{ 0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0xc0 };
    try std.testing.expect(declaresInput(&interface1, 0x05));
    try std.testing.expect(!declaresInput(&interface2, 0x05));
    try std.testing.expect(!declaresInput(&interface0, 0x05));
}

test "a truncated descriptor is not read past its end" {
    try std.testing.expect(!declaresInput(&.{ 0x85, 0x05, 0x81 }, 0x05));
    try std.testing.expect(!declaresInput(&.{0x85}, 0x05));
    try std.testing.expect(!declaresInput(&.{ 0xFE, 0x10 }, 0x05));
}
