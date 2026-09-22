const std = @import("std");

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

        var response_buffer = std.ArrayList(u8).empty;
        defer response_buffer.deinit(self.allocator);

        var writer = std.Io.Writer.fromArrayList(&response_buffer);

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

        const response = try response_buffer.toOwnedSlice(self.allocator);
        defer self.allocator.free(response);

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

        var response_buffer = std.ArrayList(u8).empty;
        defer response_buffer.deinit(self.allocator);

        var writer = std.Io.Writer.fromArrayList(&response_buffer);

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

        return try response_buffer.toOwnedSlice(self.allocator);
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
    // timestamp formatting
    return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
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
