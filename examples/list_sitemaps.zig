//! Canonical example `list_sitemaps`: parse a sample robots.txt and print its
//! sitemap URLs in file order.
const std = @import("std");
const robotstxt = @import("robotstxt");

const sample =
    \\Sitemap: https://www.example.com/sitemap.xml
    \\
    \\User-agent: *
    \\Disallow: /private/
    \\Sitemap: https://www.example.com/news/sitemap.xml
    \\
    \\User-agent: NowhereToBeBot
    \\Disallow: /
    \\
    \\# Sitemap lines belong to no group, wherever they appear.
    \\sitemap: https://cdn.example.com/sitemaps/products.xml
    \\
;

pub fn main(init: std.process.Init) !void {
    var robots = try robotstxt.parse(init.gpa, sample, .{});
    defer robots.deinit();
    for (robots.sitemaps) |url| std.debug.print("{s}\n", .{url});
}
