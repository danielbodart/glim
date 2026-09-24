//! The Razer EC's control protocol, as much of it as glim uses: a 90-byte
//! feature report goes out, and one of the same shape comes back carrying the
//! EC's status and answer.
//!
//! Layout, from OpenRazer's `struct razer_report`:
//!
//!   0  status          4  protocol type     8..87  arguments
//!   1  transaction id  5  data size         88     CRC
//!   2  packets left    6  command class     89     reserved
//!   3  (hi byte of 2)  7  command id

const std = @import("std");

pub const report_len = 90;

/// OpenRazer sends every Blade's brightness commands with 0xFF. The Blade 16
/// (2023) answers 0x1F just the same, which is what rzrctrl uses, but 0xFF is
/// the one that has been tried across the whole family.
pub const transaction_id = 0xFF;

pub const Status = enum(u8) {
    new = 0,
    busy = 1,
    success = 2,
    failure = 3,
    timeout = 4,
    not_supported = 5,
    _,
};

pub const Command = struct {
    class: u8,
    id: u8,
    /// What the data size byte says. Not always the number of arguments
    /// filled in: the brightness query sends one and declares two, as
    /// OpenRazer does.
    size: u8,
};

/// Keyboard backlight brightness, 0..255, in the EC rather than the effect,
/// so whatever effect and colour are set survive it. Arguments: [0x01, level].
pub const set_brightness: Command = .{ .class = 0x0E, .id = 0x04, .size = 2 };
/// Answers [0x01, level].
pub const get_brightness: Command = .{ .class = 0x0E, .id = 0x84, .size = 2 };

pub fn request(command: Command, args: []const u8) [report_len]u8 {
    var report = [_]u8{0} ** report_len;
    report[1] = transaction_id;
    report[5] = command.size;
    report[6] = command.class;
    report[7] = command.id;
    @memcpy(report[8..][0..args.len], args);
    report[88] = crc(&report);
    return report;
}

/// XOR of bytes 2..87: everything after the status and transaction id, up to
/// the CRC itself.
pub fn crc(report: *const [report_len]u8) u8 {
    var sum: u8 = 0;
    for (report[2..88]) |byte| sum ^= byte;
    return sum;
}

pub fn status(response: *const [report_len]u8) Status {
    return @enumFromInt(response[0]);
}

/// Whether `response` is the EC's successful answer to `command` -- the EC
/// echoes the class and id back, so a stale answer to something else, or one
/// from an interface that does not speak the protocol, is told apart here.
pub fn answers(response: *const [report_len]u8, command: Command) bool {
    return status(response) == .success and
        response[6] == command.class and
        response[7] == command.id;
}

pub fn payload(response: *const [report_len]u8) []const u8 {
    return response[8..88];
}

pub const razer_vendor_id = 0x1532;

pub const Model = struct { product_id: u16, name: []const u8 };

/// Every laptop OpenRazer's `is_blade_laptop` lists, all of which it drives
/// with `set_brightness` above. Only the Blade 16 (2023) has been tried with
/// glim; the rest are here on OpenRazer's word.
pub const models = [_]Model{
    .{ .product_id = 0x0205, .name = "Blade Stealth" },
    .{ .product_id = 0x020F, .name = "Blade Stealth (QHD)" },
    .{ .product_id = 0x0210, .name = "Blade Pro (Late 2016)" },
    .{ .product_id = 0x0220, .name = "Blade Stealth (Late 2016)" },
    .{ .product_id = 0x0224, .name = "Blade (Late 2016)" },
    .{ .product_id = 0x0225, .name = "Blade Pro (2017)" },
    .{ .product_id = 0x022D, .name = "Blade Stealth (Mid 2017)" },
    .{ .product_id = 0x022F, .name = "Blade Pro FullHD (2017)" },
    .{ .product_id = 0x0232, .name = "Blade Stealth (Late 2017)" },
    .{ .product_id = 0x0233, .name = "Blade 15 (2018)" },
    .{ .product_id = 0x0234, .name = "Blade Pro (2019)" },
    .{ .product_id = 0x0239, .name = "Blade Stealth (2019)" },
    .{ .product_id = 0x023A, .name = "Blade 15 (2019) Advanced" },
    .{ .product_id = 0x023B, .name = "Blade 15 (2018) Base Model" },
    .{ .product_id = 0x0240, .name = "Blade 15 (2018) Mercury" },
    .{ .product_id = 0x0245, .name = "Blade 15 (Mid 2019) Mercury White" },
    .{ .product_id = 0x0246, .name = "Blade 15 (2019) Base Model" },
    .{ .product_id = 0x024A, .name = "Blade Stealth (Late 2019)" },
    .{ .product_id = 0x024B, .name = "Blade Advanced (Late 2019)" },
    .{ .product_id = 0x024C, .name = "Blade Pro (Late 2019)" },
    .{ .product_id = 0x024D, .name = "Blade 15 Studio Edition (2019)" },
    .{ .product_id = 0x0252, .name = "Blade Stealth (Early 2020)" },
    .{ .product_id = 0x0253, .name = "Blade 15 Advanced (2020)" },
    .{ .product_id = 0x0255, .name = "Blade 15 Base (Early 2020)" },
    .{ .product_id = 0x0256, .name = "Blade Pro (Early 2020)" },
    .{ .product_id = 0x0259, .name = "Blade Stealth (Late 2020)" },
    .{ .product_id = 0x0268, .name = "Blade 15 Base (Late 2020)" },
    .{ .product_id = 0x026A, .name = "Book 13 (2020)" },
    .{ .product_id = 0x026D, .name = "Blade 15 Advanced (Early 2021)" },
    .{ .product_id = 0x026E, .name = "Blade 17 Pro (Early 2021)" },
    .{ .product_id = 0x026F, .name = "Blade 15 Base (Early 2021)" },
    .{ .product_id = 0x0270, .name = "Blade 14 (2021)" },
    .{ .product_id = 0x0276, .name = "Blade 15 Advanced (Mid 2021)" },
    .{ .product_id = 0x0279, .name = "Blade 17 Pro (Mid 2021)" },
    .{ .product_id = 0x027A, .name = "Blade 15 Base (2022)" },
    .{ .product_id = 0x028A, .name = "Blade 15 Advanced (Early 2022)" },
    .{ .product_id = 0x028B, .name = "Blade 17 (2022)" },
    .{ .product_id = 0x028C, .name = "Blade 14 (2022)" },
    .{ .product_id = 0x029D, .name = "Blade 14 (2023)" },
    .{ .product_id = 0x029E, .name = "Blade 15 (2023)" },
    .{ .product_id = 0x029F, .name = "Blade 16 (2023)" },
    .{ .product_id = 0x02A0, .name = "Blade 18 (2023)" },
    .{ .product_id = 0x02B6, .name = "Blade 14 (2024)" },
    .{ .product_id = 0x02B8, .name = "Blade 18 (2024)" },
    .{ .product_id = 0x02C5, .name = "Blade 14 (2025)" },
    .{ .product_id = 0x02C6, .name = "Blade 16 (2025)" },
    .{ .product_id = 0x02C7, .name = "Blade 18 (2025)" },
};

pub fn model(product_id: u16) ?Model {
    for (models) |m| {
        if (m.product_id == product_id) return m;
    }
    return null;
}

test "a brightness request is laid out the way the EC reads it" {
    const report = request(set_brightness, &.{ 0x01, 165 });
    try std.testing.expectEqual(@as(u8, 0x00), report[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), report[1]);
    try std.testing.expectEqual(@as(u8, 2), report[5]);
    try std.testing.expectEqual(@as(u8, 0x0E), report[6]);
    try std.testing.expectEqual(@as(u8, 0x04), report[7]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 165, 0 }, report[8..11]);
    // 2 ^ 0x0E ^ 0x04 ^ 0x01 ^ 165: the transaction id is outside the sum.
    try std.testing.expectEqual(@as(u8, 2 ^ 0x0E ^ 0x04 ^ 0x01 ^ 165), report[88]);
}

test "the query declares two bytes and fills one" {
    const report = request(get_brightness, &.{0x01});
    try std.testing.expectEqual(@as(u8, 2), report[5]);
    try std.testing.expectEqual(@as(u8, 0x84), report[7]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0 }, report[8..10]);
}

test "only a successful echo of the same command is an answer" {
    var response = [_]u8{0} ** report_len;
    response[0] = @intFromEnum(Status.success);
    response[6] = 0x0E;
    response[7] = 0x84;
    response[9] = 165;
    try std.testing.expect(answers(&response, get_brightness));
    try std.testing.expectEqual(@as(u8, 165), payload(&response)[1]);
    try std.testing.expect(!answers(&response, set_brightness));

    response[0] = @intFromEnum(Status.busy);
    try std.testing.expect(!answers(&response, get_brightness));
}

test "models are found by product id" {
    try std.testing.expectEqualStrings("Blade 16 (2023)", model(0x029F).?.name);
    try std.testing.expect(model(0x0084) == null);
}
