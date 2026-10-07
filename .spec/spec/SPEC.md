# robots.txt — Spec

> Capability id: `robotstxt` · Spec version: `0.1.0` · Status: draft
> Implements [RFC 9309](https://www.rfc-editor.org/rfc/rfc9309.html), the Robots Exclusion Protocol. Where the RFC is loose, Google's open-source parser ([`google/robotstxt`](https://github.com/google/robotstxt)) breaks the tie, and every place we differ from it is recorded in `DECISIONS.md`.

## 1. Scope

- **In:** parsing a robots.txt file; deciding whether a crawler may fetch a path, and which rule decided; sitemap URLs; what an HTTP status means for the file; fetching it (io).
- **Extension (not RFC 9309):** `Crawl-delay`, kept apart and marked as an extension wherever it appears.
- **Out:** sitemap parsing, URL parsing beyond the path (callers pass the path), caching, politeness scheduling.

## 2. Types

| Type | Fields |
|---|---|
| `RobotsFile` | `groups: list<Group>`, `sitemaps: list<string>` (file order), `truncated: bool` |
| `Group` | `user_agents: list<string>` (values as written, trimmed), `rules: list<Rule>`, `crawl_delay: optional<f64>` (extension) |
| `Rule` | `allow: bool`, `pattern: string` (as written, trimmed), `line: u32` (1-based) |
| `StatusPolicy` | `parse`, `follow_redirect`, `allow_all`, `disallow_all` |
| `Fetched` | `policy: parsed \| allow_all \| disallow_all`, `status: optional<u32>`, `robots: optional<RobotsFile>` |

Values reported back (user agents, patterns, sitemaps) are UTF-8 text; bytes that aren't valid UTF-8 are replaced with U+FFFD in what's reported. Matching works on the original bytes (§3.3).

## 3. Operations

### 3.1 `parse(data: bytes) -> RobotsFile` (core)

Lenient: **never fails**. In order:

1. **Size limit.** If `data` is longer than `max_bytes`, keep the first `max_bytes` bytes, set `truncated`, and drop the last line if the limit cut it (its bytes after the last line terminator) (D-005).
2. **Byte order mark.** If the data starts with the UTF-8 BOM `EF BB BF`, or a prefix of it (`EF BB`, `EF`), skip those bytes.
3. **Lines.** A line ends at `\r\n`, `\n` or a lone `\r`; a final line without a terminator still counts. Lines are numbered from 1, blank and comment lines included.
4. **Each line:**
   1. Everything from the first `#` is a comment and is removed.
   2. Trim spaces and tabs at both ends. An empty line is skipped.
   3. Split at the first `:` into key and value. With no `:`, a line of **exactly two** space- or tab-separated words is read as key and value (D-006); any other line is skipped.
   4. Trim both. An empty key skips the line. Keys compare **case-insensitively** (ASCII).
5. **Records** (by key). The parser tracks a current group and whether its **agent list is open**:
   - `user-agent`: if there's no current group or its agent list is closed, start a new group with an open agent list. Add the value to the current group's `user_agents`.
   - `allow`, `disallow`: ignored before the first `user-agent` line. Otherwise **close** the agent list, and a non-empty value adds a `Rule` to the current group. An empty value adds no rule but still closes the list.
   - `crawl-delay` (extension): ignored before the first `user-agent` line. Otherwise it closes the agent list like a rule (D-009). The group keeps the **first** value that is a non-negative decimal (`[0-9]+(\.[0-9]+)?`), as `f64` seconds; others are skipped.
   - `sitemap`: a non-empty value is appended to `sitemaps`. Not part of any group, and the agent list stays as it is.
   - Any other key: ignored, and the agent list stays as it is (D-009).

Groups that name the same user agent are **not** merged at parse time; they stay in file order. Merging happens when matching (§3.2).

### 3.2 Choosing the groups for a crawler

The crawler identifies itself with a **product token**: one or more of `A-Z a-z _ -` (D-003). Anything else is `robotstxt.invalid_user_agent`.

Each `user-agent` value names a group token (D-001):
- `*` alone, or `*` followed by a space or tab, is the **global** token.
- Otherwise the token is the value's longest prefix of `A-Z a-z _ -` characters. `FooBot/2.1` → `FooBot`; `Foo Bar` → `Foo`; `*bot` → empty, which matches nothing.

The crawler's groups are **every** group with a token equal to the crawler's, ignoring ASCII case, merged into one rule set. Only if there are none, the groups with the global token are used, merged. If there are neither, no rules apply (D-002).

### 3.3 `is_allowed(robots, user_agent, path) -> bool` and `matching_rule(...) -> optional<Rule>` (core)

`path` must start with `/` (else `robotstxt.invalid_path`). It includes the query string; anything from `#` (a fragment) is ignored (D-003). Errors are checked in argument order: `user_agent`, then `path`.

1. If the path, up to any `?`, is exactly `/robots.txt`, it is allowed and no rule decides (RFC 9309 §2.2.2).
2. **Normalize** the path and every pattern the same way (D-004), byte by byte:
   - `%` followed by two hex digits: if the byte it encodes is unreserved (`A-Z a-z 0-9 - . _ ~`), replace the three bytes with that character; otherwise keep it, with the hex digits upper-cased.
   - Bytes `0x00`–`0x20`, `0x7F` and `0x80`–`0xFF` become `%XX` (upper-case hex). Non-ASCII text is therefore compared as its UTF-8 percent-encoding.
   - Everything else is kept as is (reserved characters such as `?`, `&`, `=`, `/` are not encoded).
3. A normalized pattern **matches** if it matches a **prefix** of the normalized path, where `*` matches any run of bytes (including none), and `$` as the pattern's **last** byte means the match must reach the end of the path. `$` anywhere else is a literal.
4. Among the crawler's rules (§3.2) that match, the **longest normalized pattern** (in bytes, counting `*` and `$`) wins. On equal length, `allow` beats `disallow`; between rules of the same kind and length, the first in the file wins (RFC 9309 §2.2.2).
5. `matching_rule` returns that rule, or absent if none matched (or for `/robots.txt`). `is_allowed` is `true` when there's no rule or the rule is `allow`.

Matching is case-sensitive.

### 3.4 `crawl_delay(robots, user_agent) -> optional<f64>` (core, extension)

The crawler's groups (§3.2), in file order: the first group that has a `crawl_delay` gives it. Absent if none. Not part of RFC 9309.

### 3.5 `status_policy(http_status: u32) -> StatusPolicy` (core)

| Status | Policy | Why |
|---|---|---|
| 200–299 | `parse` | RFC 9309 §2.3.1.1 |
| 300–399 | `follow_redirect` | §2.3.1.2 (`fetch` follows it) |
| 400–499 except 429 | `allow_all` | "Unavailable", §2.3.1.3: crawlers MAY access anything |
| 429 | `disallow_all` | Rate limited: treated as unreachable (D-008) |
| 500–599 | `disallow_all` | "Unreachable", §2.3.1.4 |
| anything else | `disallow_all` | Not a final status: unreachable (D-008) |

### 3.6 `fetch(origin: string) -> Fetched` (io)

`origin` is `http://` or `https://` followed by an authority (host and optional port) and at most a trailing `/`: no path, query or fragment. Anything else is `robotstxt.invalid_origin`, the only error `fetch` raises; a failed fetch is a policy, not an error.

1. Request `origin + /robots.txt` (one `/`).
2. No response (connection, TLS or timeout failure) → `disallow_all`, status absent.
3. Apply `status_policy` to the status:
   - `follow_redirect`: resolve `Location` against the current URL and request it. Up to `max_redirects` redirects are followed. One more redirect, or a redirect with no `Location`, means the file is **unavailable** → `allow_all` (D-007).
   - `parse`: read the body (no more than `max_bytes + 1` bytes need be read), `parse` it → `parsed`.
   - `allow_all` / `disallow_all`: that policy, with the status.

`fetch` uses a **transport**: something that, given a URL, returns a status, the `Location` header and the body, or reports that there was no response. Ports provide an HTTP transport and let callers pass their own. The conformance runner passes a scripted one (§6).

## 4. Ambiguities and differences

| # | Question | Our answer | `protego` 0.7.0 (oracle) | Google `robotstxt` |
|---|---|---|---|---|
| A1 | Group token of `FooBot/2.1`, `FOO BAR` | Prefix of `[A-Za-z_-]` (D-001) | Whole value | Same as ours |
| A2 | `foo` vs crawler `foobar` | No match: tokens must be equal | Matches (substring) | Same as ours |
| A3 | `* something` | Global | Not global | Same as ours |
| A4 | Unknown line between `user-agent` lines | Doesn't end the agent list (D-009) | Ends it | Same as ours |
| A5 | `Crawl-delay` between `user-agent` lines | Ends the agent list (D-009) | Same as ours | Ignores the line |
| A6 | `%7E` vs `~`, raw UTF-8 vs `%E3%83%84` | Equal after normalization (D-004) | Same as ours | Compares bytes: not equal |
| A7 | Missing colon (`disallow /`) | Accepted when exactly two words (D-006) | Same as ours | Same as ours |
| A8 | HTTP 429 | `disallow_all` (D-008) | n/a | Same as ours |

Google behavior marked "GoogleOnly" in its tests (accepting typos such as `dissallow`, treating `index.html` as `/`, its line-length cap) is **not** part of this spec.

## 5. Limits

| Limit | Default | Why |
|---|---|---|
| `max_bytes` | 512,000 | RFC 9309 §2.5: crawlers must parse at least 500 KiB. Beyond it, input is ignored and `truncated` is set; never an error. |
| `max_redirects` | 5 | RFC 9309 §2.3.1.2: follow at least five redirects. |

## 6. Conformance

- Oracle: Python `protego==0.7.0`, for valid input. Every `is_allowed`, `sitemaps` and `crawl_delay` result is cross-checked against it, and the generator stops on any disagreement that isn't a recorded decision (A1–A4).
- Cases translated from Google's `robots_test.cc` (its RFC tests, prefixed `ID_`) keep the test name in their description; see `NOTICE`.
- Levels: `core` (parse, matching, crawl-delay, status policy) and `io` (`fetch`); `full` is both.
- **Inputs.** A robots.txt file is `input.value` (a string) or `input.base64` (raw bytes, for BOMs and invalid UTF-8). `is_allowed` and `matching_rule` take `args.user_agent` and `args.path`; `crawl_delay` takes `args.user_agent`. `options.max_bytes` overrides the limit.
- **`parse` output** is the `RobotsFile` as canonical JSON: `{"groups": [{"user_agents": [...], "rules": [{"allow", "pattern", "line"}], "crawl_delay"}], "sitemaps": [...], "truncated"}`, compared with `json_equal`.
- **`fetch` cases** give `input.value = {"origin", "responses"}`, where `responses` maps each URL to `{"status", "location"?, "body_base64"?}` or `{"error": "network"}`. A URL not listed has no response. The runner passes `fetch` a transport that answers from this map. The expected value is the `Fetched` as JSON (`policy`, `status`, `robots`).

## 7. The three canonical examples

1. **check_path:** parse a sample file and print whether `NowhereToBeBot` may fetch `/private/page`.
2. **list_sitemaps:** parse a sample file and print its sitemap URLs in order.
3. **explain_decision:** print the rule (`allow`/`disallow`, pattern, line) that decides a path, or that none does.

## 8. Performance target

Within 2× of a compiled Google-compatible reference, measured with the shared method once the bench input is pinned (planned for 0.1.x, as for PMTiles).

## 9. Security notes

robots.txt files are untrusted input.
- Input beyond `max_bytes` is never read, and parsing never fails.
- Matching must not backtrack exponentially: a pattern with many `*` against a long path stays linear in the path per `*` (greedy left-to-right search for each literal piece, as in §3.3).
- `fetch` follows at most `max_redirects` redirects and reads at most `max_bytes + 1` bytes of body.

Design decisions are in `DECISIONS.md`.
