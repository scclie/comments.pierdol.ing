const std = @import("std");

pub fn render(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        switch (input[i]) {
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#x27;"),
            '\n' => try buf.appendSlice(allocator, "<br>"),
            '*' => {
                if (i + 1 < input.len and input[i + 1] == '*') {
                    if (findClosing(input, i + 2, "**")) |close_idx| {
                        try buf.appendSlice(allocator, "<strong>");
                        const inner = input[i + 2 .. close_idx];
                        const escaped = try escapeText(allocator, inner);
                        defer allocator.free(escaped);
                        try buf.appendSlice(allocator, escaped);
                        try buf.appendSlice(allocator, "</strong>");
                        i = close_idx + 2;
                        continue;
                    }
                }
                if (findClosingSingle(input, i + 1, '*')) |close_idx| {
                    try buf.appendSlice(allocator, "<em>");
                    const inner = input[i + 1 .. close_idx];
                    const escaped = try escapeText(allocator, inner);
                    defer allocator.free(escaped);
                    try buf.appendSlice(allocator, escaped);
                    try buf.appendSlice(allocator, "</em>");
                    i = close_idx + 1;
                    continue;
                }
                try buf.append(allocator, '*');
            },
            '`' => {
                if (findClosingSingle(input, i + 1, '`')) |close_idx| {
                    try buf.appendSlice(allocator, "<code>");
                    const inner = input[i + 1 .. close_idx];
                    const escaped = try escapeText(allocator, inner);
                    defer allocator.free(escaped);
                    try buf.appendSlice(allocator, escaped);
                    try buf.appendSlice(allocator, "</code>");
                    i = close_idx + 1;
                    continue;
                }
                try buf.append(allocator, '`');
            },
            '[' => {
                if (parseLink(input, i)) |link| {
                    try buf.appendSlice(allocator, "<a href=\"");
                    const escaped_url = try escapeText(allocator, link.url);
                    defer allocator.free(escaped_url);
                    try buf.appendSlice(allocator, escaped_url);
                    try buf.appendSlice(allocator, "\">");
                    const escaped_text = try escapeText(allocator, link.text);
                    defer allocator.free(escaped_text);
                    try buf.appendSlice(allocator, escaped_text);
                    try buf.appendSlice(allocator, "</a>");
                    i = link.end;
                    continue;
                }
                try buf.append(allocator, '[');
            },
            else => try buf.append(allocator, input[i]),
        }
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

const Link = struct {
    text: []const u8,
    url: []const u8,
    end: usize,
};

fn parseLink(input: []const u8, start: usize) ?Link {
    var j = start + 1;
    while (j < input.len and input[j] != ']') : (j += 1) {}
    if (j >= input.len) return null;
    const text = input[start + 1 .. j];
    if (j + 1 >= input.len or input[j + 1] != '(') return null;
    var k = j + 2;
    while (k < input.len and input[k] != ')') : (k += 1) {}
    if (k >= input.len) return null;
    const url = input[j + 2 .. k];
    if (text.len == 0 or url.len == 0) return null;
    return .{ .text = text, .url = url, .end = k + 1 };
}

fn findClosing(input: []const u8, start: usize, delimiter: []const u8) ?usize {
    var i = start;
    while (i + delimiter.len <= input.len) : (i += 1) {
        if (std.mem.eql(u8, input[i .. i + delimiter.len], delimiter)) {
            if (i > start) return i;
        }
    }
    return null;
}

fn findClosingSingle(input: []const u8, start: usize, delimiter: u8) ?usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == delimiter) {
            if (i > start) return i;
        }
    }
    return null;
}

fn escapeText(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#x27;"),
            else => try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "plain text" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "html escaping" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "<script>alert('xss')</script>");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;", result);
}

test "bold" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "hello **world**");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello <strong>world</strong>", result);
}

test "italic" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "hello *world*");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello <em>world</em>", result);
}

test "code" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "use `std.ArrayList`");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("use <code>std.ArrayList</code>", result);
}

test "link" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "[click here](https://example.com)");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<a href=\"https://example.com\">click here</a>", result);
}

test "newlines" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "line1\nline2\nline3");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1<br>line2<br>line3", result);
}

test "mixed formatting" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "**bold** and *italic* and `code`");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<strong>bold</strong> and <em>italic</em> and <code>code</code>", result);
}

test "unclosed bold renders as literal" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "**unclosed");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("**unclosed", result);
}

test "code with html inside" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "`<div>`");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<code>&lt;div&gt;</code>", result);
}

test "link with html in url" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "[x](https://a.com?b=1&c=2)");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<a href=\"https://a.com?b=1&amp;c=2\">x</a>", result);
}

test "empty input" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}
