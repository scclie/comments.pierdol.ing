const std = @import("std");

pub const Config = struct {
    port: u16,
    database_url: []const u8,
    matrix_homeserver: []const u8,
    matrix_bot_token: []const u8,
    matrix_room_id: []const u8,
    bot_secret: []const u8,

    pub fn load(environ_map: *std.process.Environ.Map, allocator: std.mem.Allocator) !Config {
        const port_str = environ_map.get("PORT") orelse "3000";
        const port = std.fmt.parseInt(u16, port_str, 10) catch 3000;

        const database_url = environ_map.get("DATABASE_URL") orelse {
            return error.MissingDatabaseUrl;
        };

        const matrix_homeserver = environ_map.get("MATRIX_HOMESERVER") orelse {
            return error.MissingMatrixHomeserver;
        };

        const matrix_bot_token = environ_map.get("MATRIX_BOT_TOKEN") orelse {
            return error.MissingMatrixBotToken;
        };

        const matrix_room_id = environ_map.get("MATRIX_ROOM_ID") orelse {
            return error.MissingMatrixRoomId;
        };

        const bot_secret = environ_map.get("BOT_SECRET") orelse {
            return error.MissingBotSecret;
        };

        _ = allocator;

        return Config{
            .port = port,
            .database_url = database_url,
            .matrix_homeserver = matrix_homeserver,
            .matrix_bot_token = matrix_bot_token,
            .matrix_room_id = matrix_room_id,
            .bot_secret = bot_secret,
        };
    }
};
