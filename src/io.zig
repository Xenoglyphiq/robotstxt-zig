//! robots.txt (RFC 9309), io layer: fetch an origin's `/robots.txt` through a
//! transport (HTTP on `std.http.Client`, or your own), follow redirects,
//! apply the status policy and parse the file.
//!
//! Implements the io operation of the robotstxt spec (see
//! `.spec/spec/SPEC.md` §3.6). Parsing and matching live in the core module,
//! `robotstxt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const robotstxt = @import("robotstxt");

pub const Error = robotstxt.Error;
pub const Diagnostics = robotstxt.Diagnostics;
pub const Options = robotstxt.Options;
pub const RobotsFile = robotstxt.RobotsFile;
pub const StatusPolicy = robotstxt.StatusPolicy;

const fail = robotstxt.fail;

/// How `fetch` arrived at its result.
pub const FetchPolicy = enum {
    /// A 2xx response was parsed: use `Fetched.robots`.
    parsed,
    /// The file is unavailable (4xx except 429, too many redirects, or a
    /// redirect with no `Location`): the crawler may fetch anything.
    allow_all,
    /// The site is unreachable (no response, including a redirect to a URL
    /// that isn't `http` or `https`; 429, 5xx, or a status outside 200–599):
    /// the crawler should fetch nothing.
    disallow_all,
};

/// The result of `fetch`. Call `deinit` when done.
pub const Fetched = struct {
    policy: FetchPolicy,
    /// The final HTTP status; null when there was no response.
    status: ?u32,
    /// The parsed file; present exactly when `policy` is `parsed`.
    robots: ?RobotsFile,

    pub fn deinit(self: *Fetched) void {
        if (self.robots) |*r| r.deinit();
        self.* = undefined;
    }
};

/// Something that, given a URL, returns a status, the `Location` header and
/// the body, or reports that there was no response (spec §3.6): a
/// type-erased pointer and a vtable.
///
/// `HttpTransport` is provided. Implement `get` to plug in another client, a
/// cache, or canned responses in tests.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const GetError = error{
        /// Connection, TLS or timeout failure: nothing usable arrived.
        NoResponse,
        OutOfMemory,
    };

    /// One HTTP response. `location` and `body` are allocated with the `gpa`
    /// passed to `get`, and `fetch` frees them.
    pub const Response = struct {
        status: u32,
        /// The `Location` header, if any, as sent (not yet resolved).
        location: ?[]u8 = null,
        /// At most `max_body` bytes of the body. Only read for 2xx statuses;
        /// a transport may leave it empty otherwise.
        body: []u8 = &.{},
    };

    pub const VTable = struct {
        /// Requests `url` with `GET` and returns the response without
        /// following redirects. Reads at most `max_body` bytes of the body.
        get: *const fn (ptr: *anyopaque, gpa: Allocator, url: []const u8, max_body: u64) GetError!Response,
    };

    /// See `VTable.get`.
    pub fn get(t: Transport, gpa: Allocator, url: []const u8, max_body: u64) GetError!Response {
        return t.vtable.get(t.ptr, gpa, url, max_body);
    }
};

/// A `Transport` on `std.http.Client`. It doesn't follow redirects itself
/// (`fetch` does, counting them), sends `Accept-Encoding: identity`, and
/// still decodes a gzip, deflate or zstd body from a server that compresses
/// anyway.
///
/// `std.http.Client` has no timeouts, so neither does this transport.
pub const HttpTransport = struct {
    client: *std.http.Client,
    /// The `User-Agent` header, such as `"FooBot/1.0 (+https://example.com/bot)"`.
    /// Null sends `std.http.Client`'s default.
    user_agent: ?[]const u8 = null,

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .get = get };

    fn get(ptr: *anyopaque, gpa: Allocator, url: []const u8, max_body: u64) Transport.GetError!Transport.Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        const uri = std.Uri.parse(url) catch return error.NoResponse;
        var req = self.client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false, // the body may be left unread
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = if (self.user_agent) |ua| .{ .override = ua } else .default,
            },
        }) catch return error.NoResponse;
        defer req.deinit();
        req.sendBodiless() catch return error.NoResponse;
        var response = req.receiveHead(&.{}) catch return error.NoResponse;

        const status: u32 = @backingInt(response.head.status);
        // Head strings are invalidated once the body is read.
        const location = if (response.head.location) |l| try gpa.dupe(u8, l) else null;
        errdefer if (location) |l| gpa.free(l);
        if (status < 200 or status > 299) return .{ .status = status, .location = location };

        const decompress_len: usize = switch (response.head.content_encoding) {
            .identity => 0,
            .zstd => std.compress.zstd.default_window_len,
            .deflate, .gzip => std.compress.flate.max_window_len,
            .compress => return error.NoResponse,
        };
        const decompress_buf = try gpa.alloc(u8, decompress_len);
        defer gpa.free(decompress_buf);
        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(gpa);
        reader.appendRemaining(gpa, &body, .limited64(max_body)) catch |err| switch (err) {
            error.StreamTooLong => {}, // `max_body` bytes read; the rest is ignored
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.NoResponse,
        };
        return .{ .status = status, .location = location, .body = try body.toOwnedSlice(gpa) };
    }
};

/// Checks that `origin` is `http://` or `https://`, an authority (host and
/// optional port, no userinfo), and at most a trailing `/`. Returns it
/// without the slash.
fn checkOrigin(origin: []const u8, diag: ?*Diagnostics) Error![]const u8 {
    const rest = if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else
        return fail(diag, "invalid_origin", error.InvalidInput);
    const authority = if (std.mem.endsWith(u8, rest, "/")) rest[0 .. rest.len - 1] else rest;
    if (authority.len == 0) return fail(diag, "invalid_origin", error.InvalidInput);
    for (authority) |c| switch (c) {
        '/', '?', '#', '@', 0...' ', 0x7F => return fail(diag, "invalid_origin", error.InvalidInput),
        else => {},
    };
    return origin[0 .. origin.len - (rest.len - authority.len)];
}

/// Spec operation `fetch`. Requests `origin/robots.txt` through `transport`,
/// follows up to `opts.max_redirects` redirects, applies `statusPolicy`, and
/// parses a 2xx body (reading at most `opts.max_bytes + 1` bytes of it).
///
/// The only error is `robotstxt.invalid_origin` (plus `OutOfMemory`): a
/// failed fetch is a policy, not an error. Call `deinit` on the result.
pub fn fetch(gpa: Allocator, transport: Transport, origin: []const u8, opts: Options, diag: ?*Diagnostics) Error!Fetched {
    const base = try checkOrigin(origin, diag);
    var url = try std.mem.concat(gpa, u8, &.{ base, "/robots.txt" });
    defer gpa.free(url);
    const max_body = opts.max_bytes +| 1;

    var redirects: u32 = 0;
    while (true) {
        const res = transport.get(gpa, url, max_body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoResponse => return .{ .policy = .disallow_all, .status = null, .robots = null },
        };
        defer if (res.location) |l| gpa.free(l);
        defer gpa.free(res.body);

        switch (robotstxt.statusPolicy(res.status)) {
            .follow_redirect => {
                // One redirect too many, or nowhere to go: unavailable (D-007).
                const unavailable: Fetched = .{ .policy = .allow_all, .status = res.status, .robots = null };
                if (redirects == opts.max_redirects) return unavailable;
                const location = res.location orelse return unavailable;
                if (location.len == 0) return unavailable;
                // A URL that isn't http or https gets no response: unreachable.
                const next = (try resolve(gpa, url, location)) orelse
                    return .{ .policy = .disallow_all, .status = null, .robots = null };
                gpa.free(url);
                url = next;
                redirects += 1;
            },
            .parse => return .{
                .policy = .parsed,
                .status = res.status,
                .robots = try robotstxt.parse(gpa, res.body, opts),
            },
            .allow_all => return .{ .policy = .allow_all, .status = res.status, .robots = null },
            .disallow_all => return .{ .policy = .disallow_all, .status = res.status, .robots = null },
        }
    }
}

// ---------------------------------------------------------------------------
// Resolving a redirect's Location (RFC 3986 §5.2)
// ---------------------------------------------------------------------------

const Parts = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
};

/// Splits a URI reference into its components (RFC 3986 appendix B). The
/// fragment is dropped: it's never sent.
fn split(ref: []const u8) Parts {
    var parts: Parts = .{};
    var rest = ref[0 .. std.mem.findScalar(u8, ref, '#') orelse ref.len];
    // A scheme is ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) before the first
    // ':' that comes before any '/', '?' or '#'.
    if (std.mem.findAny(u8, rest, ":/?")) |i| {
        if (rest[i] == ':' and i > 0 and std.ascii.isAlphabetic(rest[0])) {
            const ok = for (rest[0..i]) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) break false;
            } else true;
            if (ok) {
                parts.scheme = rest[0..i];
                rest = rest[i + 1 ..];
            }
        }
    }
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const end = std.mem.findAny(u8, rest, "/?") orelse rest.len;
        parts.authority = rest[0..end];
        rest = rest[end..];
    }
    const q = std.mem.findScalar(u8, rest, '?');
    parts.path = rest[0 .. q orelse rest.len];
    if (q) |i| parts.query = rest[i + 1 ..];
    return parts;
}

/// RFC 3986 §5.2.4 `remove_dot_segments`, appending to `out`.
fn removeDotSegments(gpa: Allocator, out: *std.ArrayList(u8), path: []const u8) Allocator.Error!void {
    const start = out.items.len;
    var in = path;
    while (in.len > 0) {
        if (std.mem.startsWith(u8, in, "../")) {
            in = in[3..];
        } else if (std.mem.startsWith(u8, in, "./")) {
            in = in[2..];
        } else if (std.mem.startsWith(u8, in, "/./")) {
            in = in[2..];
        } else if (std.mem.eql(u8, in, "/.")) {
            in = "/";
        } else if (std.mem.startsWith(u8, in, "/../") or std.mem.eql(u8, in, "/..")) {
            in = if (in.len == 3) "/" else in[3..];
            // Remove the last segment written, and its preceding '/'.
            const written = out.items[start..];
            out.shrinkRetainingCapacity(start + (std.mem.findScalarLast(u8, written, '/') orelse 0));
        } else if (std.mem.eql(u8, in, ".") or std.mem.eql(u8, in, "..")) {
            in = "";
        } else {
            // Move the first segment, with its leading '/' if any.
            const from: usize = if (in[0] == '/') 1 else 0;
            const end = std.mem.findScalarPos(u8, in, from, '/') orelse in.len;
            try out.appendSlice(gpa, in[0..end]);
            in = in[end..];
        }
    }
}

/// Resolves `location` against `base` (RFC 3986 §5.2.2). Returns null unless
/// the result is an `http` or `https` URL with a host. The caller owns the
/// result.
pub fn resolve(gpa: Allocator, base: []const u8, location: []const u8) Allocator.Error!?[]u8 {
    const b = split(base);
    const r = split(std.mem.trim(u8, location, " \t"));
    var t: Parts = .{};
    var merged: std.ArrayList(u8) = .empty; // owns a merged path, when one is needed
    defer merged.deinit(gpa);
    var dotted = true; // the target path still needs remove_dot_segments
    if (r.scheme != null) {
        t = r;
    } else {
        t.scheme = b.scheme;
        if (r.authority != null) {
            t.authority = r.authority;
            t.path = r.path;
            t.query = r.query;
        } else {
            t.authority = b.authority;
            if (r.path.len == 0) {
                t.path = b.path;
                t.query = r.query orelse b.query;
                dotted = false;
            } else {
                t.query = r.query;
                if (r.path[0] == '/') {
                    t.path = r.path;
                } else {
                    // Merge: the base path up to its last '/', then the reference.
                    if (b.authority != null and b.path.len == 0) {
                        try merged.append(gpa, '/');
                    } else if (std.mem.findScalarLast(u8, b.path, '/')) |i| {
                        try merged.appendSlice(gpa, b.path[0 .. i + 1]);
                    }
                    try merged.appendSlice(gpa, r.path);
                    t.path = merged.items;
                }
            }
        }
    }
    const scheme = t.scheme orelse return null;
    const is_http = std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https");
    const authority = t.authority orelse return null;
    if (!is_http or authority.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (scheme) |c| try out.append(gpa, std.ascii.toLower(c));
    try out.appendSlice(gpa, "://");
    try out.appendSlice(gpa, authority);
    if (t.path.len == 0) {
        try out.append(gpa, '/');
    } else if (dotted) {
        try removeDotSegments(gpa, &out, t.path);
    } else {
        try out.appendSlice(gpa, t.path);
    }
    if (t.query) |q| {
        try out.append(gpa, '?');
        try out.appendSlice(gpa, q);
    }
    return try out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Unit tests: origins, redirect resolution, and fetch over a scripted
// transport.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "resolve: RFC 3986 §5.4 examples and redirect shapes" {
    const gpa = testing.allocator;
    const base = "http://a/b/c/d;p?q";
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "g", "http://a/b/c/g" },
        .{ "./g", "http://a/b/c/g" },
        .{ "g/", "http://a/b/c/g/" },
        .{ "/g", "http://a/g" },
        .{ "//g", "http://g/" },
        .{ "?y", "http://a/b/c/d;p?y" },
        .{ "g?y", "http://a/b/c/g?y" },
        .{ "#s", "http://a/b/c/d;p?q" },
        .{ "g#s", "http://a/b/c/g" },
        .{ ";x", "http://a/b/c/;x" },
        .{ "", "http://a/b/c/d;p?q" },
        .{ ".", "http://a/b/c/" },
        .{ "./", "http://a/b/c/" },
        .{ "..", "http://a/b/" },
        .{ "../", "http://a/b/" },
        .{ "../g", "http://a/b/g" },
        .{ "../..", "http://a/" },
        .{ "../../g", "http://a/g" },
        .{ "../../../g", "http://a/g" },
        .{ "/./g", "http://a/g" },
        .{ "/../g", "http://a/g" },
        .{ "g.", "http://a/b/c/g." },
        .{ "..g", "http://a/b/c/..g" },
        .{ "./../g", "http://a/b/g" },
        .{ "g;x=1/../y", "http://a/b/c/y" },
        .{ "HTTPS://Other.example/x/../r", "https://Other.example/r" },
        .{ "ftp://a/robots.txt", null },
        .{ "mailto:x@y", null },
        .{ "https://", null },
    };
    for (cases) |c| {
        const got = try resolve(gpa, base, c[0]);
        defer if (got) |g| gpa.free(g);
        if (c[1]) |want| {
            testing.expectEqualStrings(want, got orelse "(null)") catch |err| {
                std.debug.print("reference {s}\n", .{c[0]});
                return err;
            };
        } else try testing.expectEqual(@as(?[]u8, null), got);
    }
    const rel = (try resolve(gpa, "https://example.com/r1", "/r2")).?;
    defer gpa.free(rel);
    try testing.expectEqualStrings("https://example.com/r2", rel);
}

test "fetch: invalid origins" {
    var script: Scripted = .{ .responses = &.{} };
    var diag: Diagnostics = .{};
    for ([_][]const u8{
        "",                              "example.com",           "ftp://example.com",     "https://",
        "https:///",                     "https://example.com/x", "https://example.com?a", "https://example.com#f",
        "https://example.com//",         "https://exa mple.com",  "HTTPS://example.com",   "https://user:secret@example.com",
        "http://user@example.com:8080/",
    }) |origin| {
        try testing.expectError(error.InvalidInput, fetch(testing.allocator, script.transport(), origin, .{}, &diag));
        try testing.expectEqualStrings("robotstxt.invalid_origin", diag.code);
    }
    try testing.expectEqual(@as(usize, 0), script.calls);
}

/// A transport that answers from a fixed list of URL → response pairs; any
/// other URL has no response.
const Scripted = struct {
    const Entry = struct { url: []const u8, status: u32, location: ?[]const u8 = null, body: []const u8 = "" };
    responses: []const Entry,
    calls: usize = 0,
    last_max_body: u64 = 0,

    fn transport(self: *Scripted) Transport {
        return .{ .ptr = self, .vtable = &.{ .get = get } };
    }

    fn get(ptr: *anyopaque, gpa: Allocator, url: []const u8, max_body: u64) Transport.GetError!Transport.Response {
        const self: *Scripted = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last_max_body = max_body;
        for (self.responses) |e| {
            if (!std.mem.eql(u8, e.url, url)) continue;
            const location = if (e.location) |l| try gpa.dupe(u8, l) else null;
            errdefer if (location) |l| gpa.free(l);
            const n: usize = @intCast(@min(e.body.len, max_body));
            return .{ .status = e.status, .location = location, .body = try gpa.dupe(u8, e.body[0..n]) };
        }
        return error.NoResponse;
    }
};

test "fetch: statuses, redirects and limits" {
    const gpa = testing.allocator;
    const body = "User-agent: *\nDisallow: /private\n";
    {
        var script: Scripted = .{ .responses = &.{.{ .url = "http://x.example:8080/robots.txt", .status = 200, .body = body }} };
        var got = try fetch(gpa, script.transport(), "http://x.example:8080/", .{}, null);
        defer got.deinit();
        try testing.expectEqual(FetchPolicy.parsed, got.policy);
        try testing.expectEqual(@as(?u32, 200), got.status);
        try testing.expect(!try robotstxt.isAllowed(gpa, &got.robots.?, "FooBot", "/private/x", null));
        try testing.expectEqual(@as(u64, 512_001), script.last_max_body);
    }
    {
        // max_bytes reaches the parser, and the transport is asked for one byte more.
        var script: Scripted = .{ .responses = &.{.{ .url = "https://x.example/robots.txt", .status = 200, .body = body }} };
        var got = try fetch(gpa, script.transport(), "https://x.example", .{ .max_bytes = 20 }, null);
        defer got.deinit();
        try testing.expect(got.robots.?.truncated);
        try testing.expectEqual(@as(usize, 0), got.robots.?.groups[0].rules.len);
        try testing.expectEqual(@as(u64, 21), script.last_max_body);
    }
    // A redirect loop stops after max_redirects and counts as unavailable.
    {
        var script: Scripted = .{ .responses = &.{.{ .url = "https://x.example/robots.txt", .status = 307, .location = "/robots.txt" }} };
        var got = try fetch(gpa, script.transport(), "https://x.example", .{ .max_redirects = 2 }, null);
        defer got.deinit();
        try testing.expectEqual(FetchPolicy.allow_all, got.policy);
        try testing.expectEqual(@as(?u32, 307), got.status);
        try testing.expectEqual(@as(usize, 3), script.calls);
    }
    // max_redirects 0 follows none.
    {
        var script: Scripted = .{ .responses = &.{
            .{ .url = "https://x.example/robots.txt", .status = 301, .location = "https://y.example/robots.txt" },
            .{ .url = "https://y.example/robots.txt", .status = 200, .body = body },
        } };
        var got = try fetch(gpa, script.transport(), "https://x.example", .{ .max_redirects = 0 }, null);
        defer got.deinit();
        try testing.expectEqual(FetchPolicy.allow_all, got.policy);
    }
    // An empty Location counts as missing: unavailable.
    {
        var script: Scripted = .{ .responses = &.{.{ .url = "https://x.example/robots.txt", .status = 302, .location = "" }} };
        var got = try fetch(gpa, script.transport(), "https://x.example", .{}, null);
        defer got.deinit();
        try testing.expectEqual(FetchPolicy.allow_all, got.policy);
        try testing.expectEqual(@as(?u32, 302), got.status);
    }
    // A redirect to a URL with no response, or to one that isn't http(s): unreachable.
    // The non-http(s) URL is never requested.
    for ([_]struct { []const u8, usize }{ .{ "/gone", 2 }, .{ "ftp://x.example/robots.txt", 1 } }) |c| {
        var script: Scripted = .{ .responses = &.{.{ .url = "https://x.example/robots.txt", .status = 302, .location = c[0] }} };
        var got = try fetch(gpa, script.transport(), "https://x.example", .{}, null);
        defer got.deinit();
        try testing.expectEqual(FetchPolicy.disallow_all, got.policy);
        try testing.expectEqual(@as(?u32, null), got.status);
        try testing.expectEqual(c[1], script.calls);
    }
    for ([_]struct { u32, FetchPolicy }{ .{ 404, .allow_all }, .{ 429, .disallow_all }, .{ 500, .disallow_all }, .{ 199, .disallow_all } }) |c| {
        var script: Scripted = .{ .responses = &.{.{ .url = "https://x.example/robots.txt", .status = c[0], .body = body }} };
        var got = try fetch(gpa, script.transport(), "https://x.example", .{}, null);
        defer got.deinit();
        try testing.expectEqual(c[1], got.policy);
        try testing.expectEqual(@as(?u32, c[0]), got.status);
        try testing.expectEqual(@as(?RobotsFile, null), got.robots);
    }
}
