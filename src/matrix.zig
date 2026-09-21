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

        const url = try std.fmt.allocPrint(self.allocator,
            "{s}/_matrix/client/v3/rooms/{s}/send/m.room.message",
            .{ self.homeserver, self.room_id });
        defer self.allocator.free(url);

        const json_body = try buildJsonBody(self.allocator, body);
        defer self.allocator.free(json_body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
        defer self.allocator.free(auth_header);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
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
        "\u{1F4AC} New comment on {s}\n\n@{s}:\n> {s}\n\nReply with /approve {s} or /delete {s}",
        .{ thread_id, nickname, content, comment_id, comment_id });
}

fn buildJsonBody(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"msgtype\":\"m.text\",\"body\":\"{s}\"}}",
        .{body});
}
