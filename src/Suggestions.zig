//! The source of inline command suggestions.
//!
//! This holds the candidate commands we can suggest at a shell prompt: the
//! user's shell history plus any snippets they configured. It knows nothing
//! about the terminal; it just answers "given this prefix, what is the most
//! likely full command?".
const Suggestions = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("global.zig");
const internal_os = @import("os/main.zig");

const log = std.log.scoped(.suggestions);

/// How much of a history file we're willing to read. History files grow
/// without bound for some people and we only care about the recent tail.
const max_history_bytes: u64 = 4 * 1024 * 1024;

/// How many candidates we keep. Matching is a linear scan, so this bounds
/// both memory and the cost of every keystroke.
const max_entries: usize = 5000;

alloc: Allocator,

/// Candidate commands, most recent first, deduplicated.
entries: std.ArrayList([]const u8) = .empty,

/// User-configured snippets. Offered ahead of history because they were
/// written deliberately.
snippets: std.ArrayList([]const u8) = .empty,

pub fn init(alloc: Allocator) Suggestions {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Suggestions) void {
    for (self.entries.items) |e| self.alloc.free(e);
    self.entries.deinit(self.alloc);
    for (self.snippets.items) |e| self.alloc.free(e);
    self.snippets.deinit(self.alloc);
}

/// Replace the snippet list.
pub fn setSnippets(self: *Suggestions, list: []const []const u8) !void {
    for (self.snippets.items) |e| self.alloc.free(e);
    self.snippets.clearRetainingCapacity();
    for (list) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        try self.snippets.append(self.alloc, try self.alloc.dupe(u8, trimmed));
    }
}

/// Load history from the given files, newest entries first.
///
/// Files are read in order and later duplicates are dropped, so the first
/// file listed wins for any command that appears in several.
pub fn loadHistory(self: *Suggestions, paths: []const []const u8) !void {
    for (self.entries.items) |e| self.alloc.free(e);
    self.entries.clearRetainingCapacity();

    var seen: std.StringHashMap(void) = .init(self.alloc);
    defer seen.deinit();

    for (paths) |path| {
        const content = readFile(self.alloc, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                log.warn("could not read history path={s} err={}", .{ path, err });
                continue;
            },
        };
        defer self.alloc.free(content);

        try self.ingest(content, &seen);
        if (self.entries.items.len >= max_entries) break;
    }
}

/// Parse history file contents, appending newest entries first.
///
/// Three formats show up in practice and they're cheap to tell apart per
/// line, so we don't make the caller say which shell wrote the file.
fn ingest(
    self: *Suggestions,
    content: []const u8,
    seen: *std.StringHashMap(void),
) !void {
    // Walk backwards: the end of a history file is the most recent command,
    // and that's the order we want to match in.
    var it = std.mem.splitBackwardsScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        if (self.entries.items.len >= max_entries) return;

        const command = parseLine(raw_line) orelse continue;
        if (seen.contains(command)) continue;

        const owned = try self.alloc.dupe(u8, command);
        errdefer self.alloc.free(owned);
        try seen.put(owned, {});
        try self.entries.append(self.alloc, owned);
    }
}

/// Pull the command out of one history line, or null if there isn't one.
pub fn parseLine(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0) return null;

    // zsh extended history: ": <started>:<elapsed>;<command>"
    if (std.mem.startsWith(u8, line, ": ")) {
        if (std.mem.indexOfScalar(u8, line, ';')) |idx| {
            const command = std.mem.trim(u8, line[idx + 1 ..], " \t\r");
            return if (command.len == 0) null else command;
        }
    }

    // fish: "- cmd: <command>" inside a YAML-ish record.
    if (std.mem.startsWith(u8, line, "- cmd: ")) {
        const command = std.mem.trim(u8, line["- cmd: ".len..], " \t\r");
        return if (command.len == 0) null else command;
    }

    // fish continuation keys and comments are not commands.
    if (line[0] == '#' or
        std.mem.startsWith(u8, line, "when:") or
        std.mem.startsWith(u8, line, "paths:")) return null;

    // bash and plain zsh: the line is the command.
    return line;
}

/// Record a command the user just ran so it can be suggested immediately.
///
/// Shells only flush their history file on their own schedule — often not
/// until they exit — so waiting for the file would mean the command you just
/// typed is the one thing we can't suggest. Capturing it here also works for
/// a remote shell over ssh, because it comes from the prompt marks rather
/// than from any file on this machine.
pub fn remember(self: *Suggestions, command: []const u8) !void {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return;

    // Drop any older copy so the command moves to the front rather than
    // appearing twice.
    for (self.entries.items, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, trimmed)) {
            self.alloc.free(self.entries.orderedRemove(i));
            break;
        }
    }

    const owned = try self.alloc.dupe(u8, trimmed);
    errdefer self.alloc.free(owned);
    try self.entries.insert(self.alloc, 0, owned);

    if (self.entries.items.len > max_entries) {
        if (self.entries.pop()) |dropped| self.alloc.free(dropped);
    }
}

/// The best full command for `input`, or null when nothing fits.
///
/// Only a strict extension counts: an entry equal to what's already typed
/// would render as an empty suggestion, which just flickers.
pub fn match(self: *const Suggestions, input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;

    for (self.snippets.items) |candidate| {
        if (candidate.len > input.len and
            std.mem.startsWith(u8, candidate, input)) return candidate;
    }

    for (self.entries.items) |candidate| {
        if (candidate.len > input.len and
            std.mem.startsWith(u8, candidate, input)) return candidate;
    }

    return null;
}

/// The history files we read when the user hasn't named any.
///
/// Caller owns the returned slice and each path in it.
pub fn defaultHistoryPaths(alloc: Allocator) ![]const []const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = (try internal_os.home(global.io(), &environ_map, &buf)) orelse
        return &.{};

    const relative = [_][]const u8{
        ".zsh_history",
        ".bash_history",
        ".local/share/fish/fish_history",
    };

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }

    for (relative) |rel| {
        const path = try std.fs.path.join(alloc, &.{ home, rel });
        errdefer alloc.free(path);
        try list.append(alloc, path);
    }

    return try list.toOwnedSlice(alloc);
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(global.io(), path, .{});
    defer file.close(global.io());

    var reader = file.reader(global.io(), &.{});
    return try reader.interface.allocRemaining(
        alloc,
        .limited(max_history_bytes),
    );
}

test "parseLine handles zsh extended history" {
    const testing = std.testing;
    try testing.expectEqualStrings(
        "git status",
        Suggestions.parseLine(": 1700000000:0;git status").?,
    );
}

test "parseLine handles plain bash history" {
    const testing = std.testing;
    try testing.expectEqualStrings(
        "ls -la",
        Suggestions.parseLine("ls -la").?,
    );
}

test "parseLine handles fish history" {
    const testing = std.testing;
    try testing.expectEqualStrings(
        "cargo build",
        Suggestions.parseLine("- cmd: cargo build").?,
    );
    try testing.expect(Suggestions.parseLine("  when: 1700000000") == null);
}

test "parseLine ignores blanks" {
    const testing = std.testing;
    try testing.expect(Suggestions.parseLine("") == null);
    try testing.expect(Suggestions.parseLine("   ") == null);
}

test "match prefers the most recent history entry" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    var seen: std.StringHashMap(void) = .init(testing.allocator);
    defer seen.deinit();
    // Written oldest first, so "git status" is the most recent.
    try s.ingest("git commit\ngit status\n", &seen);

    try testing.expectEqualStrings("git status", s.match("git ").?);
}

test "match ignores an entry identical to the input" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    var seen: std.StringHashMap(void) = .init(testing.allocator);
    defer seen.deinit();
    try s.ingest("make\n", &seen);

    try testing.expect(s.match("make") == null);
}

test "match returns null for an empty prefix" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    var seen: std.StringHashMap(void) = .init(testing.allocator);
    defer seen.deinit();
    try s.ingest("anything\n", &seen);

    try testing.expect(s.match("") == null);
}

test "snippets win over history" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    var seen: std.StringHashMap(void) = .init(testing.allocator);
    defer seen.deinit();
    try s.ingest("deploy --from-history\n", &seen);
    try s.setSnippets(&.{"deploy --from-snippet"});

    try testing.expectEqualStrings("deploy --from-snippet", s.match("deploy ").?);
}

test "history is deduplicated keeping the newest" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    var seen: std.StringHashMap(void) = .init(testing.allocator);
    defer seen.deinit();
    try s.ingest("make test\nmake build\nmake test\n", &seen);

    try testing.expectEqual(@as(usize, 2), s.entries.items.len);
    try testing.expectEqualStrings("make test", s.entries.items[0]);
}

test "remember makes a command suggestable at once" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    try s.remember("cargo test --all-features");
    try testing.expectEqualStrings(
        "cargo test --all-features",
        s.match("cargo t").?,
    );
}

test "remember moves an existing command to the front" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    var seen: std.StringHashMap(void) = .init(testing.allocator);
    defer seen.deinit();
    try s.ingest("make build\nmake test\n", &seen);
    try testing.expectEqualStrings("make test", s.match("make ").?);

    try s.remember("make build");
    try testing.expectEqual(@as(usize, 2), s.entries.items.len);
    try testing.expectEqualStrings("make build", s.match("make ").?);
}

test "remember ignores blank input" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    try s.remember("   ");
    try s.remember("");
    try testing.expectEqual(@as(usize, 0), s.entries.items.len);
}

test "remember trims surrounding whitespace" {
    const testing = std.testing;
    var s: Suggestions = .init(testing.allocator);
    defer s.deinit();

    try s.remember("  git push  ");
    try testing.expectEqualStrings("git push", s.entries.items[0]);
}
