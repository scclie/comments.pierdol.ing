const std = @import("std");
const pg = @import("pg");

pub const Comment = struct {
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

pub const CreateCommentParams = struct {
    thread_id: []const u8,
    parent_id: ?[]const u8,
    nickname: []const u8,
    site: ?[]const u8,
    content: []const u8,
    html: []const u8,
    honeypot: ?[]const u8,
};

pub const Db = struct {
    pool: *pg.Pool,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, database_url: []const u8) !Db {
        const uri = try std.Uri.parse(database_url);
        const pool = try pg.Pool.initUri(io, allocator, uri, .{ .size = 5 });
        return .{ .pool = pool };
    }

    pub fn deinit(self: *Db) void {
        self.pool.deinit();
    }

    pub fn createComment(self: *Db, allocator: std.mem.Allocator, params: CreateCommentParams) !Comment {
        var row = (try self.pool.rowOpts(
            \\INSERT INTO comments (thread_id, parent_id, nickname, site, content, html, honeypot)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7)
            \\RETURNING id, thread_id, parent_id, nickname, site, content, html, status, created_at
        ,
            .{
                params.thread_id,
                params.parent_id,
                params.nickname,
                params.site,
                params.content,
                params.html,
                params.honeypot,
            },
            .{ .column_names = true },
        )) orelse return error.NoResult;
        defer row.deinit() catch {};

        return rowToComment(allocator, row);
    }

    pub fn getComments(self: *Db, allocator: std.mem.Allocator, thread_id: []const u8, since: ?i64) ![]Comment {
        var comments = std.ArrayList(Comment).empty;
        errdefer {
            for (comments.items) |c| freeComment(c, allocator);
            comments.deinit(allocator);
        }

        if (since) |s| {
            var result = try self.pool.queryOpts(
                \\SELECT id, thread_id, parent_id, nickname, site, content, html, status, created_at
                \\FROM comments
                \\WHERE thread_id = $1 AND status = 'approved' AND created_at > $2
                \\ORDER BY created_at ASC
            ,
                .{ thread_id, s },
                .{ .column_names = true },
            );
            defer result.deinit();

            while (try result.next()) |row| {
                try comments.append(allocator, try rowToComment(allocator, row));
            }
        } else {
            var result = try self.pool.queryOpts(
                \\SELECT id, thread_id, parent_id, nickname, site, content, html, status, created_at
                \\FROM comments
                \\WHERE thread_id = $1 AND status = 'approved'
                \\ORDER BY created_at ASC
            ,
                .{thread_id},
                .{ .column_names = true },
            );
            defer result.deinit();

            while (try result.next()) |row| {
                try comments.append(allocator, try rowToComment(allocator, row));
            }
        }

        return comments.toOwnedSlice(allocator);
    }

    pub fn approveComment(self: *Db, id: []const u8) !bool {
        const affected = try self.pool.exec(
            "UPDATE comments SET status = 'approved' WHERE id = $1",
            .{id},
        );
        return (affected orelse 0) > 0;
    }

    pub fn deleteComment(self: *Db, id: []const u8) !bool {
        const affected = try self.pool.exec(
            "DELETE FROM comments WHERE id = $1",
            .{id},
        );
        return (affected orelse 0) > 0;
    }

    pub fn getUnnotifiedComments(self: *Db, allocator: std.mem.Allocator) ![]Comment {
        var comments = std.ArrayList(Comment).empty;
        errdefer {
            for (comments.items) |c| freeComment(c, allocator);
            comments.deinit(allocator);
        }

        var result = try self.pool.queryOpts(
            \\SELECT id, thread_id, parent_id, nickname, site, content, html, status, created_at
            \\FROM comments
            \\WHERE notified = false
            \\ORDER BY created_at ASC
        ,
            .{},
            .{ .column_names = true },
        );
        defer result.deinit();

        while (try result.next()) |row| {
            try comments.append(allocator, try rowToComment(allocator, row));
        }

        return comments.toOwnedSlice(allocator);
    }

    pub fn markAsNotified(self: *Db, id: []const u8) !bool {
        const affected = try self.pool.exec(
            "UPDATE comments SET notified = true WHERE id = $1",
            .{id},
        );
        return (affected orelse 0) > 0;
    }
};

fn rowToComment(allocator: std.mem.Allocator, row: anytype) !Comment {
    const id_bytes = try row.get([]const u8, 0);
    const id_hex = try pg.uuidToHex(id_bytes);
    const id = try allocator.dupe(u8, &id_hex);

    const thread_id = try allocator.dupe(u8, try row.get([]const u8, 1));

    const parent_id: ?[]const u8 = blk: {
        const pid_bytes = try row.get(?[]const u8, 2);
        if (pid_bytes) |b| {
            const hex = try pg.uuidToHex(b);
            break :blk try allocator.dupe(u8, &hex);
        }
        break :blk null;
    };

    const nickname = try allocator.dupe(u8, try row.get([]const u8, 3));

    const site: ?[]const u8 = blk: {
        const s = try row.get(?[]const u8, 4);
        if (s) |v| break :blk try allocator.dupe(u8, v);
        break :blk null;
    };

    const content = try allocator.dupe(u8, try row.get([]const u8, 5));
    const html = try allocator.dupe(u8, try row.get([]const u8, 6));
    const status = try allocator.dupe(u8, try row.get([]const u8, 7));
    const created_at = try row.get(i64, 8);

    return .{
        .id = id,
        .thread_id = thread_id,
        .parent_id = parent_id,
        .nickname = nickname,
        .site = site,
        .content = content,
        .html = html,
        .status = status,
        .created_at = created_at,
    };
}

fn freeComment(comment: Comment, allocator: std.mem.Allocator) void {
    allocator.free(comment.id);
    allocator.free(comment.thread_id);
    if (comment.parent_id) |pid| allocator.free(pid);
    allocator.free(comment.nickname);
    if (comment.site) |s| allocator.free(s);
    allocator.free(comment.content);
    allocator.free(comment.html);
    allocator.free(comment.status);
}
