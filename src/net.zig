const std = @import("std");

pub fn clientIp(allocator: std.mem.Allocator, peer: std.Io.net.IpAddress, trusted: std.Io.net.IpAddress, forwarded: ?[]const u8) ![]const u8 {
    var address = peer;
    address.setPort(0);
    var proxy = trusted;
    proxy.setPort(0);
    if (std.meta.eql(address, proxy)) {
        if (forwarded) |ip| {
            if (std.Io.net.IpAddress.parse(ip, 0)) |_| {
                return allocator.dupe(u8, ip);
            } else |_| {}
        }
    }
    return std.fmt.allocPrint(allocator, "{f}", .{address});
}

test "direct clients cannot spoof rate-limit identity" {
    const result = try clientIp(std.testing.allocator, try .parse("192.0.2.7", 1234), try .parse("127.0.0.1", 0), "203.0.113.9");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("192.0.2.7:0", result);
}

test "trusted proxy may supply one IP, not a chain" {
    const peer: std.Io.net.IpAddress = try .parse("127.0.0.1", 1234);
    const result = try clientIp(std.testing.allocator, peer, peer, "203.0.113.9");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("203.0.113.9", result);
    const invalid = try clientIp(std.testing.allocator, peer, peer, "203.0.113.9, 192.0.2.1");
    defer std.testing.allocator.free(invalid);
    try std.testing.expectEqualStrings("127.0.0.1:0", invalid);
}
