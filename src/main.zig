const std = @import("std");
const httpz = @import("httpz");
const config = @import("config.zig");
const db = @import("db.zig");
const markdown = @import("markdown.zig");
const ratelimit = @import("ratelimit.zig");
const matrix = @import("matrix.zig");

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
    router.get("/api/threads/:id/comments", getComments, .{});
    router.post("/api/threads/:id/comments", createComment, .{});
    router.post("/api/comments/:id/approve", approveComment, .{});
    router.post("/api/comments/:id/delete", deleteComment, .{});

    try resendUnnotified(&app);

    std.log.info("listening on http://localhost:{d}", .{cfg.port});

    try server.listen();
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
        app.matrix.sendNotification(c.thread_id, c.nickname, c.content, c.id) catch |err| {
            std.log.warn("failed to resend notification for {s}: {}", .{ c.id, err });
            continue;
        };

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

    app.matrix.sendNotification(thread_id, nickname, content, comment.id) catch |err| {
        std.log.warn("failed to send matrix notification: {}", .{err});
        return;
    };

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
