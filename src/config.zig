const std = @import("std");

pub const Config = struct {
    port: u16,
    database_url: []const u8,
    telegram_bot_token: []const u8,
    telegram_user_id: []const u8,
    bot_secret: []const u8,

    pub fn load(environ_map: *std.process.Environ.Map, allocator: std.mem.Allocator) !Config {
        const port_str = environ_map.get("PORT") orelse "3000";
        const port = std.fmt.parseInt(u16, port_str, 10) catch 3000;

        const database_url = environ_map.get("DATABASE_URL") orelse {
            return error.MissingDatabaseUrl;
        };

        const telegram_bot_token = environ_map.get("TELEGRAM_BOT_TOKEN") orelse {
            return error.MissingTelegramBotToken;
        };

        const telegram_user_id = environ_map.get("TELEGRAM_USER_ID") orelse {
            return error.MissingTelegramUserId;
        };

        const bot_secret = environ_map.get("BOT_SECRET") orelse {
            return error.MissingBotSecret;
        };

        _ = allocator;

        return Config{
            .port = port,
            .database_url = database_url,
            .telegram_bot_token = telegram_bot_token,
            .telegram_user_id = telegram_user_id,
            .bot_secret = bot_secret,
        };
    }
};
