const std = @import("std");
const httpz = @import("httpz");
const config = @import("config.zig");
const db = @import("db.zig");
const markdown = @import("markdown.zig");
const ratelimit = @import("ratelimit.zig");
const matrix = @import("matrix.zig");
const nickgen = @import("nickgen.zig");

const App = struct {
    db: db.Db,
    read_limiter: ratelimit.RateLimiter,
    write_limiter: ratelimit.RateLimiter,
    matrix: matrix.Matrix,
    bot_secret: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const cfg = try config.Config.load(init.environ_map, allocator);

    var database = try db.Db.init(init.io, allocator, cfg.database_url);
    defer database.deinit();

    var app = App{
        .db = database,
        .read_limiter = ratelimit.RateLimiter.init(allocator, 60_000, 60),
        .write_limiter = ratelimit.RateLimiter.init(allocator, 60_000, 5),
        .matrix = matrix.Matrix.init(cfg.matrix_homeserver, cfg.matrix_bot_token, cfg.matrix_room_id, allocator, init.io),
        .bot_secret = cfg.bot_secret,
        .io = init.io,
        .allocator = allocator,
    };

    var server = try httpz.Server(*App).init(init.io, allocator, .{
        .address = .localhost(cfg.port),
    }, &app);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.options("*", corsPreflight, .{});
    router.get("/health", health, .{});
    router.get("/api/nickname", getRandomNickname, .{});
    router.get("/api/threads/:id/comments", getComments, .{});
    router.post("/api/threads/:id/comments", createComment, .{});
    router.post("/api/comments/:id/approve", approveComment, .{});
    router.post("/api/comments/:id/delete", deleteComment, .{});

    try resendUnnotified(&app);

    // Resume matrix sync from the last persisted batch to avoid reprocessing the whole history
    if (try app.db.getState(app.allocator, "matrix_since")) |since| {
        app.matrix.since = since;
        std.log.info("resumed matrix sync from since={s}", .{since});
    }

    // martix sync thread
    var sync_thread = try std.Thread.spawn(.{}, matrixSyncLoop, .{&app});
    defer sync_thread.join();

    std.log.info("listening on http://localhost:{d}", .{cfg.port});

    try server.listen();
}

fn matrixSyncLoop(app: *App) void {
    std.log.info("starting matrix sync loop", .{});

    while (true) {
        const response = app.matrix.sync() catch |err| {
            std.log.warn("matrix sync failed: {}", .{err});
            std.Thread.yield() catch {};
            continue;
        };

        if (response) |body| {
            defer app.allocator.free(body);
            processSyncResponse(app, body) catch |err| {
                std.log.warn("failed to process sync response: {}", .{err});
            };

            const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, body, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value == .object) {
                if (parsed.value.object.get("next_batch")) |next_batch| {
                    if (next_batch == .string) {
                        if (app.matrix.since) |old| {
                            app.allocator.free(old);
                        }
                        app.matrix.since = app.allocator.dupe(u8, next_batch.string) catch null;
                        app.db.setState("matrix_since", next_batch.string) catch |err| {
                            std.log.warn("failed to persist matrix_since: {}", .{err});
                        };
                    }
                }
            }
        }

        std.Thread.yield() catch {};
    }
}

fn processSyncResponse(app: *App, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, body, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;

    const rooms = switch (root) {
        .object => |obj| obj.get("rooms") orelse return,
        else => return,
    };

    const join = switch (rooms) {
        .object => |obj| obj.get("join") orelse return,
        else => return,
    };

    const room = switch (join) {
        .object => |obj| obj.get(app.matrix.room_id) orelse return,
        else => return,
    };

    const timeline = switch (room) {
        .object => |obj| obj.get("timeline") orelse return,
        else => return,
    };

    const events = switch (timeline) {
        .object => |obj| obj.get("events") orelse return,
        else => return,
    };

    switch (events) {
        .array => |arr| {
            for (arr.items) |event| {
                processEvent(app, event) catch |err| {
                    std.log.warn("failed to process event: {}", .{err});
                };
            }
        },
        else => return,
    }
}

fn processEvent(app: *App, event: std.json.Value) !void {
    const event_obj = switch (event) {
        .object => |obj| obj,
        else => return,
    };

    const event_type = switch (event_obj.get("type") orelse return) {
        .string => |s| s,
        else => return,
    };

    if (!std.mem.eql(u8, event_type, "m.room.message")) return;

    const sender = switch (event_obj.get("sender") orelse return) {
        .string => |s| s,
        else => return,
    };
    if (std.mem.eql(u8, sender, "@comments-bot:pierdol.ing")) return;

    const content = switch (event_obj.get("content") orelse return) {
        .object => |obj| obj,
        else => return,
    };

    const body = switch (content.get("body") orelse return) {
        .string => |s| s,
        else => return,
    };

    const reply_event_id: ?[]const u8 = blk: {
        const relates_to = switch (content.get("m.relates_to") orelse break :blk null) {
            .object => |o| o,
            else => break :blk null,
        };
        const in_reply_to = switch (relates_to.get("m.in_reply_to") orelse break :blk null) {
            .object => |o| o,
            else => break :blk null,
        };
        break :blk switch (in_reply_to.get("event_id") orelse break :blk null) {
            .string => |s| s,
            else => null,
        };
    };

    if (reply_event_id) |event_id| {
        // Strip the quoted "> " block that Element prepends to replies
        const reply_text = try stripReplyQuote(app.allocator, body);
        defer app.allocator.free(reply_text);
        const text = std.mem.trim(u8, reply_text, " \t");

        if (std.mem.eql(u8, text, "ok") or std.mem.eql(u8, text, "/ok") or std.mem.startsWith(u8, text, "ok ")) {
            const comment_id = try app.db.getCommentIdByEventId(app.allocator, event_id) orelse {
                std.log.warn("no comment found for event_id {s}", .{event_id});
                return;
            };
            defer app.allocator.free(comment_id);

            std.log.info("approving comment {s} via reply", .{comment_id});
            const approved = try app.db.approveComment(comment_id);
            if (!approved) {
                app.matrix.sendMessage("hmm, comment not found") catch {};
                return;
            }

            if (text.len > 2) {
                const answer = std.mem.trim(u8, text[3..], " \t");
                if (answer.len > 0) {
                    const comment = try app.db.getCommentById(app.allocator, comment_id);
                    if (comment) |c| {
                        defer freeComment(c, app.allocator);

                        if (try app.db.ownerReplyExists(c.id)) {
                            std.log.info("owner reply for comment {s} already exists, skipping", .{comment_id});
                            app.matrix.sendMessage("ok, comment approved (reply already posted)") catch {};
                            return;
                        }

                        const html = try markdown.render(app.allocator, answer);
                        defer app.allocator.free(html);
                        _ = try app.db.createOwnerReply(app.allocator, .{
                            .thread_id = c.thread_id,
                            .parent_id = c.id,
                            .content = answer,
                            .html = html,
                        });
                        std.log.info("posted owner reply to comment {s}", .{comment_id});
                    }
                    app.matrix.sendMessage("ok, comment approved + your reply posted") catch {};
                    return;
                }
            }
            app.matrix.sendMessage("ok, comment approved") catch {};
        } else if (std.mem.eql(u8, text, "no") or std.mem.eql(u8, text, "/no") or std.mem.eql(u8, text, "no ")) {
            const comment_id = try app.db.getCommentIdByEventId(app.allocator, event_id) orelse {
                std.log.warn("no comment found for event_id {s}", .{event_id});
                return;
            };
            defer app.allocator.free(comment_id);

            std.log.info("deleting comment {s} via reply", .{comment_id});
            const deleted = try app.db.deleteComment(comment_id);
            app.matrix.sendMessage(if (deleted) "ok, comment deleted" else "hmm, comment not found") catch {};
        } else {
            app.matrix.sendMessage("i heard u, but only \"ok [your answer]\" or \"no\" work as replies") catch {};
        }
        return;
    }

    if (std.mem.startsWith(u8, body, "ok ") or std.mem.eql(u8, body, "ok")) {
        const comment_id = if (body.len > 3) body[3..] else return;
        std.log.info("approving comment {s}", .{comment_id});
        _ = try app.db.approveComment(comment_id);
    } else if (std.mem.startsWith(u8, body, "no ") or std.mem.eql(u8, body, "no")) {
        const comment_id = if (body.len > 3) body[3..] else return;
        std.log.info("deleting comment {s}", .{comment_id});
        _ = try app.db.deleteComment(comment_id);
    }
}

fn stripReplyQuote(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var it = std.mem.splitScalar(u8, body, '\n');
    var in_reply = false;
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, ">")) continue;
        if (!in_reply) {
            if (trimmed.len == 0) continue;
            in_reply = true;
        }
        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
    }

    if (result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
        result.items.len -= 1;
    }
    return result.toOwnedSlice(allocator);
}

fn resendUnnotified(app: *App) !void {
    const comments = try app.db.getUnnotifiedComments(app.allocator);
    defer {
        for (comments) |c| freeComment(c, app.allocator);
        app.allocator.free(comments);
    }

    if (comments.len == 0) return;

    std.log.info("resending {d} unnotified comments", .{comments.len});

    for (comments) |c| {
        const event_id = app.matrix.sendNotification(c.thread_id, c.nickname, c.site, c.content, c.id, c.created_at) catch |err| {
            std.log.warn("failed to resend notification for {s}: {}", .{ c.id, err });
            continue;
        };
        defer app.allocator.free(event_id);

        if (event_id.len > 0) {
            _ = try app.db.setEventId(c.id, event_id);
        }

        _ = try app.db.markAsNotified(c.id);
        std.log.info("resent notification for {s}", .{c.id});
    }
}

fn freeComment(comment: db.Comment, allocator: std.mem.Allocator) void {
    allocator.free(comment.id);
    allocator.free(comment.thread_id);
    if (comment.parent_id) |pid| allocator.free(pid);
    allocator.free(comment.nickname);
    if (comment.site) |s| allocator.free(s);
    allocator.free(comment.content);
    allocator.free(comment.html);
    allocator.free(comment.status);
}

fn corsPreflight(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    addCorsHeaders(res, req);
    res.status = 204;
}

fn addCorsHeaders(res: *httpz.Response, req: *httpz.Request) void {
    const origin = req.header("origin") orelse return;
    _ = origin;
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Content-Type, X-Bot-Token");
    res.header("Access-Control-Max-Age", "86400");
}

fn health(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    addCorsHeaders(res, req);
    try res.json(.{ .status = "ok" }, .{});
}

fn getRandomNickname(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    addCorsHeaders(res, req);
    var seed_bytes: [@sizeOf(u64)]u8 = undefined;
    _ = std.os.linux.getrandom(&seed_bytes, seed_bytes.len, 0);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed_bytes, .little));
    const nick = try nickgen.generate(res.arena, prng.random());
    try res.json(.{ .nickname = nick }, .{});
}

fn getComments(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    addCorsHeaders(res, req);
    const ip = getClientIp(req);
    if (!app.read_limiter.check(ip)) {
        res.status = 429;
        try res.json(.{ .@"error" = "rate limit exceeded" }, .{});
        return;
    }

    const thread_id = req.param("id") orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "missing thread id" }, .{});
        return;
    };

    const qs = try req.query();
    var since: ?i64 = null;
    if (qs.get("since")) |since_str| {
        since = std.fmt.parseInt(i64, since_str, 10) catch null;
    }

    const comments = try app.db.getComments(res.arena, thread_id, since);

    const CommentJson = struct {
        id: []const u8,
        thread_id: []const u8,
        parent_id: ?[]const u8,
        nickname: []const u8,
        site: ?[]const u8,
        content: []const u8,
        html: []const u8,
        status: []const u8,
        created_at: i64,
    };

    var json_comments = std.ArrayList(CommentJson).empty;
    for (comments) |c| {
        try json_comments.append(res.arena, .{
            .id = c.id,
            .thread_id = c.thread_id,
            .parent_id = c.parent_id,
            .nickname = c.nickname,
            .site = c.site,
            .content = c.content,
            .html = c.html,
            .status = c.status,
            .created_at = c.created_at,
        });
    }

    try res.json(.{ .comments = json_comments.items }, .{});
}

const CreateCommentBody = struct {
    nickname: ?[]const u8 = null,
    site: ?[]const u8 = null,
    content: ?[]const u8 = null,
    honeypot: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
};

fn createComment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    addCorsHeaders(res, req);
    const ip = getClientIp(req);
    if (!app.write_limiter.check(ip)) {
        res.status = 429;
        try res.json(.{ .@"error" = "rate limit exceeded" }, .{});
        return;
    }

    const body = try req.json(CreateCommentBody) orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "invalid json body" }, .{});
        return;
    };

    if (body.honeypot) |hp| {
        if (hp.len > 0) {
            res.status = 200;
            try res.json(.{ .status = "ok" }, .{});
            return;
        }
    }

    const nickname = body.nickname orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "nickname is required" }, .{});
        return;
    };
    if (nickname.len == 0 or nickname.len > 32) {
        res.status = 400;
        try res.json(.{ .@"error" = "nickname must be 1-32 characters" }, .{});
        return;
    }

    const content = body.content orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "content is required" }, .{});
        return;
    };
    if (content.len == 0 or content.len > 2000) {
        res.status = 400;
        try res.json(.{ .@"error" = "content must be 1-2000 characters" }, .{});
        return;
    }

    const thread_id = req.param("id") orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "missing thread id" }, .{});
        return;
    };

    const html = try markdown.render(res.arena, content);

    const comment = try app.db.createComment(res.arena, .{
        .thread_id = thread_id,
        .parent_id = body.parent_id,
        .nickname = nickname,
        .site = body.site,
        .content = content,
        .html = html,
        .honeypot = body.honeypot,
    });

    const event_id = app.matrix.sendNotification(thread_id, nickname, body.site, content, comment.id, comment.created_at) catch |err| {
        std.log.warn("failed to send matrix notification: {}", .{err});
        return;
    };
    defer app.allocator.free(event_id);

    if (event_id.len > 0) {
        _ = try app.db.setEventId(comment.id, event_id);
    }

    _ = try app.db.markAsNotified(comment.id);

    try res.json(.{ .id = comment.id, .status = comment.status }, .{});
}

fn approveComment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    addCorsHeaders(res, req);
    const token = req.header("x-bot-token") orelse {
        res.status = 401;
        try res.json(.{ .@"error" = "unauthorized" }, .{});
        return;
    };
    if (!std.mem.eql(u8, token, app.bot_secret)) {
        res.status = 401;
        try res.json(.{ .@"error" = "unauthorized" }, .{});
        return;
    }

    const comment_id = req.param("id") orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "missing comment id" }, .{});
        return;
    };

    const updated = try app.db.approveComment(comment_id);
    if (!updated) {
        res.status = 404;
        try res.json(.{ .@"error" = "comment not found" }, .{});
        return;
    }

    try res.json(.{ .status = "approved" }, .{});
}

fn deleteComment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    addCorsHeaders(res, req);
    const token = req.header("x-bot-token") orelse {
        res.status = 401;
        try res.json(.{ .@"error" = "unauthorized" }, .{});
        return;
    };
    if (!std.mem.eql(u8, token, app.bot_secret)) {
        res.status = 401;
        try res.json(.{ .@"error" = "unauthorized" }, .{});
        return;
    }

    const comment_id = req.param("id") orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "missing comment id" }, .{});
        return;
    };

    const deleted = try app.db.deleteComment(comment_id);
    if (!deleted) {
        res.status = 404;
        try res.json(.{ .@"error" = "comment not found" }, .{});
        return;
    }

    try res.json(.{ .status = "deleted" }, .{});
}

fn getClientIp(req: *httpz.Request) []const u8 {
    if (req.header("x-forwarded-for")) |xff| {
        if (std.mem.indexOf(u8, xff, ",")) |comma_idx| {
            return std.mem.trim(u8, xff[0..comma_idx], " ");
        }
        return xff;
    }
    return "unknown";
}
