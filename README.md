# robots.txt for Zig

Parse robots.txt files and decide whether a crawler may fetch a path, which rule decided, and what an HTTP status for the file means; fetch an origin's `/robots.txt` over HTTP or any transport you plug in. Implements RFC 9309 · Spec v0.1.2 · Conformance: **core ✓ io ✓ full ✓** (130/130)

> **`Crawl-delay` is an extension, not RFC 9309.** It's parsed and returned by `crawlDelay`, kept apart from the rules, and never affects `isAllowed`. A group keeps its first value that is a non-negative decimal and finite as an `f64`.

Requires Zig **0.17.0**. Standard library only: HTTP is `std.http.Client`.

## Install

**Not released yet.** Until the first release, fetch the default branch:

```
zig fetch --save git+https://github.com/Xenoglyphiq/robotstxt-zig
```

Then in `build.zig`:

```zig
const robotstxt = b.dependency("robotstxt", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("robotstxt", robotstxt.module("robotstxt"));
exe.root_module.addImport("robotstxt_io", robotstxt.module("robotstxt_io"));
```

## Quick start

```zig
const robotstxt = @import("robotstxt");
const robotstxt_io = @import("robotstxt_io");

var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
var http: robotstxt_io.HttpTransport = .{ .client = &client, .user_agent = "FooBot/1.0" };

var fetched = try robotstxt_io.fetch(gpa, http.transport(), "https://example.com", .{}, null);
defer fetched.deinit();
const allowed = switch (fetched.policy) {
    .parsed => try robotstxt.isAllowed(gpa, &fetched.robots.?, "FooBot", "/private/page?x=1", null),
    .allow_all => true,
    .disallow_all => false,
};
```

Or parse bytes you already have:

```zig
var robots = try robotstxt.parse(gpa, bytes, .{});
defer robots.deinit();
if (try robotstxt.matchingRule(gpa, &robots, "FooBot", "/private/page", null)) |rule| {
    // rule.allow, rule.pattern, rule.line
}
```

Every allocating call takes the allocator first. A `RobotsFile` owns its strings; call `deinit` when done.

## Examples

Run all three with `zig build examples`. Each parses a sample robots.txt embedded in the example.

### 1. Check one path (`examples/check_path.zig`)
```zig
var robots = try robotstxt.parse(gpa, sample, .{});
defer robots.deinit();
const allowed = try robotstxt.isAllowed(gpa, &robots, "NowhereToBeBot", "/private/page", &diag);
std.debug.print("NowhereToBeBot {s} fetch /private/page\n", .{if (allowed) "may" else "may not"});
```

### 2. List the sitemaps (`examples/list_sitemaps.zig`)
```zig
var robots = try robotstxt.parse(gpa, sample, .{});
defer robots.deinit();
for (robots.sitemaps) |url| std.debug.print("{s}\n", .{url});
```

### 3. Explain a decision (`examples/explain_decision.zig`)
```zig
if (try robotstxt.matchingRule(gpa, &robots, "NowhereToBeBot", path, &diag)) |r| {
    std.debug.print("{s}: {s} by line {d}, \"{s}\"\n", .{ path, if (r.allow) "allowed" else "disallowed", r.line, r.pattern });
} else std.debug.print("{s}: allowed, no rule applies\n", .{path});
```

## API

| Function | Spec operation | Module |
|---|---|---|
| `parse(gpa, bytes, opts) Allocator.Error!RobotsFile` (never fails otherwise) | `parse` | `robotstxt` |
| `isAllowed(gpa, robots, user_agent, path, diag) Error!bool` | `is_allowed` | `robotstxt` |
| `matchingRule(gpa, robots, user_agent, path, diag) Error!?Rule` | `matching_rule` | `robotstxt` |
| `crawlDelay(robots, user_agent, diag) Error!?f64` (extension) | `crawl_delay` | `robotstxt` |
| `statusPolicy(http_status) StatusPolicy` | `status_policy` | `robotstxt` |
| `fetch(gpa, transport, origin, opts, diag) Error!Fetched` | `fetch` | `robotstxt_io` |

`RobotsFile`, `Group` and `Rule` use the spec's snake_case field names. Groups stay in file order and aren't merged; `isAllowed`, `matchingRule` and `crawlDelay` merge every group whose token equals the crawler's, and fall back to the `*` groups only when none does. `Rule.normalized` is this port's addition: the pattern percent-encoding normalized, which is what matching compares.

`user_agent` is the crawler's product token (`[A-Za-z_-]+`, such as `FooBot`), not a full `User-Agent` header. `path` starts with `/` and includes the query; a fragment is ignored. `/robots.txt` is always allowed. `gpa` is only used for paths whose normalized form is over 1 KiB.

User agents, patterns and sitemaps are reported as UTF-8, with invalid bytes replaced by U+FFFD; matching uses the original bytes.

### Transports

`fetch` requests `origin/robots.txt`, follows redirects itself, applies `statusPolicy`, and parses a 2xx body. `Fetched.policy` is `parsed`, `allow_all` or `disallow_all`, with the final `status` (null when there was no response).

| Transport | Backed by |
|---|---|
| `HttpTransport{ .client, .user_agent }` | `std.http.Client`. No automatic redirects; sends `Accept-Encoding: identity` and still decodes a gzip, deflate or zstd body; reads at most `max_bytes + 1` body bytes |
| your own | any `Transport{ .ptr, .vtable }` whose `get(ptr, gpa, url, max_body)` returns `{ status, location, body }` or `error.NoResponse` |

No response (connection or TLS failure) is `disallow_all`. Redirects resolve `Location` against the current URL (RFC 3986: dot segments removed, fragment dropped). One redirect past `max_redirects`, or a redirect without `Location` (or an empty one), is `allow_all`: the file is unavailable. A redirect to a URL that isn't `http` or `https` gets no response, so it's `disallow_all`. `std.http.Client` has no timeouts, so neither does `HttpTransport`; a transport of your own can add them.

## Limits and errors

| Limit | Default | Option name |
|---|---|---|
| Bytes of robots.txt parsed | 512,000 | `Options.max_bytes` |
| Redirects followed by `fetch` | 5 | `Options.max_redirects` |

Past `max_bytes`, the rest of the input is ignored, a line the limit cut is dropped, and `RobotsFile.truncated` is set. Never an error.

Errors are the error set `robotstxt.Error`, whose names are the spec's kinds: `InvalidInput` (plus Zig's `OutOfMemory`). Pass a `*robotstxt.Diagnostics` to get the stable `code`:

| Code | When |
|---|---|
| `robotstxt.invalid_user_agent` | `user_agent` is empty or has characters outside `[A-Za-z_-]` (checked first) |
| `robotstxt.invalid_path` | `path` doesn't start with `/` |
| `robotstxt.invalid_origin` | `fetch`'s origin isn't `http://` or `https://`, a host and optional port (no userinfo), and at most a trailing `/` |

`parse` never fails. A failed fetch is a policy, not an error.

Matching never backtracks: each literal piece between `*`s is found greedily, left to right, so a pattern with many `*` against a long path stays linear in the path per `*`.

## Modules

| Module | Layer | Needs |
|---|---|---|
| `robotstxt` | core | nothing beyond the standard library; no I/O |
| `robotstxt_io` | io | `std.http.Client` for `HttpTransport` |

`robotstxt_io` re-exports `Error`, `Diagnostics`, `Options`, `RobotsFile` and `StatusPolicy`.

## Development

| Command | What |
|---|---|
| `zig build test` | Unit tests |
| `zig build test --fuzz=10M` | Fuzz `parse`, `isAllowed` and `matchingRule` on generated robots.txt files and paths, checking the matcher against a reference one |
| `zig build conformance [-- <manifest.json>]` | Every case in `.spec/conformance/manifest.json`, or the manifest given (`fetch` cases through a scripted transport) |
| `zig build examples` | The three canonical examples |
| `zig build bench [-- <dir>]` | `parse` and `isAllowed` timings on `.spec/bench/` (always ReleaseFast) |

## Performance

| Benchmark | Reference | This port | Ratio |
|---|---|---|---|
| `parse` + `isAllowed` pass | Rust `texting_robots` 0.2.2: 13.10 ms | 14.26 ms | 1.09× |

One pass parses the 79,936-byte `bench/robots.txt` once per crawler (10 times) and checks 10,000 paths; method in `.spec/bench/README.md`. Recorded 2026-10-06 on an Apple M5 Pro, interleaved with the reference in one session (median of three rounds); checksum 24281055 reproduced every pass. Zig 0.17.0, ReleaseFast.

## License

MIT OR Apache-2.0. Some conformance cases in `.spec/` are translated from Google's `robotstxt` tests (Apache-2.0); see `.spec/NOTICE`.
