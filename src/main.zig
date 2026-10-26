//! glim: a Razer Blade's keyboard backlight, as an LED the desktop can drive.
//!
//! The Blade's keyboard backlight lives in its EC, which the kernel has no
//! driver for, so nothing in /sys/class/leds speaks for it and UPower -- and
//! so GNOME and KDE -- cannot see it. glim registers a
//! `razer::kbd_backlight` LED through uleds and passes every brightness the
//! desktop sets on to the EC over hidraw. The desktop then does the rest:
//! dimming when idle, off when the screen blanks, the brightness slider.
//!
//! The Fn brightness keys never reach the desktop: the EC acts on them itself
//! and only reports the new level, on a hidraw interface that `glim run`
//! alone reads. It announces each such level on /run/glim/fn.sock, and `glim
//! follow`, run in the desktop session, passes it on to GNOME, whose slider
//! and remembered level would otherwise go stale.

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const razer = @import("razer.zig");
const hidraw = @import("hidraw.zig");
const uleds = @import("uleds.zig");
const notify = @import("notify.zig");
const dbus = @import("dbus.zig");
const events = @import("events.zig");

const log = std.log.scoped(.glim);

pub const std_options: std.Options = .{ .log_level = .info };

/// Vendor, no colour, function: the shape UPower matches on (`kbd_backlight`)
/// and the kernel's own LED naming convention.
const led_name = "razer::kbd_backlight";

const default_fn_hold_ms = 250;

const usage =
    \\Usage: glim [command] [options]
    \\
    \\Commands:
    \\  run        Serve the keyboard backlight as an LED (the default)
    \\  follow     Tell GNOME about brightness set with the Fn keys; run as
    \\             the desktop user, in the session
    \\  probe      Say which Blade was found and its current brightness
    \\  udev-rules Print the udev rules glim's install puts in place
    \\  version    Print the version
    \\  help       Print this help
    \\
    \\Options for run:
    \\  --fn-hold-ms N  After the Fn keys change the brightness, ignore the
    \\                  desktop's for N ms, which is its echo of that change
    \\                  coming back through `glim follow` (default 250)
    \\
    \\`glim run` needs root, or at least read-write access to /dev/uleds, the
    \\Blade's hidraw nodes and /sys/class/leds. The uleds module must be loaded.
    \\
;

pub fn main() !void {
    const argv = std.os.argv;
    const command: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "run";
    const options = if (argv.len > 2) argv[2..] else argv[0..0];

    if (eql(command, "run")) return run(try parseRunOptions(options));
    if (options.len > 0) usageError("'{s}' takes no options", .{command});
    if (eql(command, "follow")) return follow();
    if (eql(command, "probe")) return probe();
    if (eql(command, "udev-rules")) return udevRules();
    if (eql(command, "version") or eql(command, "--version")) return print("{s}\n", .{build_options.version});
    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h")) return print(usage, .{});
    usageError("unknown command '{s}'", .{command});
}

const RunOptions = struct { fn_hold_ms: u32 = default_fn_hold_ms };

fn parseRunOptions(args: []const [*:0]u8) !RunOptions {
    var options: RunOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        const value = if (std.mem.startsWith(u8, arg, "--fn-hold-ms="))
            arg["--fn-hold-ms=".len..]
        else if (eql(arg, "--fn-hold-ms") and i + 1 < args.len) blk: {
            i += 1;
            break :blk std.mem.span(args[i]);
        } else usageError("unknown option '{s}'", .{arg});
        options.fn_hold_ms = std.fmt.parseInt(u32, value, 10) catch
            usageError("--fn-hold-ms wants a number of milliseconds, not '{s}'", .{value});
        if (options.fn_hold_ms > 10_000) usageError("--fn-hold-ms is at most 10000", .{});
    }
    return options;
}

fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("glim: " ++ fmt ++ "\n\n" ++ usage, args);
    std.process.exit(2);
}

/// What `run` knows between events.
const Run = struct {
    dev: ?hidraw.Device,
    notifier: ?hidraw.Notifier,
    led: *uleds.Led,
    listeners: *events.Server,
    /// The EC's level, as last set or reported.
    current: u8,
    fn_hold_ms: u32,
    /// Until when the LED's changes are the desktop's echo of a Fn change,
    /// on the monotonic clock.
    hold_until_ms: i64 = 0,
    /// While Fn is held, when next to ask the EC for its level; null when
    /// it is not held.
    next_ask_ms: ?i64 = null,

    /// How often to ask the EC for its level while Fn is held: a drop to 0
    /// is otherwise unannounced until Fn is let go.
    const fn_poll_ms = 100;

    /// How long `poll` may wait: forever, unless Fn is held.
    fn timeout(self: *const Run) i32 {
        const next = self.next_ask_ms orelse return -1;
        return @intCast(std.math.clamp(next - nowMs(), 0, fn_poll_ms));
    }

    /// Asks the EC if Fn is held and it is time, whatever woke `poll`: key
    /// reports arrive on the same interface, and typing with Fn held must
    /// not put the question off.
    fn askIfDue(self: *Run) void {
        const next = self.next_ask_ms orelse return;
        if (nowMs() < next) return;
        self.next_ask_ms = nowMs() + fn_poll_ms;
        self.askEc();
    }

    fn onNotification(self: *Run) void {
        const n = if (self.notifier) |*n| n else return;
        var buf: [64]u8 = undefined;
        const report = n.read(&buf) catch |err| {
            log.warn("{s}: {s}; no longer following the Fn keys until the EC is found again", .{ n.name(), @errorName(err) });
            n.close();
            self.notifier = null;
            return;
        };
        if (razer.brightnessNotification(report)) |level| return self.onFnChange(level);
        if (razer.specialKeyHeld(report)) |held| {
            if (held) {
                if (self.next_ask_ms == null) self.next_ask_ms = nowMs() + fn_poll_ms;
            } else {
                self.next_ask_ms = null;
                // Once more as Fn comes up, for a press in the last 100 ms.
                self.askEc();
            }
        }
    }

    /// Asks the EC for its level, for the change it does not report: to 0.
    fn askEc(self: *Run) void {
        const d = if (self.dev) |*d| d else return;
        const level = d.brightness() catch |err| {
            log.warn("{s}: {s}; could not ask the EC what the Fn keys did", .{ d.name(), @errorName(err) });
            return;
        };
        self.onFnChange(level);
    }

    /// The EC changed the brightness itself. The LED is set to match, so
    /// UPower reads the real level, the listeners are told, and the hold
    /// starts: `glim follow` tells GNOME, GNOME tells UPower, and UPower
    /// writes the LED -- in about 15 ms, and slightly off, since GNOME counts
    /// in percent. Sent on, that echo would undo presses made since and nudge
    /// the level.
    ///
    /// A level it already has is no change, and GNOME is not told: the EC
    /// reports one on resume. By then GNOME has turned the backlight off with
    /// the screen, and is about to put back what it had, without a word to
    /// its own slider. Told the 0 first, the slider shows off from then on.
    fn onFnChange(self: *Run, level: u8) void {
        if (level == self.current) return;
        self.current = level;
        self.hold_until_ms = nowMs() + self.fn_hold_ms;
        self.led.set(level) catch |err| log.warn("could not set the LED to {d}: {s}", .{ level, @errorName(err) });
        self.listeners.announce(level);
    }

    fn onLed(self: *Run, level: u8) void {
        if (nowMs() < self.hold_until_ms) return;
        if (level == self.current) return;
        if (self.apply(level)) self.current = level;
    }

    /// Sets the EC's brightness, finding the device again if it has gone: a
    /// USB reset, as across some resumes, gives the same interface a new
    /// hidraw node. The LED is left alone either way -- the desktop holds on
    /// to it, so it has to outlive any device it forwards to.
    fn apply(self: *Run, level: u8) bool {
        if (self.dev) |*d| {
            if (d.setBrightness(level)) return true else |err| {
                log.warn("{s}: {s}, looking for the EC again", .{ d.name(), @errorName(err) });
                d.close();
                self.dev = null;
            }
        }
        self.dev = findWaiting(2 * std.time.ms_per_s) catch |err| {
            log.err("EC not found ({s}); brightness {d} not applied", .{ @errorName(err), level });
            return false;
        };
        const d = &self.dev.?;
        log.info("{s} on {s}", .{ d.model.name, d.name() });
        if (self.notifier == null) self.notifier = hidraw.findNotifier() catch null;
        d.setBrightness(level) catch |err| {
            log.err("{s}: {s}; brightness {d} not applied", .{ d.name(), @errorName(err), level });
            return false;
        };
        return true;
    }
};

fn run(options: RunOptions) !void {
    // The EC first: without it there is nothing for the LED to mean. At boot
    // its hidraw nodes can come up a moment after we do.
    const device = try findWaiting(10 * std.time.ms_per_s);
    var dev = device;
    const level = try dev.brightness();
    const notifier = hidraw.findNotifier() catch null;
    log.info("{s} on {s}, brightness {d}; Fn key changes {s}{s}", .{
        device.model.name,                                        device.name(),                      level,
        if (notifier != null) "reported on " else "not reported", if (notifier) |n| n.name() else "",
    });

    var listeners = try events.Server.listen(events.socket_path);
    defer listeners.close();

    var led = uleds.Led.create(led_name, 255) catch |err| {
        if (err == error.FileNotFound) log.err("/dev/uleds is missing: load the uleds module", .{});
        return err;
    };
    defer led.close();
    // Before the first read, so UPower starts from the keyboard's real level
    // rather than the 0 every new LED begins at.
    try led.set(level);
    notify.ready();

    var state: Run = .{
        .dev = dev,
        .notifier = notifier,
        .led = &led,
        .listeners = &listeners,
        .current = level,
        .fn_hold_ms = options.fn_hold_ms,
    };
    const fixed = 3;
    while (true) {
        var fds: [fixed + events.max_clients]posix.pollfd = undefined;
        fds[0] = .{ .fd = led.fd, .events = posix.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = if (state.notifier) |n| n.fd else -1, .events = posix.POLL.IN, .revents = 0 };
        fds[2] = .{ .fd = listeners.fd, .events = posix.POLL.IN, .revents = 0 };
        // Listeners only listen: polled for nothing but their hanging up.
        for (listeners.clients, fds[fixed..]) |c, *f| f.* = .{ .fd = c, .events = 0, .revents = 0 };
        _ = try posix.poll(&fds, state.timeout());

        // The notification first: when both are ready, the LED's change may
        // be the echo of it.
        if (fds[1].revents != 0) state.onNotification();
        if (fds[0].revents & posix.POLL.IN != 0) state.onLed(try led.next());
        if (fds[2].revents != 0) listeners.accept();
        for (&listeners.clients, fds[fixed..]) |*c, f| {
            if (f.revents != 0) listeners.drop(c);
        }
        state.askIfDue();
    }
}

/// Passes the levels the EC chose itself on to GNOME, through the
/// org.gnome.SettingsDaemon.Power.Keyboard Brightness property on the session
/// bus. That is the only way in: GNOME ignores a change it hears of from
/// UPower unless the kernel reported it, and an LED made through uleds cannot.
///
/// It hears of them from `glim run`, over /run/glim/fn.sock, and never touches
/// the Blade itself. Exits quietly on a machine with no Blade, and with an
/// error when glim or the bus goes away, for the user unit to restart it.
fn follow() !void {
    if (!try hidraw.bladePresent()) {
        log.info("no supported Razer laptop here; nothing to follow", .{});
        return;
    }
    const glim = events.connect(events.socket_path) catch |err| {
        log.err("cannot reach glim on {s}: {s}", .{ events.socket_path, @errorName(err) });
        return err;
    };
    defer posix.close(glim);

    var bus: dbus.Connection = undefined;
    try bus.openSession();
    defer bus.close();
    log.info("passing Fn brightness changes on to GNOME", .{});

    var warned = false;
    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = glim, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = bus.fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, -1);
        if (fds[1].revents != 0) try bus.discardPending();
        if (fds[0].revents == 0) continue;

        const level = try events.receive(glim);
        const outcome = bus.call(.{
            .destination = "org.gnome.SettingsDaemon.Power",
            .path = "/org/gnome/SettingsDaemon/Power",
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Set",
            .args = .{
                .signature = "ssv",
                .strings = &.{ "org.gnome.SettingsDaemon.Power.Keyboard", "Brightness" },
                .variant_int32 = percent(level),
            },
        }, 1000);
        // Said once, not per key press: without GNOME there is no one to tell,
        // and that can last the whole session.
        if (outcome) |reply| switch (reply) {
            .ok => if (warned) {
                log.info("GNOME is taking brightness changes again", .{});
                warned = false;
            },
            .failed => |f| if (!warned) {
                log.warn("GNOME did not take brightness {d}: {s}: {s}", .{ level, f.name, f.message });
                warned = true;
            },
        } else |err| switch (err) {
            error.Timeout => if (!warned) {
                log.warn("GNOME did not answer about brightness {d}", .{level});
                warned = true;
            },
            else => return err,
        }
    }
}

/// GNOME's keyboard brightness is a percentage of the LED's 0..255, rounded
/// as GNOME rounds (gpm-common.c). GNOME turns it back into a level within
/// one or two of this one; the hold in `glim run` keeps that from the EC.
fn percent(level: u8) i32 {
    return gnomeConvert(level, 255, 100);
}

/// round(value / from * to), as gsd_power_backlight_convert_safe does it.
fn gnomeConvert(value: i32, from: i32, to: i32) i32 {
    return @divTrunc(value * to + @divTrunc(from, 2), from);
}

fn nowMs() i64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch unreachable;
    return ts.sec * std.time.ms_per_s + @divTrunc(ts.nsec, std.time.ns_per_ms);
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

/// Per model: start glim.service when the Blade appears, rather than at boot
/// on every machine, where it would only fail and retry. Printed from the table `find` matches against, so the two cannot disagree
/// about which laptops glim is for.
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

test "a level comes back from GNOME's percentage within rounding" {
    var level: u16 = 0;
    while (level <= 255) : (level += 1) {
        const back = gnomeConvert(percent(@intCast(level)), 100, 255);
        try std.testing.expect(@abs(back - @as(i32, level)) <= 2);
    }
    try std.testing.expectEqual(@as(i32, 0), percent(0));
    try std.testing.expectEqual(@as(i32, 100), percent(255));
}

test {
    // Each file's tests, and every declaration here, so the test build
    // type-checks the whole program and not only the code tests reach.
    _ = razer;
    _ = hidraw;
    _ = uleds;
    _ = notify;
    _ = dbus;
    _ = events;
    std.testing.refAllDecls(@This());
}
