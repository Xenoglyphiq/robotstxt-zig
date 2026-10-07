//! Conformance runner: loads `.spec/conformance/manifest.json`, runs every
//! case, converts the result to canonical JSON and compares it the way the
//! case says to (`exact`, `float_tol` or `json_equal`).
//!
//! `fetch` cases run against a scripted transport that answers from the
//! case's `responses` map; a URL not listed has no response.
//!
//! Usage: `zig build conformance` (or `conformance [manifest.json]`).
//! Exit code 0 only if every case passes.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const Allocator = std.mem.Allocator;
const robotstxt = @import("robotstxt");
const robotstxt_io = @import("robotstxt_io");

const Outcome = enum { pass, fail };

/// Everything a case needs besides its JSON.
const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    why: *std.ArrayList(u8),

    fn failf(ctx: Ctx, comptime fmt: []const u8, args: anytype) !Outcome {
        try ctx.why.print(ctx.arena, fmt, args);
        return .fail;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    // The last argument wins, so `zig build conformance -- <manifest>` overrides
    // the vendored manifest the build step passes first.
    const manifest_path = if (args.len > 1) args[args.len - 1] else ".spec/conformance/manifest.json";
    const bytes = try Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(64 * 1024 * 1024));
    const manifest = (try json.parseFromSliceLeaky(json.Value, arena, bytes, .{})).object;
    const spec_version = manifest.get("spec_version").?.string;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var passed = [2]usize{ 0, 0 }; // core, io
    var total = [2]usize{ 0, 0 };
    for (manifest.get("cases").?.array.items) |case_value| {
        const case = case_value.object;
        const level: usize = if (std.mem.eql(u8, case.get("level").?.string, "io")) 1 else 0;
        total[level] += 1;
        var why: std.ArrayList(u8) = .empty;
        const ctx: Ctx = .{ .gpa = init.gpa, .arena = arena, .why = &why };
        const outcome = runCase(ctx, case) catch |err| blk: {
            try why.print(arena, "runner error: {s}", .{@errorName(err)});
            break :blk .fail;
        };
        switch (outcome) {
            .pass => passed[level] += 1,
            .fail => try out.print("FAIL {s}: {s}\n", .{ case.get("id").?.string, why.items }),
        }
    }
    try out.print("robotstxt zig (spec {s}): core {d}/{d}, io {d}/{d}, full {d}/{d}\n", .{
        spec_version,
        passed[0],
        total[0],
        passed[1],
        total[1],
        passed[0] + passed[1],
        total[0] + total[1],
    });
    try out.flush();
    if (passed[0] != total[0] or passed[1] != total[1]) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Running one case
// ---------------------------------------------------------------------------

/// The result of an operation, as canonical JSON (`{"value": …}` or
/// `{"error": …}`).
const Result = json.Value;

fn runCase(ctx: Ctx, case: json.ObjectMap) !Outcome {
    const op = case.get("op").?.string;
    const input = case.get("input").?.object;
    const opts = try options(case.get("options"));
    var diag: robotstxt.Diagnostics = .{};

    const result: Result = if (std.mem.eql(u8, op, "parse")) blk: {
        var robots = try robotstxt.parse(ctx.gpa, try inputBytes(ctx, input), opts);
        defer robots.deinit();
        break :blk try valueJson(ctx, try robotsJson(ctx, robots));
    } else if (std.mem.eql(u8, op, "is_allowed") or std.mem.eql(u8, op, "matching_rule")) blk: {
        var robots = try robotstxt.parse(ctx.gpa, try inputBytes(ctx, input), opts);
        defer robots.deinit();
        const a = input.get("args").?.object;
        const user_agent = a.get("user_agent").?.string;
        const path = a.get("path").?.string;
        if (std.mem.eql(u8, op, "is_allowed")) {
            const allowed = robotstxt.isAllowed(ctx.gpa, &robots, user_agent, path, &diag) catch |err|
                break :blk try errorJson(ctx, err, diag);
            break :blk try valueJson(ctx, .{ .bool = allowed });
        }
        const rule = robotstxt.matchingRule(ctx.gpa, &robots, user_agent, path, &diag) catch |err|
            break :blk try errorJson(ctx, err, diag);
        break :blk try valueJson(ctx, if (rule) |r| try ruleJson(ctx, r) else .null);
    } else if (std.mem.eql(u8, op, "crawl_delay")) blk: {
        var robots = try robotstxt.parse(ctx.gpa, try inputBytes(ctx, input), opts);
        defer robots.deinit();
        const user_agent = input.get("args").?.object.get("user_agent").?.string;
        const delay = robotstxt.crawlDelay(&robots, user_agent, &diag) catch |err|
            break :blk try errorJson(ctx, err, diag);
        break :blk try valueJson(ctx, if (delay) |d| try floatJson(ctx, d) else .null);
    } else if (std.mem.eql(u8, op, "status_policy")) blk: {
        const status = std.math.cast(u32, try toU64(input.get("value").?)) orelse return error.BadInteger;
        break :blk try valueJson(ctx, .{ .string = @tagName(robotstxt.statusPolicy(status)) });
    } else if (std.mem.eql(u8, op, "fetch")) blk: {
        const v = input.get("value").?.object;
        var script: Scripted = .{ .ctx = ctx, .responses = v.get("responses").?.object };
        var fetched = robotstxt_io.fetch(ctx.gpa, script.transport(), v.get("origin").?.string, opts, &diag) catch |err|
            break :blk try errorJson(ctx, err, diag);
        defer fetched.deinit();
        if (script.failure) |err| return err;
        break :blk try valueJson(ctx, try object(ctx, .{
            .{ "policy", json.Value{ .string = @tagName(fetched.policy) } },
            .{ "status", if (fetched.status) |s| json.Value{ .integer = s } else .null },
            .{ "robots", if (fetched.robots) |r| try robotsJson(ctx, r) else .null },
        }));
    } else return ctx.failf("unknown op {s}", .{op});

    return compare(ctx, case, result);
}

/// The transport `fetch` cases use (spec §6): each URL in `responses` maps to
/// `{"status", "location"?, "body_base64"?}` or `{"error": "network"}`; a URL
/// not listed has no response.
const Scripted = struct {
    ctx: Ctx,
    responses: json.ObjectMap,
    /// A malformed case, reported after `fetch` returns.
    failure: ?anyerror = null,

    fn transport(self: *Scripted) robotstxt_io.Transport {
        return .{ .ptr = self, .vtable = &.{ .get = get } };
    }

    fn get(ptr: *anyopaque, gpa: Allocator, url: []const u8, max_body: u64) robotstxt_io.Transport.GetError!robotstxt_io.Transport.Response {
        const self: *Scripted = @ptrCast(@alignCast(ptr));
        const r = (self.responses.get(url) orelse return error.NoResponse).object;
        if (r.get("error") != null) return error.NoResponse;
        const status = toU64(r.get("status").?) catch |err| return self.malformed(err);
        const location = if (r.get("location")) |l| try gpa.dupe(u8, l.string) else null;
        errdefer if (location) |l| gpa.free(l);
        const body = if (r.get("body_base64")) |b| decodeBase64(self.ctx.arena, b.string) catch |err| return self.malformed(err) else "";
        const n: usize = @intCast(@min(body.len, max_body)); // at most what fetch asks for
        return .{
            .status = std.math.cast(u32, status) orelse return self.malformed(error.BadInteger),
            .location = location,
            .body = try gpa.dupe(u8, body[0..n]),
        };
    }

    fn malformed(self: *Scripted, err: anyerror) error{NoResponse} {
        self.failure = err;
        return error.NoResponse;
    }
};

/// Compares `got` with the case's `expect`, per its `compare` mode.
fn compare(ctx: Ctx, case: json.ObjectMap, got: Result) !Outcome {
    const mode = case.get("compare").?.string;
    const expect = case.get("expect").?;
    const tol: f64 = if (std.mem.eql(u8, mode, "float_tol"))
        try toFloat(case.get("tolerance") orelse return ctx.failf("float_tol without a tolerance", .{}))
    else if (std.mem.eql(u8, mode, "exact") or std.mem.eql(u8, mode, "json_equal"))
        0
    else
        return ctx.failf("unknown compare mode {s}", .{mode});

    // Errors compare kind and code.
    if (expect.object.get("error")) |want_err| {
        if (got.object.get("error")) |got_err| {
            const w = want_err.object;
            const g = got_err.object;
            if (std.mem.eql(u8, w.get("kind").?.string, g.get("kind").?.string) and
                std.mem.eql(u8, w.get("code").?.string, g.get("code").?.string)) return .pass;
        }
    } else if (jsonEqual(expect, got, tol)) return .pass;
    return ctx.failf("expected {s}, got {s}", .{ try show(ctx, expect), try show(ctx, got) });
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

fn options(value: ?json.Value) !robotstxt.Options {
    var opts: robotstxt.Options = .{};
    const obj = (value orelse return opts).object;
    if (obj.get("max_bytes")) |v| opts.max_bytes = try toU64(v);
    if (obj.get("max_redirects")) |v| opts.max_redirects = std.math.cast(u32, try toU64(v)) orelse return error.BadOption;
    return opts;
}

/// A robots.txt file: `{"value": "<text>"}` or `{"base64": …}` (raw bytes).
fn inputBytes(ctx: Ctx, input: json.ObjectMap) ![]const u8 {
    if (input.get("base64")) |b| return decodeBase64(ctx.arena, b.string);
    if (input.get("value")) |v| return v.string;
    return error.BadInput;
}

fn decodeBase64(arena: Allocator, text: []const u8) ![]u8 {
    const d = std.base64.standard.Decoder;
    const out = try arena.alloc(u8, try d.calcSizeForSlice(text));
    try d.decode(out, text);
    return out;
}

/// Canonical u64: a number, or a decimal string beyond 2^53.
fn toU64(v: json.Value) !u64 {
    return switch (v) {
        .integer => |i| std.math.cast(u64, i) orelse error.BadInteger,
        .number_string, .string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.BadInteger,
    };
}

fn toFloat(v: json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        .string => |s| if (std.mem.eql(u8, s, "NaN"))
            std.math.nan(f64)
        else if (std.mem.eql(u8, s, "Infinity"))
            std.math.inf(f64)
        else if (std.mem.eql(u8, s, "-Infinity"))
            -std.math.inf(f64)
        else
            error.BadFloat,
        else => error.BadFloat,
    };
}

// ---------------------------------------------------------------------------
// Canonical JSON (.kit/CONVENTIONS.md §5)
// ---------------------------------------------------------------------------

fn object(ctx: Ctx, fields: anytype) !json.Value {
    var map: json.ObjectMap = .empty;
    inline for (fields) |f| try map.put(ctx.arena, f[0], f[1]);
    return .{ .object = map };
}

fn valueJson(ctx: Ctx, v: json.Value) !Result {
    return object(ctx, .{.{ "value", v }});
}

fn kindOf(err: robotstxt.Error) []const u8 {
    return switch (err) {
        error.InvalidInput => "invalid_input",
        error.OutOfMemory => "out_of_memory",
    };
}

fn errorJson(ctx: Ctx, err: robotstxt.Error, diag: robotstxt.Diagnostics) !Result {
    const body = try object(ctx, .{
        .{ "kind", json.Value{ .string = kindOf(err) } },
        .{ "code", json.Value{ .string = diag.code } },
    });
    return object(ctx, .{.{ "error", body }});
}

/// Floats are numbers; NaN and the infinities are strings.
fn floatJson(ctx: Ctx, v: f64) !json.Value {
    _ = ctx;
    if (std.math.isNan(v)) return .{ .string = "NaN" };
    if (std.math.isInf(v)) return .{ .string = if (v > 0) "Infinity" else "-Infinity" };
    return .{ .float = v };
}

fn stringsJson(ctx: Ctx, items: []const []const u8) !json.Value {
    var list = json.Array.init(ctx.arena);
    for (items) |s| try list.append(.{ .string = try ctx.arena.dupe(u8, s) });
    return .{ .array = list };
}

fn ruleJson(ctx: Ctx, r: robotstxt.Rule) !json.Value {
    return object(ctx, .{
        .{ "allow", json.Value{ .bool = r.allow } },
        .{ "pattern", json.Value{ .string = try ctx.arena.dupe(u8, r.pattern) } },
        .{ "line", json.Value{ .integer = r.line } },
    });
}

fn robotsJson(ctx: Ctx, robots: robotstxt.RobotsFile) !json.Value {
    var groups = json.Array.init(ctx.arena);
    for (robots.groups) |g| {
        var rules = json.Array.init(ctx.arena);
        for (g.rules) |r| try rules.append(try ruleJson(ctx, r));
        try groups.append(try object(ctx, .{
            .{ "user_agents", try stringsJson(ctx, g.user_agents) },
            .{ "rules", json.Value{ .array = rules } },
            .{ "crawl_delay", if (g.crawl_delay) |d| try floatJson(ctx, d) else .null },
        }));
    }
    return object(ctx, .{
        .{ "groups", json.Value{ .array = groups } },
        .{ "sitemaps", try stringsJson(ctx, robots.sitemaps) },
        .{ "truncated", json.Value{ .bool = robots.truncated } },
    });
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

fn isNumber(v: json.Value) bool {
    return v == .integer or v == .float or v == .number_string;
}

/// Structural equality: objects by key (order-insensitive), arrays in order,
/// integers exactly, and floats within `tol` (exactly when `tol` is 0).
fn jsonEqual(a: json.Value, b: json.Value, tol: f64) bool {
    if (isNumber(a) and isNumber(b)) {
        if (a == .integer and b == .integer) return a.integer == b.integer;
        const x = toFloat(a) catch return false;
        const y = toFloat(b) catch return false;
        if (std.math.isNan(x) or std.math.isNan(y)) return std.math.isNan(x) and std.math.isNan(y);
        return if (tol == 0) x == y else @abs(x - y) <= tol;
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q, tol)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(kv.value_ptr.*, other, tol)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn show(ctx: Ctx, v: json.Value) ![]const u8 {
    const text = try json.Stringify.valueAlloc(ctx.arena, v, .{});
    const max = 300;
    if (text.len <= max) return text;
    return std.fmt.allocPrint(ctx.arena, "{s}… ({d} bytes)", .{ text[0..max], text.len });
}
