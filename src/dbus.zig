//! Just enough of D-Bus to call a method on the session bus and hear whether
//! it worked: connect, authenticate as ourselves, say Hello, marshal a method
//! call, and read replies. No match rules, so the bus only ever sends us
//! replies and the odd message addressed to us.
//!
//! Little-endian throughout, and only the types the header fields and glim's
//! own calls use: y, u, i, s, o, g and a variant holding one of them.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.dbus);

const MessageType = enum(u8) { method_call = 1, method_return = 2, @"error" = 3, signal = 4, _ };

const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    _,
};

/// A method call's arguments, already marshalled, with their signature. Only
/// what glim sends: strings, and a variant holding an int32.
pub const Args = struct {
    signature: []const u8 = "",
    strings: []const []const u8 = &.{},
    variant_int32: ?i32 = null,
};

pub const Call = struct {
    destination: []const u8,
    path: []const u8,
    interface: []const u8,
    member: []const u8,
    args: Args = .{},
};

pub const Reply = union(enum) {
    ok,
    /// The error's name, and its message when it came with one, in the
    /// connection's buffer: good until the next call.
    failed: struct { name: []const u8, message: []const u8 },
};

pub const Connection = struct {
    fd: posix.fd_t,
    serial: u32 = 0,
    /// Bytes read from the bus and not yet consumed as whole messages.
    in_buf: [64 * 1024]u8 = undefined,
    in_len: usize = 0,
    /// Where the last message handed out began and ended, so the next read
    /// can drop it.
    consumed: usize = 0,

    /// $DBUS_SESSION_BUS_ADDRESS, or /run/user/<uid>/bus when that is unset.
    pub fn openSession(self: *Connection) !void {
        var fallback_buf: [64]u8 = undefined;
        const address = posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
            try std.fmt.bufPrint(&fallback_buf, "unix:path=/run/user/{d}/bus", .{linux.getuid()});
        try self.open(address);
    }

    pub fn open(self: *Connection, address: []const u8) !void {
        const addr = try parseAddress(address);
        self.* = .{ .fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) };
        errdefer posix.close(self.fd);
        try posix.connect(self.fd, @ptrCast(&addr.sockaddr), addr.len);
        try self.authenticate();
        switch (try self.call(.{
            .destination = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
        }, 5000)) {
            .ok => {},
            .failed => return error.HelloRefused,
        }
    }

    pub fn close(self: *Connection) void {
        posix.close(self.fd);
    }

    /// The SASL exchange: a NUL, then EXTERNAL with our uid in hex-encoded
    /// ASCII, which the bus checks against the socket's peer credentials.
    fn authenticate(self: *Connection) !void {
        var uid_buf: [16]u8 = undefined;
        const uid = try std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()});
        var line_buf: [64]u8 = undefined;
        const auth = try std.fmt.bufPrint(&line_buf, "\x00AUTH EXTERNAL {x}\r\n", .{uid});
        try writeAll(self.fd, auth);

        var reply_buf: [256]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOf(u8, reply_buf[0..len], "\r\n") == null) {
            if (len == reply_buf.len) return error.AuthReplyTooLong;
            const n = try posix.read(self.fd, reply_buf[len..]);
            if (n == 0) return error.Disconnected;
            len += n;
        }
        if (!std.mem.startsWith(u8, reply_buf[0..len], "OK ")) return error.AuthRejected;
        try writeAll(self.fd, "BEGIN\r\n");
    }

    /// Sends `c` and waits up to `timeout_ms` for its reply, dropping anything
    /// else the bus sends meanwhile.
    pub fn call(self: *Connection, c: Call, timeout_ms: i32) !Reply {
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        var msg_buf: [1024]u8 = undefined;
        const msg = try marshalCall(&msg_buf, self.serial, c);
        try writeAll(self.fd, msg);

        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (true) {
            while (try self.nextMessage()) |m| {
                const header = try parseHeader(m);
                if (header.reply_serial != self.serial) continue;
                switch (header.type) {
                    .method_return => return .ok,
                    .@"error" => return .{ .failed = .{
                        .name = header.error_name,
                        .message = firstString(m[header.body_offset..], header.signature),
                    } },
                    else => continue,
                }
            }
            const left = deadline - std.time.milliTimestamp();
            if (left <= 0) return error.Timeout;
            var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&fds, @intCast(left)) == 0) return error.Timeout;
            try self.fill();
        }
    }

    /// Reads what the bus has sent and drops it. For when the fd polls
    /// readable between calls: nothing unasked for is worth acting on, but
    /// left unread it would keep waking the poll.
    pub fn discardPending(self: *Connection) !void {
        try self.fill();
        while (try self.nextMessage()) |_| {}
    }

    fn fill(self: *Connection) !void {
        self.compact();
        if (self.in_len == self.in_buf.len) return error.MessageTooLarge;
        const n = try posix.read(self.fd, self.in_buf[self.in_len..]);
        if (n == 0) return error.Disconnected;
        self.in_len += n;
    }

    fn compact(self: *Connection) void {
        if (self.consumed == 0) return;
        std.mem.copyForwards(u8, self.in_buf[0..], self.in_buf[self.consumed..self.in_len]);
        self.in_len -= self.consumed;
        self.consumed = 0;
    }

    /// The next whole message in the buffer, or null until more arrives.
    fn nextMessage(self: *Connection) !?[]const u8 {
        const pending = self.in_buf[self.consumed..self.in_len];
        const len = try messageLength(pending) orelse return null;
        if (pending.len < len) {
            if (len > self.in_buf.len) return error.MessageTooLarge;
            return null;
        }
        self.consumed += len;
        return pending[0..len];
    }
};

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) written += try posix.write(fd, bytes[written..]);
}

const Address = struct { sockaddr: posix.sockaddr.un, len: posix.socklen_t };

/// The first unix: transport in a bus address, by path= or abstract=.
/// Addresses list alternatives separated by ';', each a transport and
/// comma-separated key=value pairs.
fn parseAddress(address: []const u8) !Address {
    var transports = std.mem.splitScalar(u8, address, ';');
    while (transports.next()) |transport| {
        if (!std.mem.startsWith(u8, transport, "unix:")) continue;
        var pairs = std.mem.splitScalar(u8, transport["unix:".len..], ',');
        while (pairs.next()) |pair| {
            const abstract = std.mem.startsWith(u8, pair, "abstract=");
            if (!abstract and !std.mem.startsWith(u8, pair, "path=")) continue;
            const value = pair[std.mem.indexOfScalar(u8, pair, '=').? + 1 ..];
            var result: Address = .{ .sockaddr = .{ .family = posix.AF.UNIX, .path = [_]u8{0} ** 108 }, .len = 0 };
            const start: usize = if (abstract) 1 else 0;
            if (start + value.len >= result.sockaddr.path.len) return error.AddressTooLong;
            @memcpy(result.sockaddr.path[start..][0..value.len], value);
            const path_len = start + value.len + @as(usize, if (abstract) 0 else 1);
            result.len = @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len);
            return result;
        }
    }
    return error.NoUnixAddress;
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn pad(self: *Writer, alignment: usize) !void {
        const target = std.mem.alignForward(usize, self.len, alignment);
        if (target > self.buf.len) return error.NoSpaceLeft;
        @memset(self.buf[self.len..target], 0);
        self.len = target;
    }

    fn bytes(self: *Writer, b: []const u8) !void {
        if (self.len + b.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len..][0..b.len], b);
        self.len += b.len;
    }

    fn byte(self: *Writer, b: u8) !void {
        try self.bytes(&.{b});
    }

    fn uint32(self: *Writer, v: u32) !void {
        try self.pad(4);
        try self.bytes(&std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }

    fn int32(self: *Writer, v: i32) !void {
        try self.uint32(@bitCast(v));
    }

    fn string(self: *Writer, s: []const u8) !void {
        try self.uint32(@intCast(s.len));
        try self.bytes(s);
        try self.byte(0);
    }

    fn signature(self: *Writer, s: []const u8) !void {
        try self.byte(@intCast(s.len));
        try self.bytes(s);
        try self.byte(0);
    }

    fn field(self: *Writer, code: Field, type_code: u8, value: []const u8) !void {
        try self.pad(8);
        try self.byte(@intFromEnum(code));
        try self.signature(&.{type_code});
        if (type_code == 'g') try self.signature(value) else try self.string(value);
    }
};

fn marshalCall(buf: []u8, serial: u32, c: Call) ![]const u8 {
    var w: Writer = .{ .buf = buf };
    try w.bytes(&.{ 'l', @intFromEnum(MessageType.method_call), 0, 1 });
    try w.uint32(0); // body length, patched below
    try w.uint32(serial);
    try w.uint32(0); // header fields' array length, patched below
    const fields_start = std.mem.alignForward(usize, w.len, 8);
    try w.field(.path, 'o', c.path);
    try w.field(.destination, 's', c.destination);
    try w.field(.interface, 's', c.interface);
    try w.field(.member, 's', c.member);
    if (c.args.signature.len > 0) try w.field(.signature, 'g', c.args.signature);
    const fields_len = w.len - fields_start;
    try w.pad(8);

    const body_start = w.len;
    for (c.args.strings) |s| try w.string(s);
    if (c.args.variant_int32) |v| {
        try w.signature("i");
        try w.int32(v);
    }
    const body_len = w.len - body_start;

    std.mem.writeInt(u32, buf[4..8], @intCast(body_len), .little);
    std.mem.writeInt(u32, buf[12..16], @intCast(fields_len), .little);
    return buf[0..w.len];
}

/// The total length of the message at the start of `bytes`, from its fixed
/// header, or null if even that has not arrived.
fn messageLength(bytes: []const u8) !?usize {
    if (bytes.len < 16) return null;
    if (bytes[0] != 'l') return error.BigEndianMessage;
    const body_len = std.mem.readInt(u32, bytes[4..8], .little);
    const fields_len = std.mem.readInt(u32, bytes[12..16], .little);
    return std.mem.alignForward(usize, 16 + fields_len, 8) + body_len;
}

const Header = struct {
    type: MessageType,
    reply_serial: u32 = 0,
    error_name: []const u8 = "",
    signature: []const u8 = "",
    body_offset: usize,
};

/// The header fields glim reads: the reply serial, error name and body
/// signature. Every header field's value is one of o, s, g or u.
fn parseHeader(m: []const u8) !Header {
    const fields_len = std.mem.readInt(u32, m[12..16], .little);
    var header: Header = .{
        .type = @enumFromInt(m[1]),
        .body_offset = std.mem.alignForward(usize, 16 + fields_len, 8),
    };
    const end = 16 + fields_len;
    if (end > m.len) return error.Truncated;
    var i: usize = 16;
    while (i < end) {
        i = std.mem.alignForward(usize, i, 8);
        if (i + 3 > end) return error.Truncated;
        const code: Field = @enumFromInt(m[i]);
        const sig_len = m[i + 1];
        if (sig_len != 1) return error.UnexpectedHeaderField;
        const type_code = m[i + 2];
        i += 4; // code, signature length, type, NUL
        switch (type_code) {
            's', 'o' => {
                i = std.mem.alignForward(usize, i, 4);
                if (i + 4 > end) return error.Truncated;
                const len = std.mem.readInt(u32, m[i..][0..4], .little);
                if (i + 4 + len + 1 > end) return error.Truncated;
                const value = m[i + 4 ..][0..len];
                if (code == .error_name) header.error_name = value;
                i += 4 + len + 1;
            },
            'g' => {
                if (i >= end) return error.Truncated;
                const len = m[i];
                if (i + 1 + len + 1 > end) return error.Truncated;
                if (code == .signature) header.signature = m[i + 1 ..][0..len];
                i += 1 + len + 1;
            },
            'u' => {
                i = std.mem.alignForward(usize, i, 4);
                if (i + 4 > end) return error.Truncated;
                const value = std.mem.readInt(u32, m[i..][0..4], .little);
                if (code == .reply_serial) header.reply_serial = value;
                i += 4;
            },
            else => return error.UnexpectedHeaderField,
        }
    }
    return header;
}

/// An error's message: its body's first argument, when that is a string.
fn firstString(body: []const u8, signature: []const u8) []const u8 {
    if (signature.len == 0 or signature[0] != 's' or body.len < 4) return "";
    const len = std.mem.readInt(u32, body[0..4], .little);
    if (4 + len > body.len) return "";
    return body[4..][0..len];
}

test "a method call is marshalled as the spec lays it out" {
    var buf: [1024]u8 = undefined;
    const msg = try marshalCall(&buf, 7, .{
        .destination = "org.gnome.SettingsDaemon.Power",
        .path = "/org/gnome/SettingsDaemon/Power",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .args = .{
            .signature = "ssv",
            .strings = &.{ "org.gnome.SettingsDaemon.Power.Keyboard", "Brightness" },
            .variant_int32 = 65,
        },
    });
    try std.testing.expectEqualSlices(u8, &.{ 'l', 1, 0, 1 }, msg[0..4]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, msg[8..12], .little));
    try std.testing.expectEqual(@as(?usize, msg.len), try messageLength(msg));

    const header = try parseHeader(msg);
    try std.testing.expectEqual(MessageType.method_call, header.type);
    try std.testing.expectEqualStrings("ssv", header.signature);
    try std.testing.expectEqual(@as(usize, 0), header.body_offset % 8);

    // Body: two strings, then a variant: signature "i", padding, 65.
    const body = msg[header.body_offset..];
    try std.testing.expectEqualStrings("org.gnome.SettingsDaemon.Power.Keyboard", firstString(body, "s"));
    const second = std.mem.alignForward(usize, 4 + 39 + 1, 4);
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, body[second..][0..4], .little));
    const variant = second + 4 + 10 + 1;
    try std.testing.expectEqualSlices(u8, &.{ 1, 'i', 0 }, body[variant..][0..3]);
    const value = std.mem.alignForward(usize, variant + 3, 4);
    try std.testing.expectEqual(@as(i32, 65), std.mem.readInt(i32, body[value..][0..4], .little));
    try std.testing.expectEqual(body.len, value + 4);
}

test "bus addresses: the first unix transport, by path or abstract name" {
    const path = try parseAddress("unix:path=/run/user/1000/bus");
    try std.testing.expectEqualStrings("/run/user/1000/bus", std.mem.sliceTo(&path.sockaddr.path, 0));

    const abstract = try parseAddress("tcp:host=x,port=1;unix:abstract=/tmp/dbus-X,guid=ab");
    try std.testing.expectEqual(@as(u8, 0), abstract.sockaddr.path[0]);
    try std.testing.expectEqualStrings("/tmp/dbus-X", std.mem.sliceTo(abstract.sockaddr.path[1..], 0));
    try std.testing.expectEqual(@as(posix.socklen_t, @offsetOf(posix.sockaddr.un, "path") + 1 + 11), abstract.len);

    try std.testing.expectError(error.NoUnixAddress, parseAddress("tcp:host=x,port=1"));
}

test "a real bus answers, and its errors are read back" {
    // Only against a private bus handed over as GLIM_TEST_BUS -- never the
    // session the tests happen to be run from. `./run test` and the Nix build
    // start one with dbus-run-session; without it this is skipped.
    const address = posix.getenv("GLIM_TEST_BUS") orelse return error.SkipZigTest;
    var bus: Connection = undefined;
    try bus.open(address);
    defer bus.close();

    // The bus driver's Features property is read-only: setting it is an error
    // with a message, which is the path `glim follow` must report.
    const reply = try bus.call(.{
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .args = .{ .signature = "ssv", .strings = &.{ "org.freedesktop.DBus", "Features" }, .variant_int32 = 1 },
    }, 5000);
    switch (reply) {
        .ok => return error.ExpectedAnError,
        .failed => |f| {
            try std.testing.expect(std.mem.startsWith(u8, f.name, "org.freedesktop.DBus.Error."));
            try std.testing.expect(f.message.len > 0);
        },
    }

    const ping = try bus.call(.{
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus.Peer",
        .member = "Ping",
    }, 5000);
    try std.testing.expect(ping == .ok);
}
