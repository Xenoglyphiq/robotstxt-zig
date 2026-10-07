//! Canonical example `check_path`: parse a sample robots.txt and print
//! whether `NowhereToBeBot` may fetch `/private/page`.
const std = @import("std");
const robotstxt = @import("robotstxt");

const sample =
    \\# Sample robots.txt
    \\User-agent: *
    \\Disallow: /private/
    \\Allow: /private/press-kit
    \\Crawl-delay: 2
    \\
    \\User-agent: NowhereToBeBot
    \\User-agent: OtherBot/1.0
    \\Disallow: /private/
    \\Disallow: /drafts/*.html$
    \\Allow: /drafts/public/
    \\
    \\Sitemap: https://www.example.com/sitemap.xml
    \\Sitemap: https://www.example.com/news/sitemap.xml
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var robots = try robotstxt.parse(gpa, sample, .{});
    defer robots.deinit();

    var diag: robotstxt.Diagnostics = .{};
    const allowed = robotstxt.isAllowed(gpa, &robots, "NowhereToBeBot", "/private/page", &diag) catch |err| {
        std.debug.print("{s}: {s}\n", .{ @errorName(err), diag.code });
        return err;
    };
    std.debug.print("NowhereToBeBot {s} fetch /private/page\n", .{if (allowed) "may" else "may not"});
}
