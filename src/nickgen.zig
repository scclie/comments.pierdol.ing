const std = @import("std");

const adjectives = [_][]const u8{
    "null",   "void",    "shadow",  "cyber",   "glitch",
    "silent", "dark",    "neon",    "quantum", "binary",
    "pixel",  "ghost",   "chaos",   "crypt",   "zero",
    "phantom","static",  "broken",  "wild",    "frozen",
};

const nouns = [_][]const u8{
    "puppy",   "kitten",  "wolf",    "fox",     "cat",
    "dragon",  "ninja",   "samurai", "wizard",  "ghost",
    "byte",    "bit",     "node",    "root",    "daemon",
    "spectre", "raven",   "lynx",    "serpent", "phoenix",
};

const symbols = [_][]const u8{
    "0x", "_", ".", "-", "@", "#", "$",
};

const numbers = [_][]const u8{
    "42", "13", "7", "666", "404", "1337", "9000", "420", "69", "0",
};

fn pick(rng: std.Random, words: []const []const u8) []const u8 {
    return words[rng.int(usize) % words.len];
}

pub fn generate(allocator: std.mem.Allocator, rng: std.Random) ![]const u8 {
    const adj = pick(rng, &adjectives);
    const noun = pick(rng, &nouns);
    const noun2 = pick(rng, &nouns);
    const sym = pick(rng, &symbols);
    const num = pick(rng, &numbers);

    return switch (rng.int(usize) % 5) {
        0 => std.fmt.allocPrint(allocator, "{s}_{s}", .{ adj, noun }),
        1 => std.fmt.allocPrint(allocator, "{s}{s}_{s}", .{ sym, adj, noun }),
        2 => std.fmt.allocPrint(allocator, "{s}_{s}_{s}", .{ adj, noun, num }),
        3 => std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ noun, sym, noun2 }),
        4 => std.fmt.allocPrint(allocator, "{s}{s}_{s}", .{ sym, noun, num }),
        else => unreachable,
    };
}

test "generate produces non-empty nickname" {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    const nick = try generate(std.testing.allocator, rng);
    defer std.testing.allocator.free(nick);
    try std.testing.expect(nick.len > 0);
}

test "generate produces different nicknames with different seeds" {
    var prng1 = std.Random.DefaultPrng.init(1);
    var prng2 = std.Random.DefaultPrng.init(999);

    const nick1 = try generate(std.testing.allocator, prng1.random());
    defer std.testing.allocator.free(nick1);
    const nick2 = try generate(std.testing.allocator, prng2.random());
    defer std.testing.allocator.free(nick2);

    try std.testing.expect(!std.mem.eql(u8, nick1, nick2));
}

test "generate produces variety of formats" {
    const allocator = std.testing.allocator;
    var has_underscore_only = false;
    var has_prefix_symbol = false;
    var has_middle_symbol = false;
    var has_number_suffix = false;

    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const nick = try generate(allocator, rng);
        defer allocator.free(nick);

        const starts_with_symbol = std.mem.startsWith(u8, nick, "0x") or
            std.mem.startsWith(u8, nick, "@") or
            std.mem.startsWith(u8, nick, "#") or
            std.mem.startsWith(u8, nick, "$");

        if (starts_with_symbol) {
            has_prefix_symbol = true;
        }

        if (std.mem.indexOf(u8, nick, ".") != null or std.mem.indexOf(u8, nick, "-") != null) {
            has_middle_symbol = true;
        }

        if (!starts_with_symbol and std.mem.indexOf(u8, nick, "_") != null) {
            has_underscore_only = true;
            const last_underscore = std.mem.lastIndexOf(u8, nick, "_").?;
            const tail = nick[last_underscore + 1 ..];
            if (std.fmt.parseInt(u64, tail, 10) catch null) |_| {
                has_number_suffix = true;
            }
        }
    }

    try std.testing.expect(has_underscore_only);
    try std.testing.expect(has_prefix_symbol);
    try std.testing.expect(has_middle_symbol or has_number_suffix);
}

test "generate template 0 format adjective_noun" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const rng = prng.random();

    var found = false;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const nick = try generate(allocator, rng);
        defer allocator.free(nick);

        var count: usize = 0;
        var it = std.mem.splitScalar(u8, nick, '_');
        while (it.next() != null) : (count += 1) {}

        if (count == 2) {
            var it2 = std.mem.splitScalar(u8, nick, '_');
            const adj_part = it2.next().?;
            const noun_part = it2.next().?;

            var adj_found = false;
            for (adjectives) |a| {
                if (std.mem.eql(u8, a, adj_part)) {
                    adj_found = true;
                    break;
                }
            }
            var noun_found = false;
            for (nouns) |n| {
                if (std.mem.eql(u8, n, noun_part)) {
                    noun_found = true;
                    break;
                }
            }
            if (adj_found and noun_found) {
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
}
