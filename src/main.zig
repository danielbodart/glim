//! glim: a Razer Blade's keyboard backlight, as an LED the desktop can drive.
//!
//! The Blade's keyboard backlight lives in its EC, which the kernel has no
//! driver for, so nothing in /sys/class/leds speaks for it and UPower -- and
//! so GNOME and KDE -- cannot see it. glim registers a
//! `razer::kbd_backlight` LED through uleds and passes every brightness the
//! desktop sets on to the EC over hidraw. The desktop then does the rest:
//! dimming when idle, off when the screen blanks, the brightness slider and
//! keys.

const std = @import("std");
const build_options = @import("build_options");
const razer = @import("razer.zig");
const hidraw = @import("hidraw.zig");
const uleds = @import("uleds.zig");
const notify = @import("notify.zig");

const log = std.log.scoped(.glim);

pub const std_options: std.Options = .{ .log_level = .info };

/// Vendor, no colour, function: the shape UPower matches on (`kbd_backlight`)
/// and the kernel's own LED naming convention.
const led_name = "razer::kbd_backlight";

const usage =
    \\Usage: glim [command]
    \\
    \\Commands:
    \\  run        Serve the keyboard backlight as an LED (the default)
    \\  probe      Say which Blade was found and its current brightness
    \\  udev-rules Print the udev rules that start glim.service on a Blade
    \\  version    Print the version
    \\  help       Print this help
    \\
    \\glim needs root, or at least read-write access to /dev/uleds, the Blade's
    \\hidraw nodes and /sys/class/leds. The uleds module must be loaded.
    \\
;

pub fn main() !void {
    const command: []const u8 = if (std.os.argv.len > 1) std.mem.span(std.os.argv[1]) else "run";

    if (eql(command, "run")) return run();
    if (eql(command, "probe")) return probe();
    if (eql(command, "udev-rules")) return udevRules();
    if (eql(command, "version") or eql(command, "--version")) return print("{s}\n", .{build_options.version});
    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h")) return print(usage, .{});

    std.debug.print("glim: unknown command '{s}'\n\n" ++ usage, .{command});
    std.process.exit(2);
}

fn run() !void {
    // The EC first: without it there is nothing for the LED to mean. At boot
    // its hidraw nodes can come up a moment after we do.
    var device = try findWaiting(10 * std.time.ms_per_s);
    const level = try device.brightness();
    log.info("{s} on {s}, brightness {d}", .{ device.model.name, device.name(), level });

    var led = uleds.Led.create(led_name, 255) catch |err| {
        if (err == error.FileNotFound) log.err("/dev/uleds is missing: load the uleds module", .{});
        return err;
    };
    defer led.close();
    // Before the first read, so UPower starts from the keyboard's real level
    // rather than the 0 every new LED begins at.
    try led.set(level);
    notify.ready();

    var current = level;
    var dev: ?hidraw.Device = device;
    while (true) {
        const wanted = try led.next();
        if (wanted == current) continue;
        if (apply(&dev, wanted)) current = wanted;
    }
}

/// Sets the EC's brightness, finding the device again if it has gone: a USB
/// reset, as across some resumes, gives the same interface a new hidraw node.
/// The LED is left alone either way -- UPower only looks for keyboard LEDs
/// when it starts, so this one has to outlive any device it forwards to.
fn apply(dev: *?hidraw.Device, level: u8) bool {
    if (dev.*) |*d| {
        if (d.setBrightness(level)) return true else |err| {
            log.warn("{s}: {s}, looking for the EC again", .{ d.name(), @errorName(err) });
            d.close();
            dev.* = null;
        }
    }
    dev.* = findWaiting(2 * std.time.ms_per_s) catch |err| {
        log.err("EC not found ({s}); brightness {d} not applied", .{ @errorName(err), level });
        return false;
    };
    const d = &dev.*.?;
    log.info("{s} on {s}", .{ d.model.name, d.name() });
    d.setBrightness(level) catch |err| {
        log.err("{s}: {s}; brightness {d} not applied", .{ d.name(), @errorName(err), level });
        return false;
    };
    return true;
}

fn findWaiting(timeout_ms: u64) !hidraw.Device {
    const step_ms = 250;
    var waited: u64 = 0;
    while (true) : (waited += step_ms) {
        if (try hidraw.find()) |d| return d;
        if (waited >= timeout_ms) return error.NoSupportedDevice;
        std.Thread.sleep(step_ms * std.time.ns_per_ms);
    }
}

fn probe() !void {
    var device = (try hidraw.find()) orelse {
        std.debug.print("glim: no supported Razer laptop found\n", .{});
        std.process.exit(1);
    };
    defer device.close();
    try print("{s}  {s}  1532:{x:0>4}  brightness {d}/255\n", .{
        device.name(), device.model.name, device.model.product_id, try device.brightness(),
    });
}

/// glim.service is started by udev, when a Blade it knows appears, rather
/// than at boot on every machine: elsewhere it would only fail and retry.
/// Printed from the same table `find` matches against, so the two cannot
/// disagree about which laptops glim is for.
fn udevRules() !void {
    try print("# Written by `glim udev-rules`: start glim.service when a Razer laptop it\n" ++
        "# knows appears. One line per model.\n", .{});
    for (razer.models) |m| {
        try print("SUBSYSTEM==\"hidraw\", ATTRS{{idVendor}}==\"{x:0>4}\", ATTRS{{idProduct}}==\"{x:0>4}\", " ++
            "TAG+=\"systemd\", ENV{{SYSTEMD_WANTS}}+=\"glim.service\"\n", .{ razer.razer_vendor_id, m.product_id });
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn print(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    // Streaming, not positional: a positional writer on a redirected stdout
    // starts every call at offset 0, so each print would overwrite the last.
    var writer = std.fs.File.stdout().writerStreaming(&buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test {
    // Every declaration, so the test build type-checks the whole program and
    // not only the files that happen to hold tests.
    std.testing.refAllDeclsRecursive(@This());
}
