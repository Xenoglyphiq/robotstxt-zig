//! robots.txt (RFC 9309), core layer: parse a robots.txt file, decide whether
//! a crawler may fetch a path and which rule decides, find the crawler's
//! Crawl-delay (an extension, not RFC 9309), and say what an HTTP status
//! means for the file.
//!
//! Implements the robotstxt spec (see `.spec/spec/SPEC.md`). Everything here
//! works on in-memory bytes; fetching the file is the io layer
//! (`robotstxt_io`, `src/io.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error kinds from the spec. `OutOfMemory` is Zig's own and never appears in
/// conformance fixtures. The spec's error code goes in `Diagnostics`. Every
/// error this library raises is `invalid_input`.
pub const Error = error{ InvalidInput, OutOfMemory };

/// Filled in when an operation fails, if the caller passes one.
pub const Diagnostics = struct {
    /// Stable spec error code, e.g. `"robotstxt.invalid_path"`; empty on success.
    code: []const u8 = "",
};

/// Limits from spec §5. Defaults match the spec.
pub const Options = struct {
    /// Bytes of a robots.txt file that are parsed; the rest is ignored and
    /// `RobotsFile.truncated` is set (RFC 9309 §2.5: at least 500 KiB).
    max_bytes: u64 = 512_000,
    /// Redirects `fetch` follows before treating the file as unavailable
    /// (RFC 9309 §2.3.1.2: at least five). Used by the io layer.
    max_redirects: u32 = 5,
};

/// One `allow` or `disallow` line.
pub const Rule = struct {
    allow: bool,
    /// The value as written, trimmed; not normalized. Bytes that aren't valid
    /// UTF-8 are replaced with U+FFFD.
    pattern: []const u8,
    /// 1-based line number in the file.
    line: u32,
    /// The pattern's original bytes, percent-encoding normalized (spec §3.3
    /// step 2): what matching compares. Not part of the spec's `Rule`.
    normalized: []const u8,
};

/// One or more `user-agent` lines and the group members that follow them.
pub const Group = struct {
    /// Values as written, trimmed (U+FFFD for invalid UTF-8).
    user_agents: []const []const u8,
    rules: []const Rule,
    /// Extension, not RFC 9309: the group's first valid `Crawl-delay`, in
    /// seconds.
    crawl_delay: ?f64,
};

/// A parsed robots.txt file. Owns all of its strings; call `deinit` when done.
pub const RobotsFile = struct {
    /// In file order. Groups naming the same agent are not merged here.
    groups: []const Group,
    /// Sitemap URLs in file order (U+FFFD for invalid UTF-8).
    sitemaps: []const []const u8,
    /// The input was longer than `Options.max_bytes`.
    truncated: bool,
    /// Holds every slice above.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *RobotsFile) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// What an HTTP status for `/robots.txt` means (spec §3.5, RFC 9309 §2.3.1).
pub const StatusPolicy = enum { parse, follow_redirect, allow_all, disallow_all };

/// Records `code` in `diag`, if given, and returns `err`.
pub fn fail(diag: ?*Diagnostics, comptime code: []const u8, err: Error) Error {
    if (diag) |d| d.* = .{ .code = "robotstxt." ++ code };
    return err;
}

// ---------------------------------------------------------------------------
// parse (spec §3.1)
// ---------------------------------------------------------------------------

const ws = " \t";

fn isEol(c: u8) bool {
    return c == '\n' or c == '\r';
}

/// The bytes that are parsed: at most `max_bytes`, minus a line the limit
/// cut (D-005). Sets `truncated`.
fn limitInput(data: []const u8, max_bytes: u64, truncated: *bool) []const u8 {
    if (data.len <= max_bytes) {
        truncated.* = false;
        return data;
    }
    truncated.* = true;
    const kept = data[0..@intCast(max_bytes)];
    if (kept.len == 0 or isEol(kept[kept.len - 1])) return kept;
    const cut = std.mem.findLastAny(u8, kept, "\r\n") orelse return kept[0..0];
    return kept[0 .. cut + 1];
}

/// Skips a UTF-8 byte order mark, or a prefix of one (spec §3.1 step 2).
fn skipBom(data: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    var n: usize = 0;
    while (n < bom.len and n < data.len and data[n] == bom[n]) n += 1;
    return data[n..];
}

const KeyValue = struct { key: []const u8, value: []const u8 };

/// Comment stripped and trimmed, then `key: value`, or `key value` when the
/// line is exactly two space- or tab-separated words (D-006).
fn keyValue(raw: []const u8) ?KeyValue {
    var line = raw;
    if (std.mem.findScalar(u8, line, '#')) |h| line = line[0..h];
    line = std.mem.trim(u8, line, ws);
    if (line.len == 0) return null;
    var key: []const u8 = undefined;
    var value: []const u8 = undefined;
    if (std.mem.findScalar(u8, line, ':')) |c| {
        key = line[0..c];
        value = line[c + 1 ..];
    } else {
        const sep = std.mem.findAny(u8, line, ws) orelse return null; // one word
        key = line[0..sep];
        value = std.mem.trimStart(u8, line[sep..], ws);
        if (std.mem.findAny(u8, value, ws) != null) return null; // three or more
    }
    key = std.mem.trim(u8, key, ws);
    if (key.len == 0) return null;
    return .{ .key = key, .value = std.mem.trim(u8, value, ws) };
}

/// `[0-9]+(\.[0-9]+)?`
fn isDecimal(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0) return false;
    if (i == s.len) return true;
    if (s[i] != '.') return false;
    i += 1;
    const frac = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i > frac and i == s.len;
}

/// Copies `bytes` as UTF-8, replacing each maximal invalid subpart with
/// U+FFFD (the Unicode "substitution of maximal subparts" practice, as
/// Python's `errors="replace"` does).
pub fn lossyUtf8(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return gpa.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len + 8);
    const replacement = "\u{FFFD}";
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b < 0x80) {
            try out.append(gpa, b);
            i += 1;
            continue;
        }
        // Continuation bytes still needed, and the range of the first one.
        const need: usize, const lo: u8, const hi: u8 = switch (b) {
            0xC2...0xDF => .{ 1, 0x80, 0xBF },
            0xE0 => .{ 2, 0xA0, 0xBF },
            0xE1...0xEC, 0xEE, 0xEF => .{ 2, 0x80, 0xBF },
            0xED => .{ 2, 0x80, 0x9F },
            0xF0 => .{ 3, 0x90, 0xBF },
            0xF1...0xF3 => .{ 3, 0x80, 0xBF },
            0xF4 => .{ 3, 0x80, 0x8F },
            else => {
                try out.appendSlice(gpa, replacement);
                i += 1;
                continue;
            },
        };
        var j = i + 1;
        var k: usize = 0;
        while (k < need and j < bytes.len) : (k += 1) {
            const c = bytes[j];
            const min: u8 = if (k == 0) lo else 0x80;
            const max: u8 = if (k == 0) hi else 0xBF;
            if (c < min or c > max) break;
            j += 1;
        }
        try out.appendSlice(gpa, if (k == need) bytes[i..j] else replacement);
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

const GroupBuilder = struct {
    agents: std.ArrayList([]const u8) = .empty,
    rules: std.ArrayList(Rule) = .empty,
    crawl_delay: ?f64 = null,
};

/// Spec operation `parse`. Lenient: never fails except for running out of
/// memory. `data` is only read during the call; the result owns copies of
/// everything it reports. Call `deinit` on the result.
pub fn parse(gpa: Allocator, data: []const u8, opts: Options) Allocator.Error!RobotsFile {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var truncated = false;
    const input = skipBom(limitInput(data, opts.max_bytes, &truncated));

    var groups: std.ArrayList(GroupBuilder) = .empty;
    var sitemaps: std.ArrayList([]const u8) = .empty;
    var current: ?*GroupBuilder = null;
    var agents_open = false; // true while consecutive user-agent lines build one group

    var line_no: u32 = 0;
    var i: usize = 0;
    while (i < input.len) {
        const start = i;
        while (i < input.len and !isEol(input[i])) i += 1;
        const line = input[start..i];
        if (i < input.len) i += if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') 2 else 1;
        line_no +|= 1;

        const kv = keyValue(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(kv.key, "user-agent")) {
            if (current == null or !agents_open) {
                // Pointers into `groups` move when it grows; re-take it below.
                try groups.append(a, .{});
                agents_open = true;
            }
            current = &groups.items[groups.items.len - 1];
            try current.?.agents.append(a, try lossyUtf8(a, kv.value));
        } else if (std.ascii.eqlIgnoreCase(kv.key, "allow") or std.ascii.eqlIgnoreCase(kv.key, "disallow")) {
            const g = current orelse continue; // before the first user-agent line
            agents_open = false; // even an empty value ends the agent list
            if (kv.value.len == 0) continue;
            const norm = try a.alloc(u8, normalizedLen(kv.value));
            normalizeInto(norm, kv.value);
            try g.rules.append(a, .{
                .allow = kv.key.len == "allow".len,
                .pattern = try lossyUtf8(a, kv.value),
                .line = line_no,
                .normalized = norm,
            });
        } else if (std.ascii.eqlIgnoreCase(kv.key, "crawl-delay")) {
            const g = current orelse continue;
            agents_open = false; // a group member, like allow and disallow (D-009)
            // The first non-negative decimal that is finite as an f64 wins;
            // anything else (even 400 nines) is skipped.
            if (g.crawl_delay == null and isDecimal(kv.value)) {
                const d = std.fmt.parseFloat(f64, kv.value) catch unreachable;
                if (std.math.isFinite(d)) g.crawl_delay = d;
            }
        } else if (std.ascii.eqlIgnoreCase(kv.key, "sitemap")) {
            if (kv.value.len > 0) try sitemaps.append(a, try lossyUtf8(a, kv.value));
        }
        // Any other key is ignored and leaves the agent list as it is (D-009).
    }

    const out = try a.alloc(Group, groups.items.len);
    for (groups.items, out) |*g, *o| o.* = .{
        .user_agents = g.agents.items,
        .rules = g.rules.items,
        .crawl_delay = g.crawl_delay,
    };
    return .{ .groups = out, .sitemaps = sitemaps.items, .truncated = truncated, .arena = arena };
}

// ---------------------------------------------------------------------------
// Normalization and matching (spec §3.3)
// ---------------------------------------------------------------------------

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn mustEncode(c: u8) bool {
    return c <= 0x20 or c >= 0x7F;
}

fn hexValue(c: u8) u8 {
    return std.fmt.charToDigit(c, 16) catch unreachable;
}

/// Length of `bytes` after `normalizeInto`.
pub fn normalizedLen(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '%' and i + 2 < bytes.len and std.ascii.isHex(bytes[i + 1]) and std.ascii.isHex(bytes[i + 2])) {
            n += if (isUnreserved(hexValue(bytes[i + 1]) << 4 | hexValue(bytes[i + 2]))) 1 else 3;
            i += 3;
        } else {
            n += if (mustEncode(c)) 3 else 1;
            i += 1;
        }
    }
    return n;
}

/// Percent-encoding normalization (spec §3.3 step 2, D-004), applied to paths
/// and patterns alike: `%XX` of an unreserved character is decoded, other
/// `%XX` get upper-case hex, and control bytes, space, 0x7F and non-ASCII
/// bytes are encoded. `out.len` must be `normalizedLen(bytes)`.
pub fn normalizeInto(out: []u8, bytes: []const u8) void {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '%' and i + 2 < bytes.len and std.ascii.isHex(bytes[i + 1]) and std.ascii.isHex(bytes[i + 2])) {
            const v = hexValue(bytes[i + 1]) << 4 | hexValue(bytes[i + 2]);
            if (isUnreserved(v)) {
                out[n] = v;
                n += 1;
            } else {
                out[n..][0..3].* = .{ '%', std.ascii.toUpper(bytes[i + 1]), std.ascii.toUpper(bytes[i + 2]) };
                n += 3;
            }
            i += 3;
        } else {
            if (mustEncode(c)) {
                out[n..][0..3].* = .{ '%', hex[c >> 4], hex[c & 0xF] };
                n += 3;
            } else {
                out[n] = c;
                n += 1;
            }
            i += 1;
        }
    }
    std.debug.assert(n == out.len);
}

/// Whether a normalized `pattern` matches a prefix of the normalized `path`:
/// `*` matches any run of bytes, and `$` as the last byte anchors the match
/// at the end of the path (anywhere else it's a literal).
///
/// Each literal piece between `*`s is found greedily, left to right, at its
/// earliest position after the previous one: the earliest end always leaves
/// the most room for the rest, so there's no backtracking (spec §9). With
/// `$`, the last piece must instead end the path.
pub fn patternMatches(pattern: []const u8, path: []const u8) bool {
    var p = pattern;
    const anchored = p.len > 0 and p[p.len - 1] == '$';
    if (anchored) p = p[0 .. p.len - 1];

    // The first piece is anchored at the start of the path.
    var star = std.mem.findScalar(u8, p, '*') orelse
        return if (anchored) std.mem.eql(u8, p, path) else std.mem.startsWith(u8, path, p);
    if (!std.mem.startsWith(u8, path, p[0..star])) return false;
    var pos = star;
    while (true) {
        const begin = star + 1;
        const next = std.mem.findScalarPos(u8, p, begin, '*');
        const piece = p[begin .. next orelse p.len];
        if (next == null and anchored)
            return path.len - pos >= piece.len and std.mem.endsWith(u8, path, piece);
        if (piece.len > 0) {
            const at = std.mem.findPos(u8, path, pos, piece) orelse return false;
            pos = at + piece.len;
        }
        star = next orelse return true;
    }
}

// ---------------------------------------------------------------------------
// Choosing the crawler's groups (spec §3.2)
// ---------------------------------------------------------------------------

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}

/// `*` alone, or followed by a space or tab, names the global group (D-001).
fn isGlobal(value: []const u8) bool {
    return value.len > 0 and value[0] == '*' and (value.len == 1 or value[1] == ' ' or value[1] == '\t');
}

/// The value's longest `[A-Za-z_-]` prefix (D-001): `FooBot/2.1` is `FooBot`.
fn groupToken(value: []const u8) []const u8 {
    var n: usize = 0;
    while (n < value.len and isTokenChar(value[n])) n += 1;
    return value[0..n];
}

fn namesCrawler(g: Group, user_agent: []const u8) bool {
    for (g.user_agents) |v| {
        if (!isGlobal(v) and std.ascii.eqlIgnoreCase(groupToken(v), user_agent)) return true;
    }
    return false;
}

fn namesGlobal(g: Group) bool {
    for (g.user_agents) |v| if (isGlobal(v)) return true;
    return false;
}

const Selection = enum {
    specific,
    global,

    /// The crawler's own groups if any group names it, else the global ones (D-002).
    fn of(robots: *const RobotsFile, user_agent: []const u8) Selection {
        for (robots.groups) |g| if (namesCrawler(g, user_agent)) return .specific;
        return .global;
    }

    fn includes(s: Selection, g: Group, user_agent: []const u8) bool {
        return switch (s) {
            .specific => namesCrawler(g, user_agent),
            .global => namesGlobal(g),
        };
    }
};

/// A product token is one or more of `A-Z a-z _ -` (D-003).
fn checkUserAgent(user_agent: []const u8, diag: ?*Diagnostics) Error!void {
    if (user_agent.len == 0) return fail(diag, "invalid_user_agent", error.InvalidInput);
    for (user_agent) |c| if (!isTokenChar(c)) return fail(diag, "invalid_user_agent", error.InvalidInput);
}

/// The path must start with `/`; a fragment is dropped (D-003).
fn checkPath(path: []const u8, diag: ?*Diagnostics) Error![]const u8 {
    if (path.len == 0 or path[0] != '/') return fail(diag, "invalid_path", error.InvalidInput);
    return path[0 .. std.mem.findScalar(u8, path, '#') orelse path.len];
}

/// Spec operation `matching_rule`. The rule that decides `isAllowed` for the
/// crawler's product token `user_agent` (`[A-Za-z_-]+`) and `path` (starts
/// with `/`, includes the query), or null when no rule matches or the path is
/// `/robots.txt`. The returned rule's slices belong to `robots`.
///
/// `gpa` is used only for paths whose normalized form is over 1 KiB.
/// Errors are checked in argument order: `robotstxt.invalid_user_agent`,
/// then `robotstxt.invalid_path`.
pub fn matchingRule(gpa: Allocator, robots: *const RobotsFile, user_agent: []const u8, path: []const u8, diag: ?*Diagnostics) Error!?Rule {
    try checkUserAgent(user_agent, diag);
    const p = try checkPath(path, diag);
    // RFC 9309 §2.2.2: /robots.txt is always allowed.
    if (std.mem.eql(u8, p[0 .. std.mem.findScalar(u8, p, '?') orelse p.len], "/robots.txt")) return null;

    var stack: [1024]u8 = undefined;
    const len = normalizedLen(p);
    const norm = if (len <= stack.len) stack[0..len] else try gpa.alloc(u8, len);
    defer if (len > stack.len) gpa.free(norm);
    normalizeInto(norm, p);

    const selection: Selection = .of(robots, user_agent);
    var best: ?Rule = null;
    for (robots.groups) |g| {
        if (!selection.includes(g, user_agent)) continue;
        for (g.rules) |r| {
            if (!patternMatches(r.normalized, norm)) continue;
            // Longest wins; on equal length allow beats disallow; otherwise
            // the first in the file stays.
            if (best) |b| {
                if (r.normalized.len < b.normalized.len) continue;
                if (r.normalized.len == b.normalized.len and (b.allow or !r.allow)) continue;
            }
            best = r;
        }
    }
    return best;
}

/// Spec operation `is_allowed`. Whether the crawler `user_agent` may fetch
/// `path`: true when no rule matches or the deciding rule is `allow`. See
/// `matchingRule` for the arguments and errors.
pub fn isAllowed(gpa: Allocator, robots: *const RobotsFile, user_agent: []const u8, path: []const u8, diag: ?*Diagnostics) Error!bool {
    const rule = try matchingRule(gpa, robots, user_agent, path, diag);
    return if (rule) |r| r.allow else true;
}

/// Spec operation `crawl_delay`. Extension, not RFC 9309: the `Crawl-delay`
/// in seconds from the first of the crawler's groups (§3.2) that has one, or
/// null.
pub fn crawlDelay(robots: *const RobotsFile, user_agent: []const u8, diag: ?*Diagnostics) Error!?f64 {
    try checkUserAgent(user_agent, diag);
    const selection: Selection = .of(robots, user_agent);
    for (robots.groups) |g| {
        if (selection.includes(g, user_agent)) if (g.crawl_delay) |d| return d;
    }
    return null;
}

/// Spec operation `status_policy`: what the HTTP status of a `/robots.txt`
/// fetch means (spec §3.5).
pub fn statusPolicy(http_status: u32) StatusPolicy {
    return switch (http_status) {
        200...299 => .parse,
        300...399 => .follow_redirect,
        429 => .disallow_all, // rate limited: unreachable (D-008)
        400...428, 430...499 => .allow_all,
        else => .disallow_all, // 5xx, and anything that isn't a final status (D-008)
    };
}

// ---------------------------------------------------------------------------
// Unit tests. The conformance runner (`zig build conformance`) is the real
// test suite; these cover the matcher, normalization, the size limit and a
// few parsing details, plus a fuzz target.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectNormalized(want: []const u8, in: []const u8) !void {
    var buf: [256]u8 = undefined;
    const n = normalizedLen(in);
    normalizeInto(buf[0..n], in);
    try testing.expectEqualStrings(want, buf[0..n]);
}

test "normalize: unreserved decoded, reserved upper-cased, raw bytes encoded" {
    try expectNormalized("/~user", "/%7Euser");
    try expectNormalized("/~user", "/%7euser");
    try expectNormalized("/baz", "/%62%61%7A");
    try expectNormalized("/a%2Fb", "/a%2fb");
    try expectNormalized("/%E3%83%84", "/\xE3\x83\x84");
    try expectNormalized("/%E3%83%84", "/%e3%83%84");
    try expectNormalized("/a%20b%09%7F%00", "/a b\t\x7F\x00");
    try expectNormalized("/?q=1&r=/x*$", "/?q=1&r=/x*$");
    // `%` without two hex digits is kept as is; `%25` stays encoded.
    try expectNormalized("/%", "/%");
    try expectNormalized("/%4", "/%4");
    try expectNormalized("/%zz", "/%zz");
    try expectNormalized("/%25", "/%25");
    // `%2A` and `%24` are literals, not wildcards.
    try expectNormalized("/%2A%24", "/%2a%24");
}

test "patternMatches: prefixes, `*` and `$`" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "/", "/anything", true },
        .{ "/fish", "/fish.html", true },
        .{ "/fish", "/Fish", false },
        .{ "/fish$", "/fish", true },
        .{ "/fish$", "/fish/", false },
        .{ "/*.php", "/index.php?x", true },
        .{ "/*.php$", "/index.php", true },
        .{ "/*.php$", "/index.php?x", false },
        .{ "/*.php$", "/a.php.php", true },
        .{ "/a$b", "/a$b", true },
        .{ "/a$b", "/a", false },
        .{ "$", "/", false },
        .{ "*", "/x", true },
        .{ "*$", "/x", true },
        .{ "/**/x", "/x", false },
        .{ "/**/x", "//x", true },
        .{ "/a*b*c", "/abc", true },
        .{ "/a*b*c", "/acb", false },
        .{ "/a*b*c$", "/abcc", true },
        .{ "/a*bc$", "/abcbc", true },
        .{ "/a*bcb$", "/abcb", true },
        // The anchored last piece must not overlap the pieces before it.
        .{ "/*ab*ba$", "/aba", false },
        .{ "/*ab*ba$", "/abba", true },
        .{ "/foo/*/qux", "/foo//qux", true },
        .{ "/foo/*/qux", "/foo/qux", false },
    };
    for (cases) |c| {
        testing.expectEqual(c[2], patternMatches(c[0], c[1])) catch |err| {
            std.debug.print("pattern {s} path {s}\n", .{ c[0], c[1] });
            return err;
        };
        try testing.expectEqual(c[2], referenceMatches(c[0], c[1]));
    }
}

/// `prefix`, then `piece` `n` times, then `suffix`. Test helper; the caller frees.
fn repeated(gpa: Allocator, prefix: []const u8, piece: []const u8, n: usize, suffix: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    for (0..n) |_| try out.appendSlice(gpa, piece);
    try out.appendSlice(gpa, suffix);
    return out.toOwnedSlice(gpa);
}

test "patternMatches: many `*` against a long path stays fast" {
    // A backtracking matcher takes exponential time here; the greedy one
    // scans the path once per piece.
    const gpa = testing.allocator;
    const path = try repeated(gpa, "/", "a", 20_000, "");
    defer gpa.free(path);
    const Case = struct { []const u8, usize, []const u8, bool };
    for ([_]Case{
        .{ "*a", 60, "*b", false },
        .{ "*a", 60, "*b$", false },
        .{ "*a", 60, "*a$", true },
        .{ "*a*", 60, "b", false },
        .{ "*", 500, "", true },
        .{ "*aa", 5_000, "*", true },
        .{ "*aa", 10_001, "", false },
    }) |c| {
        const pattern = try repeated(gpa, "/", c[0], c[1], c[2]);
        defer gpa.free(pattern);
        try testing.expectEqual(c[3], patternMatches(pattern, path));
    }
}

test "parse: size limit drops a cut line (D-005)" {
    const gpa = testing.allocator;
    const body = "User-agent: *\nDisallow: /a\nDisallow: /b\n";
    const Case = struct { max: u64, rules: usize, truncated: bool };
    const cases = [_]Case{
        .{ .max = body.len, .rules = 2, .truncated = false },
        .{ .max = body.len - 1, .rules = 1, .truncated = true }, // the terminator is cut
        .{ .max = "User-agent: *\nDisallow: /a\n".len, .rules = 1, .truncated = true },
        .{ .max = "User-agent: *\nDisallow: /a".len, .rules = 0, .truncated = true },
        .{ .max = "User-agent: *\n".len, .rules = 0, .truncated = true },
        .{ .max = 3, .rules = 0, .truncated = true },
        .{ .max = 0, .rules = 0, .truncated = true },
    };
    for (cases) |c| {
        var robots = try parse(gpa, body, .{ .max_bytes = c.max });
        defer robots.deinit();
        try testing.expectEqual(c.truncated, robots.truncated);
        const rules = if (robots.groups.len > 0) robots.groups[0].rules.len else 0;
        try testing.expectEqual(c.rules, rules);
    }
    // A lone \r ends the kept part: nothing is cut.
    var robots = try parse(gpa, "User-agent: *\rDisallow: /a\rDisallow: /b", .{ .max_bytes = 27 });
    defer robots.deinit();
    try testing.expectEqual(@as(usize, 1), robots.groups[0].rules.len);
}

test "parse: keys, missing colons, comments and line numbers" {
    const gpa = testing.allocator;
    const text =
        "\xEF\xBBuser-agent FooBot\n" ++ // partial BOM, two words
        "DISALLOW:/a # comment\r\n" ++
        "allow /b /c\n" ++ // three words: skipped
        "allow:\n" ++ // empty: no rule, but closes the agent list
        "user-agent: Bar # x\r" ++
        "crawl-delay: 1.50\n" ++
        "crawl-delay: 2\n" ++
        "sitemap: https://x.example/s.xml\n" ++
        "  Allow\t:\t/d\t\n" ++
        ": /e\n";
    var robots = try parse(gpa, text, .{});
    defer robots.deinit();
    try testing.expectEqual(@as(usize, 2), robots.groups.len);
    const foo = robots.groups[0];
    try testing.expectEqualStrings("FooBot", foo.user_agents[0]);
    try testing.expectEqual(@as(usize, 1), foo.rules.len);
    try testing.expectEqualStrings("/a", foo.rules[0].pattern);
    try testing.expectEqual(@as(u32, 2), foo.rules[0].line);
    try testing.expect(!foo.rules[0].allow);
    const bar = robots.groups[1];
    try testing.expectEqualStrings("Bar", bar.user_agents[0]);
    try testing.expectEqual(@as(?f64, 1.5), bar.crawl_delay);
    try testing.expectEqual(@as(usize, 1), bar.rules.len);
    try testing.expectEqualStrings("/d", bar.rules[0].pattern);
    try testing.expectEqual(@as(u32, 9), bar.rules[0].line);
    try testing.expect(bar.rules[0].allow);
    try testing.expectEqualStrings("https://x.example/s.xml", robots.sitemaps[0]);
}

test "parse: crawl-delay must be a non-negative decimal" {
    for ([_][]const u8{ "1", "0", "10.25", "007" }) |ok| try testing.expect(isDecimal(ok));
    for ([_][]const u8{ "", "-1", "1.", ".5", "1e3", "1.2.3", "+1", " 1", "inf" }) |bad| try testing.expect(!isDecimal(bad));
    // Too large to be finite: skipped, and a later valid value is kept.
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "User-agent: a\nCrawl-delay: ");
    try text.appendNTimes(gpa, '9', 400);
    try text.appendSlice(gpa, "\nCrawl-delay: 4\n");
    var robots = try parse(gpa, text.items, .{});
    defer robots.deinit();
    try testing.expectEqual(@as(?f64, 4), robots.groups[0].crawl_delay);
}

test "lossyUtf8: maximal subparts become U+FFFD" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "/caf\xE9", "/caf\u{FFFD}" },
        .{ "/\xE3\x83", "/\u{FFFD}" }, // cut-off sequence: one replacement
        .{ "/\xE3\x83x", "/\u{FFFD}x" },
        .{ "\xED\xA0\x80", "\u{FFFD}\u{FFFD}\u{FFFD}" }, // surrogate
        .{ "\xC0\x80", "\u{FFFD}\u{FFFD}" }, // overlong
        .{ "\xF4\x90\x80\x80", "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" }, // above U+10FFFF
        .{ "\xF0\x9F\x98\x80", "\u{1F600}" },
        .{ "\xFF", "\u{FFFD}" },
    };
    for (cases) |c| {
        const got = try lossyUtf8(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "matching: reported pattern is lossy, matching uses the original bytes" {
    const gpa = testing.allocator;
    var robots = try parse(gpa, "User-agent: *\nDisallow: /caf\xE9\n", .{});
    defer robots.deinit();
    const rule = (try matchingRule(gpa, &robots, "FooBot", "/caf%E9", null)).?;
    try testing.expectEqualStrings("/caf\u{FFFD}", rule.pattern);
    // The replacement character's own encoding doesn't match.
    try testing.expect(try isAllowed(gpa, &robots, "FooBot", "/caf%EF%BF%BD", null));
    try testing.expect(!try isAllowed(gpa, &robots, "FooBot", "/caf\xE9", null));
}

test "matching: argument errors in order, fragments, /robots.txt, long paths" {
    const gpa = testing.allocator;
    var robots = try parse(gpa, "User-agent: *\nDisallow: /\nAllow: /ok$\n", .{});
    defer robots.deinit();
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidInput, isAllowed(gpa, &robots, "Foo Bot", "x", &diag));
    try testing.expectEqualStrings("robotstxt.invalid_user_agent", diag.code);
    try testing.expectError(error.InvalidInput, isAllowed(gpa, &robots, "FooBot", "x", &diag));
    try testing.expectEqualStrings("robotstxt.invalid_path", diag.code);
    try testing.expectError(error.InvalidInput, isAllowed(gpa, &robots, "FooBot", "", &diag));
    try testing.expectError(error.InvalidInput, crawlDelay(&robots, "", &diag));
    try testing.expectEqualStrings("robotstxt.invalid_user_agent", diag.code);
    try testing.expect(try isAllowed(gpa, &robots, "FooBot", "/ok#fragment", null));
    try testing.expect(try isAllowed(gpa, &robots, "FooBot", "/robots.txt?x=1", null));
    try testing.expect(!try isAllowed(gpa, &robots, "FooBot", "/robots.txt/x", null));
    // A path normalizing to more than the stack buffer goes through `gpa`.
    const long = try repeated(gpa, "/", "\xFF", 2000, "");
    defer gpa.free(long);
    try testing.expect(!try isAllowed(gpa, &robots, "FooBot", long, null));
}

test "status_policy" {
    try testing.expectEqual(StatusPolicy.parse, statusPolicy(200));
    try testing.expectEqual(StatusPolicy.follow_redirect, statusPolicy(399));
    try testing.expectEqual(StatusPolicy.allow_all, statusPolicy(428));
    try testing.expectEqual(StatusPolicy.disallow_all, statusPolicy(429));
    try testing.expectEqual(StatusPolicy.allow_all, statusPolicy(430));
    try testing.expectEqual(StatusPolicy.disallow_all, statusPolicy(599));
    try testing.expectEqual(StatusPolicy.disallow_all, statusPolicy(std.math.maxInt(u32)));
}

/// Reference matcher for tests: dynamic programming over (pattern, path)
/// positions, no greediness. Patterns up to 4 KiB.
fn referenceMatches(pattern: []const u8, path: []const u8) bool {
    var p = pattern;
    const anchored = p.len > 0 and p[p.len - 1] == '$';
    if (anchored) p = p[0 .. p.len - 1];
    // reach[i]: p[0..i] can match path[0..j] for the current j.
    var reach: [4097]bool = undefined;
    std.debug.assert(p.len < reach.len);
    reach[0] = true;
    for (1..p.len + 1) |i| reach[i] = reach[i - 1] and p[i - 1] == '*';
    if (!anchored and reach[p.len]) return true;
    for (path) |c| {
        var i = p.len;
        while (i > 0) : (i -= 1) {
            reach[i] = if (p[i - 1] == '*') reach[i] or reach[i - 1] else reach[i - 1] and p[i - 1] == c;
        }
        reach[0] = false;
        for (1..p.len + 1) |k| {
            if (p[k - 1] == '*') reach[k] = reach[k] or reach[k - 1];
        }
        if (!anchored and reach[p.len]) return true;
    }
    return reach[p.len];
}

test "fuzz: parse and matching never crash and agree with each other" {
    try testing.fuzz({}, fuzzMatching, .{});
}

/// Pieces the fuzzer builds robots.txt lines from, besides raw bytes.
const fuzz_keys = [_][]const u8{ "User-agent", "user-agent", "Disallow", "allow", "ALLOW", "Crawl-delay", "Sitemap", "foo", "" };
const fuzz_seps = [_][]const u8{ ": ", ":", " ", "\t", " : ", "::" };
const fuzz_bytes = "/a*$%7Ee3?#=&. \t\xE3\x83\x84\xFF_-AbB09";
const fuzz_agents = [_][]const u8{ "FooBot", "foobot", "BarBot", "*", "* x", "*bot", "FooBot/2.1", "Foo Bar", "" };
const fuzz_eols = [_][]const u8{ "\n", "\r\n", "\r", "", " # c\n" };

fn fuzzMatching(context: void, smith: *testing.Smith) !void {
    _ = context;
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    const lines = smith.valueRangeAtMost(u8, 0, 16);
    for (0..lines) |_| {
        if (smith.boolWeighted(5, 1)) {
            const key = fuzz_keys[smith.index(fuzz_keys.len)];
            const sep = fuzz_seps[smith.index(fuzz_seps.len)];
            const value = if (smith.boolWeighted(1, 1)) fuzz_agents[smith.index(fuzz_agents.len)] else "";
            for ([_][]const u8{ key, sep, value }) |part| {
                const n = @min(part.len, buf.len - len);
                @memcpy(buf[len..][0..n], part[0..n]);
                len += n;
            }
            const extra = @min(smith.valueRangeAtMost(u8, 0, 12), buf.len - len);
            for (buf[len..][0..extra]) |*b| b.* = fuzz_bytes[smith.index(fuzz_bytes.len)];
            len += extra;
            const eol = fuzz_eols[smith.index(fuzz_eols.len)];
            const n = @min(eol.len, buf.len - len);
            @memcpy(buf[len..][0..n], eol[0..n]);
            len += n;
        } else {
            const n = @min(smith.valueRangeAtMost(u8, 0, 24), buf.len - len);
            smith.bytes(buf[len..][0..n]);
            len += n;
        }
    }
    const data = buf[0..len];

    var path_buf: [96]u8 = undefined;
    const path_len = smith.valueRangeAtMost(u8, 0, path_buf.len);
    for (path_buf[0..path_len]) |*b| b.* = if (smith.boolWeighted(4, 1)) fuzz_bytes[smith.index(fuzz_bytes.len)] else smith.value(u8);
    if (path_len > 0 and smith.boolWeighted(1, 8)) path_buf[0] = '/';
    const path = path_buf[0..path_len];

    var agent_buf: [12]u8 = undefined;
    const user_agent = if (smith.boolWeighted(1, 5)) blk: {
        const n = smith.valueRangeAtMost(u8, 0, agent_buf.len);
        smith.bytes(agent_buf[0..n]);
        break :blk agent_buf[0..n];
    } else fuzz_agents[smith.index(fuzz_agents.len)];

    const max_bytes: u64 = if (smith.boolWeighted(3, 1)) smith.valueRangeAtMost(u64, 0, 1100) else 512_000;

    const gpa = testing.allocator;
    var robots = try parse(gpa, data, .{ .max_bytes = max_bytes });
    defer robots.deinit();
    try testing.expectEqual(data.len > max_bytes, robots.truncated);

    var prev_line: u32 = 0;
    for (robots.groups) |g| {
        for (g.user_agents) |v| try testing.expect(std.unicode.utf8ValidateSlice(v));
        for (g.rules) |r| {
            try testing.expect(r.pattern.len > 0 and std.unicode.utf8ValidateSlice(r.pattern));
            try testing.expect(r.line > prev_line); // rules follow file order
            prev_line = r.line;
        }
        if (g.crawl_delay) |d| try testing.expect(d >= 0 and std.math.isFinite(d));
    }
    for (robots.sitemaps) |s| try testing.expect(s.len > 0 and std.unicode.utf8ValidateSlice(s));

    var diag: Diagnostics = .{};
    const rule = matchingRule(gpa, &robots, user_agent, path, &diag) catch |err| {
        try testing.expectEqual(error.InvalidInput, err);
        try testing.expect(std.mem.eql(u8, diag.code, "robotstxt.invalid_user_agent") or
            std.mem.eql(u8, diag.code, "robotstxt.invalid_path"));
        // is_allowed raises the same error.
        var diag2: Diagnostics = .{};
        try testing.expectError(err, isAllowed(gpa, &robots, user_agent, path, &diag2));
        try testing.expectEqualStrings(diag.code, diag2.code);
        return;
    };
    const allowed = try isAllowed(gpa, &robots, user_agent, path, null);
    try testing.expectEqual(rule == null or rule.?.allow, allowed);
    _ = try crawlDelay(&robots, user_agent, null);

    // The greedy matcher agrees with the reference one, and the chosen rule
    // is the best among the matching ones.
    const p = path[0 .. std.mem.findScalar(u8, path, '#') orelse path.len];
    var norm_buf: [3 * path_buf.len]u8 = undefined;
    const norm = norm_buf[0..normalizedLen(p)];
    normalizeInto(norm, p);
    const is_robots_txt = std.mem.eql(u8, p[0 .. std.mem.findScalar(u8, p, '?') orelse p.len], "/robots.txt");
    const selection: Selection = .of(&robots, user_agent);
    var best: ?struct { len: usize, allow: bool, line: u32 } = null;
    for (robots.groups) |g| {
        for (g.rules) |r| {
            const m = patternMatches(r.normalized, norm);
            try testing.expectEqual(referenceMatches(r.normalized, norm), m);
            if (!m or !selection.includes(g, user_agent)) continue;
            const n = r.normalized.len;
            if (best == null or n > best.?.len or (n == best.?.len and r.allow and !best.?.allow))
                best = .{ .len = n, .allow = r.allow, .line = r.line };
        }
    }
    if (is_robots_txt or best == null) {
        try testing.expectEqual(@as(?Rule, null), rule);
    } else {
        try testing.expectEqual(best.?.len, rule.?.normalized.len);
        try testing.expectEqual(best.?.allow, rule.?.allow);
        try testing.expectEqual(best.?.line, rule.?.line);
    }
}
