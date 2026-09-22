const std = @import("std");

var confirm_counter: u64 = 0;

pub const Matrix = struct {
    homeserver: []const u8,
    access_token: []const u8,
    room_id: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    since: ?[]const u8 = null,

    pub fn init(homeserver: []const u8, access_token: []const u8, room_id: []const u8, allocator: std.mem.Allocator, io: std.Io) Matrix {
        return .{
            .homeserver = homeserver,
            .access_token = access_token,
            .room_id = room_id,
            .allocator = allocator,
            .io = io,
        };
    }
    pub fn sendNotification(self: *Matrix, thread_id: []const u8, nickname: []const u8, site: ?[]const u8, content: []const u8, comment_id: []const u8, created_at: i64) ![]const u8 {
        const body = try formatMessage(self.allocator, thread_id, nickname, site, content, comment_id, created_at);
        defer self.allocator.free(body);

        // Use comment_id as transaction ID to ensure uniqueness
        const url = try std.fmt.allocPrint(self.allocator, "{s}/_matrix/client/v3/rooms/{s}/send/m.room.message/{s}", .{ self.homeserver, self.room_id, comment_id });
        defer self.allocator.free(url);

        const json_body = try buildJsonBody(self.allocator, body);
        defer self.allocator.free(json_body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
        defer self.allocator.free(auth_header);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var response_buffer: [1024 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&response_buffer);

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = json_body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .response_writer = &writer,
        });

        if (@intFromEnum(result.status) >= 400) {
            return error.MatrixApiError;
        }

        const response = writer.buffered();

        // JSON parsing for event_id
        if (std.mem.indexOf(u8, response, "\"event_id\":\"")) |start| {
            const event_start = start + 12;
            if (std.mem.indexOfPos(u8, response, event_start, "\"")) |end| {
                const event_id = response[event_start..end];
                return self.allocator.dupe(u8, event_id) catch return "";
            }
        }

        return "";
    }
    pub fn sendMessage(self: *Matrix, text: []const u8) !void {
        const mono = @atomicRmw(u64, &confirm_counter, .Add, 1, .monotonic);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/_matrix/client/v3/rooms/{s}/send/m.room.message/confirm-{d}", .{ self.homeserver, self.room_id, mono });
        defer self.allocator.free(url);

        const json_body = try buildJsonBody(self.allocator, text);
        defer self.allocator.free(json_body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
        defer self.allocator.free(auth_header);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var response_buffer: [1024 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&response_buffer);

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = json_body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .response_writer = &writer,
        });

        if (@intFromEnum(result.status) >= 400) {
            return error.MatrixApiError;
        }
    }

    pub fn sync(self: *Matrix) !?[]const u8 {
        const url = if (self.since) |since|
            try std.fmt.allocPrint(self.allocator, "{s}/_matrix/client/v3/sync?since={s}&timeout=30000", .{ self.homeserver, since })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/_matrix/client/v3/sync?timeout=30000", .{self.homeserver});
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
        defer self.allocator.free(auth_header);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var response_buffer: [1024 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&response_buffer);

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
            },
            .response_writer = &writer,
        });

        if (@intFromEnum(result.status) >= 400) {
            return error.MatrixSyncError;
        }

        return self.allocator.dupe(u8, writer.buffered()) catch return null;
    }
};

pub fn formatMessage(allocator: std.mem.Allocator, thread_id: []const u8, nickname: []const u8, site: ?[]const u8, content: []const u8, _: []const u8, created_at: i64) ![]const u8 {
    const date_str = try formatDate(allocator, created_at);
    defer allocator.free(date_str);

    const site_str = site orelse "";
    const separator = if (site != null and site.?.len > 0) ", " else "";

    return std.fmt.allocPrint(allocator, "new comment on {s}:\n---\n{s}\n---\n{s}{s}{s}\n{s}", .{ thread_id, content, nickname, separator, site_str, date_str });
}

fn formatDate(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const secs: u64 = @intCast(@divFloor(timestamp, 1_000_000));
    const e = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = e.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const seconds_into_day = e.getDaySeconds();
    const hour = seconds_into_day.getHoursIntoDay();
    const minute = seconds_into_day.getMinutesIntoHour();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        hour,
        minute,
    });
}

fn buildJsonBody(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8).empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"msgtype\":\"m.text\",\"body\":\"");

    for (body) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const escaped = try std.fmt.allocPrint(allocator, "\\u{:0>4}", .{c});
                    defer allocator.free(escaped);
                    try result.appendSlice(allocator, escaped);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    try result.appendSlice(allocator, "\"}");

    return result.toOwnedSlice(allocator);
}
