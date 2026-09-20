const std = @import("std");

pub const Action = struct {
    action: []const u8,
    comment_id: []const u8,
};

pub const Telegram = struct {
    bot_token: []const u8,
    chat_id: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(bot_token: []const u8, chat_id: []const u8, allocator: std.mem.Allocator, io: std.Io) Telegram {
        return .{
            .bot_token = bot_token,
            .chat_id = chat_id,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn sendNotification(self: *Telegram, thread_id: []const u8, nickname: []const u8, content: []const u8, comment_id: []const u8) !void {
        const message = try formatMessage(self.allocator, thread_id, nickname, content, comment_id);
        defer self.allocator.free(message);

        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{self.bot_token});
        defer self.allocator.free(url);

        const body = try buildJsonBody(self.allocator, self.chat_id, message);
        defer self.allocator.free(body);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
        });

        if (@intFromEnum(result.status) >= 400) {
            return error.TelegramApiError;
        }
    }

    pub fn handleUpdate(self: *Telegram, update_json: []const u8) !?Action {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, update_json, .{});
        defer parsed.deinit();

        return parseUpdate(parsed.value, self.allocator);
    }
};

pub fn formatMessage(allocator: std.mem.Allocator, thread_id: []const u8, nickname: []const u8, content: []const u8, comment_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        "\u{1F4AC} New comment on {s}\n\n@{s}:\n> {s}\n\nReply to approve, /delete to remove\nComment ID: {s}",
        .{ thread_id, nickname, content, comment_id });
}

fn parseUpdate(root: std.json.Value, allocator: std.mem.Allocator) ?Action {
    const message = switch (root) {
        .object => |obj| obj.get("message") orelse return null,
        else => return null,
    };

    const text_val = switch (message) {
        .object => |obj| obj.get("text") orelse return null,
        else => return null,
    };

    const text: []const u8 = switch (text_val) {
        .string => |s| s,
        else => return null,
    };

    const reply_to = switch (message) {
        .object => |obj| obj.get("reply_to_message") orelse return null,
        else => return null,
    };

    const reply_msg_id = switch (reply_to) {
        .object => |obj| obj.get("message_id") orelse return null,
        else => return null,
    };

    const comment_id: []const u8 = switch (reply_msg_id) {
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch return null,
        .string => |s| allocator.dupe(u8, s) catch return null,
        else => return null,
    };

    const action_str: []const u8 = if (std.mem.eql(u8, text, "/delete")) "delete" else "approve";

    return .{
        .action = action_str,
        .comment_id = comment_id,
    };
}

fn buildJsonBody(allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"chat_id\":\"");
    try list.appendSlice(allocator, chat_id);
    try list.appendSlice(allocator, "\",\"text\":\"");
    try appendJsonEscaped(allocator, &list, text);
    try list.appendSlice(allocator, "\"}");

    return list.toOwnedSlice(allocator);
}

fn appendJsonEscaped(allocator: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try list.appendSlice(allocator, "\\u00");
                    try list.append(allocator, hex[c >> 4]);
                    try list.append(allocator, hex[c & 0x0f]);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
}

test "formatMessage produces correct format" {
    const allocator = std.testing.allocator;
    const msg = try formatMessage(allocator, "blog/post-1", "cyber_cat", "Great article!", "abc-123");
    defer allocator.free(msg);

    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "New comment on blog/post-1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "@cyber_cat:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "> Great article!"));
    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "Comment ID: abc-123"));
    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "/delete"));
}

test "formatMessage includes all parameters" {
    const allocator = std.testing.allocator;
    const msg = try formatMessage(allocator, "thread-42", "null_puppy", "Hello world", "id-999");
    defer allocator.free(msg);

    try std.testing.expectEqualStrings(
        "\u{1F4AC} New comment on thread-42\n\n@null_puppy:\n> Hello world\n\nReply to approve, /delete to remove\nComment ID: id-999",
        msg,
    );
}

test "parseUpdate returns delete action for /delete command" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"update_id":123,"message":{"message_id":456,"text":"/delete","reply_to_message":{"message_id":789}}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const action = parseUpdate(parsed.value, allocator);
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("delete", action.?.action);
    try std.testing.expectEqualStrings("789", action.?.comment_id);
    allocator.free(action.?.comment_id);
}

test "parseUpdate returns approve action for other text" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"update_id":124,"message":{"message_id":457,"text":"looks good","reply_to_message":{"message_id":101}}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const action = parseUpdate(parsed.value, allocator);
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("approve", action.?.action);
    try std.testing.expectEqualStrings("101", action.?.comment_id);
    allocator.free(action.?.comment_id);
}

test "parseUpdate returns null when no message" {
    const allocator = std.testing.allocator;
    const json_str = \\{"update_id":125}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const action = parseUpdate(parsed.value, allocator);
    try std.testing.expect(action == null);
}

test "parseUpdate returns null when no reply_to_message" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"update_id":126,"message":{"message_id":458,"text":"hello"}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const action = parseUpdate(parsed.value, allocator);
    try std.testing.expect(action == null);
}

test "parseUpdate returns null when no text" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"update_id":127,"message":{"message_id":459,"reply_to_message":{"message_id":202}}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const action = parseUpdate(parsed.value, allocator);
    try std.testing.expect(action == null);
}

test "parseUpdate handles string message_id" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"update_id":128,"message":{"message_id":460,"text":"/delete","reply_to_message":{"message_id":"uuid-abc"}}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const action = parseUpdate(parsed.value, allocator);
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("delete", action.?.action);
    try std.testing.expectEqualStrings("uuid-abc", action.?.comment_id);
    allocator.free(action.?.comment_id);
}

test "buildJsonBody escapes special characters" {
    const allocator = std.testing.allocator;
    const body = try buildJsonBody(allocator, "12345", "line1\nline2\t\"quoted\"");
    defer allocator.free(body);

    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\\t"));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\\\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"chat_id\":\"12345\""));
}

test "buildJsonBody produces valid json structure" {
    const allocator = std.testing.allocator;
    const body = try buildJsonBody(allocator, "999", "hello world");
    defer allocator.free(body);

    try std.testing.expectEqualStrings("{\"chat_id\":\"999\",\"text\":\"hello world\"}", body);
}
