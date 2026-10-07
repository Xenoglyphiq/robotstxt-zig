# robots.txt — Decisions

Spec-level decisions. Newest at the bottom. Status is **Accepted** unless noted. "Google" means `google/robotstxt` and its `robots_test.cc`; "protego" means the oracle, Python `protego` 0.7.0. Their behavior below was tested on 2026-10-06.

### D-001 — A group's token is the user-agent value's `[A-Za-z_-]` prefix
**Status:** Proposed
**Decision:** A `user-agent` value of `*`, or `*` followed by a space or tab, names the global group. Any other value names the token made of its longest prefix of `A-Z a-z _ -`, so `FooBot/2.1` is `FooBot` and `FOO BAR` is `FOO`. A crawler matches a group when the tokens are equal, ignoring ASCII case. `foo` doesn't match `foobar`.
**Why:** RFC 9309 §2.2.1: crawlers find "the group that matches the product token". Product tokens are `[A-Za-z_-]+` and the rest of a user-agent line is commonly version or comment text. Google does exactly this (`ExtractUserAgent`, `ID_UserAgentValueCaseInsensitive`).
**Oracle:** protego compares whole values and matches substrings, so it ignores `FooBot/2.1` for `FooBot` and applies `foo` to `foobar`. Those cases are spec-sourced.
**Affects:** spec §3.2, A1–A3; all ports.

### D-002 — Only the crawler's groups apply; the global group is a fallback
**Status:** Proposed
**Decision:** Every group whose token matches the crawler is merged, and only those groups' rules apply, even when none of them matches the path. The global groups apply only when no group names the crawler.
**Why:** RFC 9309 §2.2.1, and Google (`ID_GlobalGroups_Secondary`, `ID_LineSyntax_Groups`). Falling through to `*` when the crawler's own group has no matching rule is the most common bug in existing parsers (Swift's CanProceed does it).
**Affects:** spec §3.2.

### D-003 — The crawler's user agent and the path are checked
**Status:** Proposed
**Decision:** `user_agent` must be a product token, `[A-Za-z_-]+`; otherwise `robotstxt.invalid_user_agent`. `path` must start with `/`; otherwise `robotstxt.invalid_path`. The path includes the query; a fragment (from `#`) is ignored.
**Why:** A full user-agent string (`Mozilla/5.0 (compatible; FooBot/2.1)`) silently matching nothing is a worse failure than an error. Google rejects the same strings (`ID_VerifyValidUserAgentsToObey`). Robots rules are written against path and query, so the API takes exactly that; parsing URLs is the caller's job.
**Affects:** spec §3.2, §3.3.

### D-004 — Patterns and paths get the same percent-encoding normalization
**Status:** Proposed
**Decision:** Before comparing, both the path and every pattern are normalized: `%XX` of an unreserved character is decoded, other `%XX` keep their bytes with upper-case hex, and control bytes, space, `0x7F` and non-ASCII bytes are percent-encoded. So `/%7Euser` equals `/~user`, and a raw UTF-8 path matches a rule written either raw or encoded.
**Why:** RFC 9309 §2.2.2 says non-ASCII octets "MUST be percent-encoded" and percent-encoded unreserved octets "MUST be unencoded prior to comparison". Applying one normalization to both sides is the reading that makes equivalent URLs compare equal however either side is written.
**Differs from Google:** Google encodes non-ASCII only in patterns, and doesn't decode unreserved `%XX`, so its `ID_Encoding` test expects a raw `ツ` path and `/foo/bar/baz` not to match encoded rules. Its own comment there says the unreserved case "should not be relied on". Those three translated cases use our answer.
**Invalid UTF-8 in a pattern** is matched by its original bytes (so `/caf\xE9` matches the path `/caf%E9`), never by the U+FFFD it's reported with.
**Oracle:** protego agrees on every encoding case except that last one: it decodes the file as text first, so it matches the replacement character (spec-sourced case `encoding.invalid_utf8_rule_not_fffd`).
**Affects:** spec §2, §3.3, A6, A9.

### D-005 — Past `max_bytes`, input is ignored and a cut line is dropped
**Status:** Proposed
**Decision:** Only the first `max_bytes` bytes (default 512,000) are parsed, and `truncated` is set. If the limit falls inside a line, that partial line is dropped. Never an error.
**Why:** RFC 9309 §2.5 requires parsing at least 500 KiB and allows ignoring the rest. Half a line can turn `Disallow: /private` into `Disallow: /`; dropping it keeps the file's meaning a strict prefix of the original.
**Affects:** spec §3.1, §5.

### D-006 — A missing colon is accepted when the line is exactly two words
**Status:** Proposed
**Decision:** A line with no `:` that is exactly two space- or tab-separated words is read as key and value (`disallow /`). Other colon-less lines are ignored.
**Why:** Google accepts it in an RFC-labelled test (`ID_LineSyntax_Line`), protego accepts it too, and the two-word condition keeps prose lines from being misread.
**Affects:** spec §3.1.

### D-007 — Too many redirects, or none to follow, means "unavailable"
**Status:** Proposed
**Decision:** `fetch` follows up to `max_redirects` (5) redirects. One more, or a 3xx without `Location`, means the file is unavailable: `allow_all`.
**Why:** RFC 9309 §2.3.1.2 says crawlers MAY assume the file is unavailable after five redirects, and §2.3.1.3 says an unavailable file lets crawlers access anything. A redirect with nowhere to go is the same situation.
**Affects:** spec §3.6.

### D-008 — 429, and statuses outside 200–599, mean "unreachable"
**Status:** Proposed
**Decision:** HTTP 429 is `disallow_all`, as are statuses below 200 or above 599. Other 4xx statuses are `allow_all`.
**Why:** RFC 9309 says 4xx means unavailable and crawlers MAY access anything; MAY leaves room to be more careful, and a server that is rate-limiting the crawler is the one case where crawling everything is clearly wrong. Google treats 429 as a server error for the same reason. Statuses that aren't final responses mean nothing usable arrived.
**Affects:** spec §3.5, A8.

### D-009 — What ends a group's agent list
**Status:** Proposed
**Decision:** `allow`, `disallow` (even with an empty value) and `crawl-delay` end the run of `user-agent` lines; the next `user-agent` line starts a new group. `sitemap` lines and unknown keys don't.
**Why:** RFC 9309 §2.1 and Google's `ID_LineSyntax_Groups_OtherRules`: a group must not be closed by lines the RFC doesn't define. `crawl-delay` is a group member in every parser that supports it, and without this `User-agent: *` / `Crawl-delay: 10` / blank line / `User-agent: FooBot` would put `*` and `FooBot` in one group.
**Differs:** protego also ends the list on unknown keys (spec-sourced case `groups.unknown_does_not_close`). Google ignores `crawl-delay`, so it doesn't end the list there.
**Affects:** spec §3.1, A4, A5.

### D-010 — Oracle, Google's tests, and what isn't adopted
**Status:** Proposed
**Decision:** protego 0.7.0 is the executable oracle; the generator cross-checks every `is_allowed`, sitemap and crawl-delay case against it, and stops on any disagreement that isn't a recorded decision. Google's RFC-labelled tests (`ID_*`) are translated into fixtures and their expectations checked against ours. Google-only behavior (`GoogleOnly_*`: typo tolerance such as `dissallow`, `index.html` treated as `/`, its line-length limit) is not adopted.
**Why:** protego is maintained and close to RFC 9309, but has no error codes and differs on agent selection. Google's tests are the closest thing to an RFC test suite. Typo tolerance is a product choice of one crawler, not the protocol.
**Affects:** `conformance/`, spec §4, §6, `NOTICE`.
