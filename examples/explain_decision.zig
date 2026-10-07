//! Canonical example `explain_decision`: for a few paths, print the rule
//! that decides whether `NowhereToBeBot` may fetch it (allow or disallow, the
//! pattern and its line), or that no rule applies.
const std = @import("std");
const robotstxt = @import("robotstxt");

const sample =
    \\User-agent: *
    \\Disallow: /
    \\
    \\User-agent: NowhereToBeBot
    \\Disallow: /private/
    \\Allow: /private/press-kit
    \\Disallow: /*.pdf$
    \\Allow: /drafts/public/
    \\Disallow: /drafts/
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var robots = try robotstxt.parse(gpa, sample, .{});
    defer robots.deinit();

    const paths = [_][]const u8{
        "/private/page",
        "/private/press-kit/logo.png",
        "/reports/2026.pdf",
        "/reports/2026.pdf?download=1",
        "/drafts/public/notes",
        "/about",
        "/robots.txt",
    };
    var diag: robotstxt.Diagnostics = .{};
    for (paths) |path| {
        const rule = robotstxt.matchingRule(gpa, &robots, "NowhereToBeBot", path, &diag) catch |err| {
            std.debug.print("{s}: {s}\n", .{ @errorName(err), diag.code });
            return err;
        };
        if (rule) |r| {
            std.debug.print("{s}: {s} by line {d}, \"{s}: {s}\"\n", .{
                path,
                if (r.allow) "allowed" else "disallowed",
                r.line,
                if (r.allow) "Allow" else "Disallow",
                r.pattern,
            });
        } else std.debug.print("{s}: allowed, no rule applies\n", .{path});
    }
}
