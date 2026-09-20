const std = @import("std");
const linux = std.os.linux;

fn getTimestampMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn sleepMs(ms: u64) void {
    var req: linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = false }, &req, null);
}

pub const RateLimiter = struct {
    const Entry = struct {
        timestamps: std.ArrayList(i64),
    };

    allocator: std.mem.Allocator,
    window_ms: u64,
    max_requests: usize,
    entries: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator, window_ms: u64, max_requests: usize) RateLimiter {
        return .{
            .allocator = allocator,
            .window_ms = window_ms,
            .max_requests = max_requests,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.timestamps.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn check(self: *RateLimiter, key: []const u8) bool {
        const now = getTimestampMs();
        const window_start = now - @as(i64, @intCast(self.window_ms));

        const result = self.entries.getOrPut(key) catch return false;

        if (!result.found_existing) {
            result.value_ptr.* = .{
                .timestamps = std.ArrayList(i64).empty,
            };
        }

        var entry = result.value_ptr;
        var valid_count: usize = 0;
        var write_idx: usize = 0;

        for (entry.timestamps.items) |ts| {
            if (ts > window_start) {
                entry.timestamps.items[write_idx] = ts;
                write_idx += 1;
                valid_count += 1;
            }
        }
        entry.timestamps.items.len = write_idx;

        if (valid_count >= self.max_requests) {
            return false;
        }

        entry.timestamps.append(self.allocator, now) catch return false;
        return true;
    }

    pub fn cleanup(self: *RateLimiter) void {
        const now = getTimestampMs();
        const window_start = now - @as(i64, @intCast(self.window_ms));

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            var write_idx: usize = 0;
            for (entry.value_ptr.timestamps.items) |ts| {
                if (ts > window_start) {
                    entry.value_ptr.timestamps.items[write_idx] = ts;
                    write_idx += 1;
                }
            }
            entry.value_ptr.timestamps.items.len = write_idx;

            if (entry.value_ptr.timestamps.items.len == 0) {
                entry.value_ptr.timestamps.deinit(self.allocator);
                _ = self.entries.remove(entry.key_ptr.*);
            }
        }
    }
};

test "basic rate limiting allows requests under limit" {
    var limiter = RateLimiter.init(std.testing.allocator, 60_000, 5);
    defer limiter.deinit();

    try std.testing.expect(limiter.check("127.0.0.1"));
    try std.testing.expect(limiter.check("127.0.0.1"));
    try std.testing.expect(limiter.check("127.0.0.1"));
}

test "rate limiting blocks requests over limit" {
    var limiter = RateLimiter.init(std.testing.allocator, 60_000, 3);
    defer limiter.deinit();

    try std.testing.expect(limiter.check("10.0.0.1"));
    try std.testing.expect(limiter.check("10.0.0.1"));
    try std.testing.expect(limiter.check("10.0.0.1"));
    try std.testing.expect(!limiter.check("10.0.0.1"));
}

test "different keys are independent" {
    var limiter = RateLimiter.init(std.testing.allocator, 60_000, 2);
    defer limiter.deinit();

    try std.testing.expect(limiter.check("ip-a"));
    try std.testing.expect(limiter.check("ip-a"));
    try std.testing.expect(!limiter.check("ip-a"));

    try std.testing.expect(limiter.check("ip-b"));
    try std.testing.expect(limiter.check("ip-b"));
    try std.testing.expect(!limiter.check("ip-b"));
}

test "cleanup removes expired entries" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, 1, 10);
    defer limiter.deinit();

    try std.testing.expect(limiter.check("old-key"));

    sleepMs(3);

    try std.testing.expect(limiter.check("new-key"));

    limiter.cleanup();

    try std.testing.expectEqual(@as(u32, 1), limiter.entries.count());
}

test "window expiry allows new requests" {
    var limiter = RateLimiter.init(std.testing.allocator, 1, 2);
    defer limiter.deinit();

    try std.testing.expect(limiter.check("user1"));
    try std.testing.expect(limiter.check("user1"));
    try std.testing.expect(!limiter.check("user1"));

    sleepMs(3);

    try std.testing.expect(limiter.check("user1"));
}
