//! Benchmark: the spec's method (`.spec/bench/README.md`). One pass = for
//! each block of consecutive `paths.txt` lines with the same crawler, in file
//! order: `parse` `robots.txt`, then `isAllowed` for each of the block's
//! paths, summing the 1-based line numbers of the allowed ones. The sum is
//! the checksum every port must reproduce. 3 warm-up passes, then 15 timed
//! passes; reports median and min ms per pass.
//!
//! Usage: `zig build bench [-- <dir>]`, where `<dir>` holds both files
//! (default `.spec/bench`). Always built ReleaseFast.

const std = @import("std");
const Io = std.Io;
const robotstxt = @import("robotstxt");

const warmup = 3;
const runs = 15;

const expected_checksum = 24_281_055;

fn elapsedMs(io: Io, start: Io.Timestamp) f64 {
    const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// One `paths.txt` line.
const Lookup = struct { line: u64, user_agent: []const u8, path: []const u8 };

/// Consecutive lookups for one crawler.
const Block = []const Lookup;

/// One pass over every block. Returns the checksum.
fn pass(gpa: std.mem.Allocator, robots_txt: []const u8, blocks: []const Block) !u64 {
    var sum: u64 = 0;
    for (blocks) |block| {
        var robots = try robotstxt.parse(gpa, robots_txt, .{});
        defer robots.deinit();
        for (block) |l| {
            if (try robotstxt.isAllowed(gpa, &robots, l.user_agent, l.path, null)) sum += l.line;
        }
    }
    return sum;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const dir_path = if (args.len > 1) args[1] else ".spec/bench";
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    const robots_txt = try dir.readFileAlloc(io, "robots.txt", arena, .limited(16 * 1024 * 1024));
    const paths_text = try dir.readFileAlloc(io, "paths.txt", arena, .limited(16 * 1024 * 1024));

    var lookups: std.ArrayList(Lookup) = .empty;
    var lines = std.mem.splitScalar(u8, paths_text, '\n');
    var line_no: u64 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const space = std.mem.findScalar(u8, line, ' ') orelse return error.BadLine;
        try lookups.append(arena, .{ .line = line_no, .user_agent = line[0..space], .path = line[space + 1 ..] });
    }
    var blocks: std.ArrayList(Block) = .empty;
    var start: usize = 0;
    for (lookups.items, 0..) |l, i| {
        const last = i + 1 == lookups.items.len or !std.mem.eql(u8, lookups.items[i + 1].user_agent, l.user_agent);
        if (last) {
            try blocks.append(arena, lookups.items[start .. i + 1]);
            start = i + 1;
        }
    }

    var samples: [runs]f64 = undefined;
    for (0..warmup + runs) |i| {
        const t0 = Io.Timestamp.now(io, .awake);
        const sum = try pass(gpa, robots_txt, blocks.items);
        const ms = elapsedMs(io, t0);
        if (sum != expected_checksum) {
            std.debug.print("checksum {d}, expected {d}\n", .{ sum, @as(u64, expected_checksum) });
            return error.WrongChecksum;
        }
        if (i >= warmup) samples[i - warmup] = ms;
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    std.debug.print("robotstxt zig ReleaseFast: {d} blocks, parse + is_allowed x {d}: median {d:.3} ms (min {d:.3}) per pass, checksum {d} ok\n", .{
        blocks.items.len,
        lookups.items.len,
        samples[runs / 2],
        samples[0],
        @as(u64, expected_checksum),
    });
}
