const std = @import("std");

pub const Matrix = struct {
    homeserver: []const u8,
    access_token: []const u8,
    room_id: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(homeserver: []const u8, access_token: []const u8, room_id: []const u8, allocator: std.mem.Allocator, io: std.Io) Matrix {
        return .{
            .homeserver = homeserver,
            .access_token = access_token,
            .room_id = room_id,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn sendNotification(self: *Matrix, thread_id: []const u8, nickname: []const u8, content: []const u8, comment_id: []const u8) !void {
        const body = try formatMessage(self.allocator, thread_id, nickname, content, comment_id);
        defer self.allocator.free(body);

        // Use comment_id as transaction ID to ensure uniqueness
        const url = try std.fmt.allocPrint(self.allocator,
            "{s}/_matrix/client/v3/rooms/{s}/send/m.room.message/{s}",
            .{ self.homeserver, self.room_id, comment_id });
        defer self.allocator.free(url);

        const json_body = try buildJsonBody(self.allocator, body);
        defer self.allocator.free(json_body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
        defer self.allocator.free(auth_header);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = json_body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
        });

        if (@intFromEnum(result.status) >= 400) {
            return error.MatrixApiError;
        }
    }
};

pub fn formatMessage(allocator: std.mem.Allocator, thread_id: []const u8, nickname: []const u8, content: []const u8, comment_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        "\u{1F4AC} New comment on {s}\n\n@{s}:\n> {s}\n\nReply /ok to approve or /no to delete\nComment ID: {s}",
        .{ thread_id, nickname, content, comment_id });
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
