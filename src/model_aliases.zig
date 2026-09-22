//! Model aliases (`~/.mlx-serve/model-aliases.json`): short request ids that
//! resolve to a registered model, and ride its `/v1/models` row as `aliases`.
//! The file maps an alias to a model ID or to a model's absolute path:
//!
//! ```json
//! {
//!   "Qwen3.8-Flash-Next": "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
//!   "qwen-small": "/Users/me/.mlx-serve/models/mlx-community/Qwen2.5-0.5B-Instruct-4bit"
//! }
//! ```
//!
//! A registered id always beats an alias, so an alias can never shadow a real
//! model; a target that isn't registered is dangling (logged at boot, resolves
//! to nothing) and becomes live as soon as the model appears on disk. The user
//! edits the file; the server owns applying it — same division as
//! `model_settings.zig`. Missing or malformed = empty, logged: a typo in an
//! alias must never stop the server.

const std = @import("std");
const log = @import("log.zig");

/// A usable alias name: what a client can put in a `model` field without
/// quoting games. Letters, digits, and `-_./:` only — no whitespace, quotes or
/// control bytes (so the `/v1/models` fragment needs no escaping), and no `@`
/// (that is `lan`'s `<id>@<peer>` syntax). `mlx-serve` is the built-in default
/// -model alias and stays reserved.
pub fn nameOk(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, "mlx-serve")) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '/', ':' => {},
        else => return false,
    };
    return true;
}

fn trimSlash(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

pub const Table = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *Table) void {
        if (self.parsed) |*p| p.deinit();
        self.parsed = null;
    }

    pub fn count(self: *const Table) usize {
        const p = self.parsed orelse return 0;
        return switch (p.value) {
            .object => |o| o.count(),
            else => 0,
        };
    }

    /// What `alias` points at (a model id or an absolute path), or null when
    /// the key isn't a usable alias or isn't in the file.
    pub fn targetFor(self: *const Table, alias: []const u8) ?[]const u8 {
        if (!nameOk(alias)) return null;
        const p = self.parsed orelse return null;
        const root = switch (p.value) {
            .object => |o| o,
            else => return null,
        };
        const v = root.get(alias) orelse return null;
        return switch (v) {
            .string => |s| if (s.len > 0) s else null,
            else => null,
        };
    }

    /// `,"aliases":["a","b"]` for one model's `/v1/models` row, `""` when it has
    /// none. Targets match by id OR by path (both slash-insensitive), so a row
    /// advertises exactly the names that would resolve to it; sorted so the
    /// listing is stable across boots.
    pub fn aliasesJson(self: *const Table, allocator: std.mem.Allocator, id: []const u8, path: []const u8) ![]const u8 {
        const p = self.parsed orelse return "";
        const root = switch (p.value) {
            .object => |o| o,
            else => return "",
        };
        const want_id = trimSlash(id);
        const want_path = trimSlash(path);
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        var it = root.iterator();
        while (it.next()) |kv| {
            const t = self.targetFor(kv.key_ptr.*) orelse continue;
            const tgt = trimSlash(t);
            if (!std.mem.eql(u8, tgt, want_id) and !std.mem.eql(u8, tgt, want_path)) continue;
            try names.append(allocator, kv.key_ptr.*);
        }
        if (names.items.len == 0) return "";
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, ",\"aliases\":[");
        for (names.items, 0..) |n, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, n);
            try buf.append(allocator, '"');
        }
        try buf.append(allocator, ']');
        return buf.toOwnedSlice(allocator);
    }
};

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Table {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{}) };
}

/// Missing file = empty. Unreadable or malformed = empty, logged.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Table {
    const body = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| {
        if (err != error.FileNotFound) log.warn("[aliases] {s}: unreadable ({s}), ignored\n", .{ path, @errorName(err) });
        return .{};
    };
    defer allocator.free(body);
    var t = parse(allocator, body) catch |err| {
        log.warn("[aliases] {s}: malformed ({s}), ignored\n", .{ path, @errorName(err) });
        return .{};
    };
    if (t.count() > 0) log.info("[aliases] {d} model alias(es) from {s}\n", .{ t.count(), path });
    return t;
}

pub fn defaultPath(buf: []u8) []const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
    return std.fmt.bufPrint(buf, "{s}/.mlx-serve/model-aliases.json", .{home}) catch "";
}

test "model_aliases: alias to an id and to a path; reserved and bad names refused" {
    var t = try parse(std.testing.allocator,
        \\{ "Qwen3.8-Flash-Next": "ddalcu/Qwen3.8-mixed-4-8bit",
        \\  "qwen-small": "/models/mlx-community/Qwen2.5-0.5B",
        \\  "mlx-serve": "ddalcu/Qwen3.8-mixed-4-8bit",
        \\  "two words": "ddalcu/Qwen3.8-mixed-4-8bit",
        \\  "peer@host": "ddalcu/Qwen3.8-mixed-4-8bit",
        \\  "broken": 42 }
    );
    defer t.deinit();
    try std.testing.expectEqualStrings("ddalcu/Qwen3.8-mixed-4-8bit", t.targetFor("Qwen3.8-Flash-Next").?);
    try std.testing.expectEqualStrings("/models/mlx-community/Qwen2.5-0.5B", t.targetFor("qwen-small").?);
    try std.testing.expect(t.targetFor("nope") == null);
    try std.testing.expect(t.targetFor("mlx-serve") == null);
    try std.testing.expect(t.targetFor("two words") == null);
    try std.testing.expect(t.targetFor("peer@host") == null);
    try std.testing.expect(t.targetFor("broken") == null);
}

test "model_aliases: listing fragment names every alias of a model, by id or path" {
    var t = try parse(std.testing.allocator,
        \\{ "zed": "ddalcu/m", "abel": "/models/m/", "other": "org/elsewhere" }
    );
    defer t.deinit();
    const a = try t.aliasesJson(std.testing.allocator, "ddalcu/m", "/models/m");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings(",\"aliases\":[\"abel\",\"zed\"]", a);
    // A path target matches the row whose PATH it is, whatever that row's id is.
    const b = try t.aliasesJson(std.testing.allocator, "whatever-id", "/models/m/");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(",\"aliases\":[\"abel\"]", b);
    const c = try t.aliasesJson(std.testing.allocator, "org/elsewhere", "/models/elsewhere");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings(",\"aliases\":[\"other\"]", c);
    try std.testing.expectEqualStrings("", try t.aliasesJson(std.testing.allocator, "unrelated", "/models/x"));
}

test "model_aliases: malformed or missing file is empty, never an error" {
    var t = load(std.testing.allocator, std.testing.io, "/nonexistent/model-aliases.json");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 0), t.count());
    try std.testing.expect(t.targetFor("qwen") == null);
    try std.testing.expectError(error.SyntaxError, parse(std.testing.allocator, "{nope"));
}
