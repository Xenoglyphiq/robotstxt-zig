# /// script
# requires-python = ">=3.10"
# dependencies = ["protego==0.7.0"]
# ///
"""Generate conformance/manifest.json for the robots.txt spec.

Every case is computed by a transcription of spec/SPEC.md §3 (the `spec_*` functions
below), then cross-checked against the oracle, Python `protego` 0.7.0, wherever the
oracle has an opinion:

- `is_allowed` cases: protego's `can_fetch` must agree, unless the case is listed in
  ORACLE_DIFFERS with the decision that explains why (agent selection, D-001; encoding
  of characters outside US-ASCII, D-004). Any other disagreement stops the generator.
- `sitemaps` and `crawl_delay` cases are cross-checked the same way.

Cases translated from Google's `robots_test.cc` (Apache-2.0, see NOTICE) keep the
Google test name in their description. Run from the repo root:

    uv run conformance/generate/generate.py
"""

from __future__ import annotations

import base64
import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path

from protego import Protego

ORACLE = {"language": "python", "package": "protego", "version": "0.7.0", "script": "generate/generate.py"}
SPEC_VERSION = "0.1.2"
GENERATED_AT = "2026-10-06T00:00:00Z"  # bump by hand when cases change
ROOT = Path(__file__).resolve().parents[1]

MAX_BYTES = 512_000
MAX_REDIRECTS = 5

KIND = {
    "robotstxt.invalid_user_agent": "invalid_input",
    "robotstxt.invalid_path": "invalid_input",
    "robotstxt.invalid_origin": "invalid_input",
}


class SpecError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


# ---------------------------------------------------------------------------
# Spec transcription: parse (spec §3 `parse`)
# ---------------------------------------------------------------------------

@dataclass
class Rule:
    allow: bool
    pattern: str  # as written, trimmed; invalid UTF-8 replaced with U+FFFD
    line: int
    raw: bytes = b""  # the pattern's original bytes, which matching uses (spec §2)

    def json(self):
        return {"allow": self.allow, "pattern": self.pattern, "line": self.line}


@dataclass
class Group:
    user_agents: list[str] = field(default_factory=list)
    rules: list[Rule] = field(default_factory=list)
    crawl_delay: float | None = None

    def json(self):
        return {"user_agents": self.user_agents, "rules": [r.json() for r in self.rules],
                "crawl_delay": self.crawl_delay}


@dataclass
class RobotsFile:
    groups: list[Group]
    sitemaps: list[str]
    truncated: bool

    def json(self):
        return {"groups": [g.json() for g in self.groups], "sitemaps": self.sitemaps, "truncated": self.truncated}


WS = " \t"
TOKEN = re.compile(r"[A-Za-z_-]*")
DELAY = re.compile(r"[0-9]+(\.[0-9]+)?")


def split_lines(data: bytes) -> list[bytes]:
    """Lines end at \\r\\n, \\n or a lone \\r; a final line without a terminator counts."""
    lines, start, i = [], 0, 0
    while i < len(data):
        if data[i] in (0x0A, 0x0D):
            lines.append(data[start:i])
            i += 2 if data[i] == 0x0D and i + 1 < len(data) and data[i + 1] == 0x0A else 1
            start = i
        else:
            i += 1
    if start < len(data):
        lines.append(data[start:])
    return lines


def key_value(line: bytes) -> tuple[bytes, bytes] | None:
    """Comment stripped, then `key: value`; or `key value` when the line is exactly two words (D-006)."""
    line = line.split(b"#", 1)[0].strip(b" \t")
    if not line:
        return None
    if b":" in line:
        key, value = line.split(b":", 1)
    else:
        parts = re.split(rb"[ \t]+", line)
        if len(parts) != 2:
            return None
        key, value = parts
    key = key.strip(b" \t")
    if not key:
        return None
    return key.lower(), value.strip(b" \t")


def text(b: bytes) -> str:
    """Values reported back (patterns, user agents, sitemaps) are UTF-8, invalid bytes replaced."""
    return b.decode("utf-8", errors="replace")


def spec_parse(data: bytes, max_bytes: int = MAX_BYTES) -> RobotsFile:
    truncated = len(data) > max_bytes
    if truncated:
        data = data[:max_bytes]
        # A line cut by the limit is dropped (D-005).
        if data and data[-1] not in (0x0A, 0x0D):
            cut = max(data.rfind(b"\n"), data.rfind(b"\r"))
            data = data[:cut + 1] if cut >= 0 else b""
    # A UTF-8 byte order mark, or any leading prefix of one, is skipped (Google's ID_ test).
    for bom in (b"\xef\xbb\xbf", b"\xef\xbb", b"\xef"):
        if data.startswith(bom):
            data = data[len(bom):]
            break

    groups: list[Group] = []
    sitemaps: list[str] = []
    current: Group | None = None
    collecting_agents = False  # true while consecutive user-agent lines build one group
    for n, raw in enumerate(split_lines(data), start=1):
        kv = key_value(raw)
        if kv is None:
            continue
        key, value = kv
        if key == b"user-agent":
            if not collecting_agents:
                current = Group()
                groups.append(current)
                collecting_agents = True
            current.user_agents.append(text(value))
        elif key in (b"allow", b"disallow"):
            if current is None:
                continue  # rules before any user-agent line are ignored
            collecting_agents = False  # allow/disallow (even empty) ends the agent list
            if value:
                current.rules.append(Rule(key == b"allow", text(value), n, value))
        elif key == b"sitemap":
            if value:
                sitemaps.append(text(value))
        elif key == b"crawl-delay":
            if current is None:
                continue
            collecting_agents = False  # a group member, like allow/disallow (D-009)
            if current.crawl_delay is None and DELAY.fullmatch(text(value)) and math.isfinite(float(value)):
                current.crawl_delay = float(value)  # a value too large for f64 is skipped
        # anything else is ignored and doesn't end the agent list
    return RobotsFile(groups, sitemaps, truncated)


# ---------------------------------------------------------------------------
# Spec transcription: matching (spec §3 `is_allowed`, `matching_rule`)
# ---------------------------------------------------------------------------

UNRESERVED = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
HEX = set(b"0123456789ABCDEFabcdef")


def normalize(b: bytes) -> bytes:
    """Percent-encoding normalization applied to patterns and paths alike (D-004)."""
    out = bytearray()
    i = 0
    while i < len(b):
        c = b[i]
        if c == 0x25 and i + 2 < len(b) and b[i + 1] in HEX and b[i + 2] in HEX:
            v = int(b[i + 1:i + 3], 16)
            if v in UNRESERVED:
                out.append(v)
            else:
                out += b"%" + b[i + 1:i + 3].upper()
            i += 3
        elif c <= 0x20 or c >= 0x7F:
            out += b"%%%02X" % c
            i += 1
        else:
            out.append(c)
            i += 1
    return bytes(out)


def pattern_matches(pattern: bytes, path: bytes) -> bool:
    """`*` matches any run of bytes; `$` anchors only as the last byte; otherwise a prefix match."""
    anchored = pattern.endswith(b"$")
    if anchored:
        pattern = pattern[:-1]
    parts = pattern.split(b"*")
    if not path.startswith(parts[0]):
        return False
    pos = len(parts[0])
    for j, part in enumerate(parts[1:], start=1):
        last = j == len(parts) - 1
        if last and anchored:
            return path.endswith(part) and len(path) - len(part) >= pos
        k = path.find(part, pos)
        if k < 0:
            return False
        pos = k + len(part)
    return not anchored or pos == len(path)


def check_user_agent(ua: str) -> str:
    if not ua or not TOKEN.fullmatch(ua):
        raise SpecError("robotstxt.invalid_user_agent")
    return ua.lower()


def check_path(path: str) -> bytes:
    if not path.startswith("/"):
        raise SpecError("robotstxt.invalid_path")
    return path.split("#", 1)[0].encode("utf-8")


def group_token(value: str) -> str | None:
    """`*` (alone or followed by whitespace) is the global group; otherwise the [A-Za-z_-] prefix (D-001)."""
    if value == "*" or (value.startswith("*") and value[1:2] in (" ", "\t")):
        return "*"
    return TOKEN.match(value).group(0).lower()


def selected_groups(robots: RobotsFile, ua: str) -> list[Group]:
    specific = [g for g in robots.groups if any(group_token(v) == ua for v in g.user_agents)]
    if specific:
        return specific
    return [g for g in robots.groups if any(group_token(v) == "*" for v in g.user_agents)]


def spec_matching_rule(robots: RobotsFile, ua: str, path: str) -> Rule | None:
    ua = check_user_agent(ua)
    raw = check_path(path)
    if raw.split(b"?", 1)[0] == b"/robots.txt":
        return None
    norm = normalize(raw)
    best: Rule | None = None
    best_len = -1
    for g in selected_groups(robots, ua):
        for r in g.rules:
            p = normalize(r.raw)
            if not pattern_matches(p, norm):
                continue
            if len(p) > best_len or (len(p) == best_len and r.allow and not best.allow):
                best, best_len = r, len(p)
    return best


def spec_is_allowed(robots: RobotsFile, ua: str, path: str) -> bool:
    r = spec_matching_rule(robots, ua, path)
    return r is None or r.allow


def spec_crawl_delay(robots: RobotsFile, ua: str) -> float | None:
    ua = check_user_agent(ua)
    for g in selected_groups(robots, ua):
        if g.crawl_delay is not None:
            return g.crawl_delay
    return None


def spec_status_policy(status: int) -> str:
    if 200 <= status <= 299:
        return "parse"
    if 300 <= status <= 399:
        return "follow_redirect"
    if 400 <= status <= 499 and status != 429:
        return "allow_all"
    return "disallow_all"  # 429, 5xx, and anything outside 200-599 (D-008)


# ---------------------------------------------------------------------------
# Spec transcription: fetch (io), over scripted responses
# ---------------------------------------------------------------------------

ORIGIN = re.compile(r"https?://[^/?#@\s]+/?")  # host and optional port: no userinfo (spec §3.6)


def resolve(base: str, location: str) -> str:
    if re.match(r"https?://", location):
        return location
    scheme_host = re.match(r"https?://[^/?#]+", base).group(0)
    if location.startswith("//"):
        return base.split(":", 1)[0] + ":" + location
    if location.startswith("/"):
        return scheme_host + location
    directory = base.split("?", 1)[0].rsplit("/", 1)[0]
    return directory + "/" + location


def spec_fetch(origin: str, responses: dict[str, dict]) -> dict:
    if not ORIGIN.fullmatch(origin):
        raise SpecError("robotstxt.invalid_origin")
    url = origin.rstrip("/") + "/robots.txt"
    redirects = 0
    while True:
        r = responses.get(url, {"error": "network"})
        if "error" in r:
            return {"policy": "disallow_all", "status": None, "robots": None}
        policy = spec_status_policy(r["status"])
        if policy == "follow_redirect":
            if redirects == MAX_REDIRECTS or not r.get("location"):
                return {"policy": "allow_all", "status": r["status"], "robots": None}  # unavailable (D-007)
            redirects += 1
            url = resolve(url, r["location"])
            continue
        if policy == "parse":
            body = base64.b64decode(r.get("body_base64", ""))
            return {"policy": "parsed", "status": r["status"], "robots": spec_parse(body).json()}
        return {"policy": policy, "status": r["status"], "robots": None}


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

cases: list[dict] = []

# Cases where protego 0.7.0 disagrees with the spec, and the decision that says why.
ORACLE_DIFFERS: dict[str, str] = {}
# Unexplained disagreements; the generator fails if any remain.
MISMATCHES: list[str] = []


def add(case: dict) -> None:
    cases.append({k: v for k, v in case.items() if v is not None})


def robots_input(data: bytes) -> dict:
    try:
        s = data.decode("utf-8")
        if not s.startswith("﻿"):
            return {"value": s}
    except UnicodeDecodeError:
        pass
    return {"base64": base64.b64encode(data).decode()}


def err(code: str) -> dict:
    return {"error": {"kind": KIND[code], "code": code}}


def protego_allowed(data: bytes, ua: str, path: str) -> bool:
    return Protego.parse(data.decode("utf-8", errors="replace")).can_fetch("https://example.com" + path, ua)


def allowed_case(cid: str, robots: str | bytes, ua: str, path: str, desc: str, *,
                 differs: str | None = None, google: str | None = None) -> None:
    """An `is_allowed` case, plus a `matching_rule` case for the same input when a rule decides."""
    data = robots.encode("utf-8") if isinstance(robots, str) else robots
    parsed = spec_parse(data)
    try:
        got = spec_is_allowed(parsed, ua, path)
    except SpecError as e:
        add({"id": cid, "op": "is_allowed", "level": "core", "group": cid.split(".")[0], "description": desc,
             "input": {**robots_input(data), "args": {"user_agent": ua, "path": path}},
             "expect": err(e.code), "compare": "exact", "source": "spec"})
        return
    oracle = protego_allowed(data, ua, path)
    if differs and oracle == got:
        MISMATCHES.append(f"{cid}: listed as an oracle difference, but protego agrees ({got})")
    elif not differs and oracle != got:
        MISMATCHES.append(f"{cid}: protego says {oracle}, spec says {got}")
    if differs:
        ORACLE_DIFFERS[cid] = differs
    full_desc = desc + (f" (Google robots_test.cc {google})" if google else "")
    if differs:
        full_desc += f" (protego differs: {differs})"
    add({"id": cid, "op": "is_allowed", "level": "core", "group": cid.split(".")[0], "description": full_desc,
         "input": {**robots_input(data), "args": {"user_agent": ua, "path": path}},
         "expect": {"value": got}, "compare": "exact", "source": "spec" if differs else "oracle"})


def rule_case(cid: str, robots: str, ua: str, path: str, desc: str) -> None:
    data = robots.encode("utf-8")
    r = spec_matching_rule(spec_parse(data), ua, path)
    add({"id": cid, "op": "matching_rule", "level": "core", "group": "matching_rule", "description": desc,
         "input": {**robots_input(data), "args": {"user_agent": ua, "path": path}},
         "expect": {"value": r.json() if r else None}, "compare": "json_equal", "source": "spec"})


def parse_case(cid: str, robots: str | bytes, desc: str, *, max_bytes: int | None = None, google: str | None = None) -> None:
    data = robots.encode("utf-8") if isinstance(robots, str) else robots
    got = spec_parse(data, **({"max_bytes": max_bytes} if max_bytes else {}))
    if got.sitemaps and max_bytes is None:  # protego's sitemaps must agree, in order
        assert list(Protego.parse(data.decode("utf-8", errors="replace")).sitemaps) == got.sitemaps, cid
    add({"id": cid, "op": "parse", "level": "core", "group": "parse",
         "description": desc + (f" (Google robots_test.cc {google})" if google else ""),
         "input": robots_input(data), "options": {"max_bytes": max_bytes} if max_bytes else None,
         "expect": {"value": got.json()}, "compare": "json_equal", "source": "spec"})


def build() -> None:
    G = "FooBot"

    # --- line syntax and groups (Google ID_ tests, RFC 9309 §2.1)
    allowed_case("syntax.correct", "user-agent: FooBot\ndisallow: /\n", G, "/x/y", "Well-formed group", google="ID_LineSyntax_Line")
    allowed_case("syntax.unknown_keys", "foo: FooBot\nbar: /\n", G, "/x/y", "Unknown keys are ignored", google="ID_LineSyntax_Line")
    allowed_case("syntax.missing_colon", "user-agent FooBot\ndisallow /\n", G, "/x/y",
                 "A missing colon is accepted when the line is exactly two words (D-006)", google="ID_LineSyntax_Line")
    groups = ("allow: /foo/bar/\n\nuser-agent: FooBot\ndisallow: /\nallow: /x/\nuser-agent: BarBot\ndisallow: /\n"
              "allow: /y/\n\n\nallow: /w/\nuser-agent: BazBot\n\nuser-agent: FooBot\nallow: /z/\ndisallow: /\n")
    for cid, ua, path, desc in [
        ("groups.merged_x", "FooBot", "/x/b", "Rules from both FooBot groups apply"),
        ("groups.merged_z", "FooBot", "/z/d", "Rules from both FooBot groups apply"),
        ("groups.other_group", "FooBot", "/y/c", "BarBot's allow doesn't apply to FooBot"),
        ("groups.bar_y", "BarBot", "/y/c", "BarBot's own allow"),
        ("groups.bar_w", "BarBot", "/w/a", "A rule after blank lines still belongs to the group"),
        ("groups.bar_z", "BarBot", "/z/d", "FooBot's allow doesn't apply to BarBot"),
        ("groups.baz_shares_group", "BazBot", "/z/d", "Consecutive user-agent lines share one group, blank lines between them too"),
        ("groups.rule_before_any_agent", "FooBot", "/foo/bar/", "A rule before any user-agent line is ignored"),
    ]:
        allowed_case(cid, groups, ua, path, desc, google="ID_LineSyntax_Groups")
    allowed_case("groups.sitemap_does_not_close", "User-agent: BarBot\nSitemap: https://foo.bar/sitemap\nUser-agent: *\nDisallow: /\n",
                 "BarBot", "/", "A sitemap line between user-agent lines doesn't end the group",
                 google="ID_LineSyntax_Groups_OtherRules")
    allowed_case("groups.unknown_does_not_close", "User-agent: FooBot\nInvalid-Unknown-Line: unknown\nUser-agent: *\nDisallow: /\n",
                 "FooBot", "/", "An unknown line between user-agent lines doesn't end the group (D-009)",
                 google="ID_LineSyntax_Groups_OtherRules", differs="an unknown line ends its agent list")
    allowed_case("groups.crawl_delay_closes", "User-agent: FooBot\nCrawl-delay: 5\nUser-agent: *\nDisallow: /\n",
                 "FooBot", "/", "Crawl-delay is a group member: it ends FooBot's agent list, so * doesn't apply to FooBot (D-009)")
    for cid, txt in [("keys.upper", "USER-AGENT: FooBot\nALLOW: /x/\nDISALLOW: /\n"),
                     ("keys.camel", "uSeR-aGeNt: FooBot\nAlLoW: /x/\ndIsAlLoW: /\n")]:
        allowed_case(cid + ".allowed", txt, G, "/x/y", "Keys are case-insensitive", google="ID_REPLineNamesCaseInsensitive")
        allowed_case(cid + ".disallowed", txt, G, "/a/b", "Keys are case-insensitive", google="ID_REPLineNamesCaseInsensitive")

    # --- agent selection (D-001; protego is wrong here)
    allowed_case("agent.value_case_insensitive", "User-Agent: FOO BAR\nAllow: /x/\nDisallow: /\n", "foo", "/a/b",
                 "The group's token is the value up to the first character outside [A-Za-z_-], matched case-insensitively",
                 google="ID_UserAgentValueCaseInsensitive", differs="matches the whole value")
    allowed_case("agent.versioned", "User-agent: FooBot/2.1\nDisallow: /\n", G, "/x", "FooBot/2.1 applies to FooBot (D-001)",
                 differs="matches the whole value")
    allowed_case("agent.prefix_is_not_a_match", "User-agent: foo\nDisallow: /\n", "foobar", "/x",
                 "foo doesn't apply to foobar: tokens must be equal (D-001)", differs="substring match")
    allowed_case("agent.own_group_no_rule", "User-agent: foobot\nAllow: /public\n\nUser-agent: *\nDisallow: /\n", "foobot", "/other",
                 "The crawler's own group decides even when none of its rules match; * doesn't apply (D-002)")
    glob = "user-agent: *\nallow: /\nuser-agent: FooBot\ndisallow: /\n"
    allowed_case("agent.empty_file", "", G, "/x/y", "No groups: everything is allowed", google="ID_GlobalGroups_Secondary")
    allowed_case("agent.specific_over_global", glob, "FooBot", "/x/y", "A specific group beats *", google="ID_GlobalGroups_Secondary")
    allowed_case("agent.global_fallback", glob, "BarBot", "/x/y", "No specific group: * applies", google="ID_GlobalGroups_Secondary")
    allowed_case("agent.no_matching_group", "user-agent: FooBot\nallow: /\nuser-agent: BarBot\ndisallow: /\n", "QuxBot", "/x/y",
                 "No specific group and no *: everything is allowed", google="ID_GlobalGroups_Secondary")
    allowed_case("agent.star_with_trailing_text", "User-agent: * nonsense\nDisallow: /\n", G, "/x",
                 "* followed by whitespace is still the global group (D-001)", differs="only exactly * is global")
    allowed_case("agent.star_glued_is_not_global", "User-agent: *bot\nDisallow: /\n", G, "/x",
                 "*bot is neither the global group nor a token that can match (D-001)")
    for cid, ua in [("agent.error.empty", ""), ("agent.error.space", "Foo Bar"), ("agent.error.version", "FooBot/2.1"),
                    ("agent.error.star", "*"), ("agent.error.non_ascii", "ツ")]:
        allowed_case(cid, "User-agent: *\nDisallow: /\n", ua, "/x", "The crawler's user agent must be a product token [A-Za-z_-]+ (D-003)")

    # --- longest match and ties (RFC §2.2.2)
    page = "/x/page.html"
    for cid, txt, path, desc in [
        ("match.longer_disallow", "user-agent: FooBot\ndisallow: /x/page.html\nallow: /x/\n", page, "Longer disallow wins"),
        ("match.longer_allow", "user-agent: FooBot\nallow: /x/page.html\ndisallow: /x/\n", page, "Longer allow wins"),
        ("match.shorter_only", "user-agent: FooBot\nallow: /x/page.html\ndisallow: /x/\n", "/x/", "Only the shorter rule matches"),
        ("match.empty_rules", "user-agent: FooBot\ndisallow: \nallow: \n", page, "Empty allow and disallow add no rules"),
        ("match.tie_root", "user-agent: FooBot\ndisallow: /\nallow: /\n", page, "Equal lengths: allow wins"),
        ("match.tie_page", "user-agent: FooBot\ndisallow: /x/page.html\nallow: /x/page.html\n", page, "Equal lengths: allow wins"),
        ("match.slash_a", "user-agent: FooBot\ndisallow: /x\nallow: /x/\n", "/x", "/x/ doesn't match /x"),
        ("match.slash_b", "user-agent: FooBot\ndisallow: /x\nallow: /x/\n", "/x/", "/x/ is longer than /x"),
        ("match.wildcard_longer", "user-agent: FooBot\nallow: /page\ndisallow: /*.html\n", "/page.html", "Wildcard pattern length counts its *"),
        ("match.wildcard_no_match", "user-agent: FooBot\nallow: /page\ndisallow: /*.html\n", "/page", "Wildcard doesn't match"),
        ("match.prefix_vs_wildcard", "user-agent: FooBot\nallow: /x/page.\ndisallow: /*.html\n", page, "Longer allow beats wildcard"),
        ("match.wildcard_other", "user-agent: FooBot\nallow: /x/page.\ndisallow: /*.html\n", "/x/y.html", "Wildcard disallow"),
        ("match.specific_group_implicit_allow", "User-agent: *\nDisallow: /x/\nUser-agent: FooBot\nDisallow: /y/\n", "/x/page",
         "FooBot's group doesn't mention /x/: allowed"),
        ("match.specific_group_disallow", "User-agent: *\nDisallow: /x/\nUser-agent: FooBot\nDisallow: /y/\n", "/y/page",
         "FooBot's own disallow"),
        ("match.case_sensitive_lower", "user-agent: FooBot\ndisallow: /x/\n", "/x/y", "Paths are case-sensitive"),
        ("match.case_sensitive_upper", "user-agent: FooBot\ndisallow: /X/\n", "/x/y", "Paths are case-sensitive"),
        ("match.query_counts", "User-agent: *\nDisallow: /*?\n", "/search?q=1", "The query is part of the path"),
        ("match.no_query", "User-agent: *\nDisallow: /*?\n", "/search", "No query: no match"),
        ("match.space_in_pattern", "User-agent: *\nDisallow: /a b\n", "/ab", "Spaces inside a value are kept: /a b doesn't match /ab"),
    ]:
        allowed_case(cid, txt, G, path, desc, google="ID_LongestMatch" if "x/page" in txt or "/x\n" in txt else None)

    # --- special characters (RFC §2.2.3)
    for cid, txt, path, desc in [
        ("special.star_disallowed", "User-agent: FooBot\nDisallow: /foo/bar/quz\nAllow: /foo/*/qux\n", "/foo/bar/quz", "Literal disallow"),
        ("special.star_empty", "User-agent: FooBot\nDisallow: /foo/bar/quz\nAllow: /foo/*/qux\n", "/foo/quz", "No rule matches"),
        ("special.star_double_slash", "User-agent: FooBot\nDisallow: /foo/bar/quz\nAllow: /foo/*/qux\n", "/foo//quz", "No rule matches"),
        ("special.dollar_exact", "User-agent: FooBot\nDisallow: /foo/bar$\nAllow: /foo/bar/qux\n", "/foo/bar", "$ anchors the end"),
        ("special.dollar_longer", "User-agent: FooBot\nDisallow: /foo/bar$\nAllow: /foo/bar/qux\n", "/foo/bar/", "$ doesn't match a longer path"),
        ("special.dollar_other", "User-agent: FooBot\nDisallow: /foo/bar$\nAllow: /foo/bar/qux\n", "/foo/bar/baz", "$ doesn't match a longer path"),
        ("special.comment_line", "User-agent: FooBot\n# Disallow: /\nDisallow: /foo/quz#qux\nAllow: /\n", "/foo/bar", "Comments are ignored"),
        ("special.comment_inline", "User-agent: FooBot\n# Disallow: /\nDisallow: /foo/quz#qux\nAllow: /\n", "/foo/quz", "An inline comment ends the value"),
        ("special.dollar_pdf", "User-agent: *\nDisallow: /*.pdf$\n", "/a.pdf?x=1", "A query after .pdf: $ doesn't match"),
        ("special.dollar_middle", "User-agent: *\nDisallow: /a$b\n", "/a$b", "$ is literal except at the end"),
        ("special.robots_txt", "User-agent: *\nDisallow: /\n", "/robots.txt", "/robots.txt is always allowed (RFC §2.2.2)"),
    ]:
        allowed_case(cid, txt, G, path, desc, google="ID_SpecialCharacters" if "foo/" in txt else None)

    # --- percent-encoding (D-004: the same normalization on both sides)
    enc = "User-agent: FooBot\nDisallow: /\nAllow: "
    allowed_case("encoding.reserved_kept", enc + "/foo/bar?qux=taz&baz=http://foo.bar?tar&par\n", G,
                 "/foo/bar?qux=taz&baz=http://foo.bar?tar&par", "Reserved characters are compared as they are", google="ID_Encoding")
    allowed_case("encoding.utf8_rule_encoded_path", enc + "/foo/bar/ツ\n", G, "/foo/bar/%E3%83%84",
                 "A non-ASCII rule matches its percent-encoded form", google="ID_Encoding")
    allowed_case("encoding.utf8_rule_raw_path", enc + "/foo/bar/ツ\n", G, "/foo/bar/ツ",
                 "Raw non-ASCII in the path is encoded the same way, so it matches (Google says not; D-004)",
                 google="ID_Encoding")
    allowed_case("encoding.encoded_rule_raw_path", enc + "/foo/bar/%E3%83%84\n", G, "/foo/bar/ツ",
                 "Same as above, the other way round (Google says not; D-004)", google="ID_Encoding")
    allowed_case("encoding.lowercase_hex", enc + "/foo/bar/%e3%83%84\n", G, "/foo/bar/%E3%83%84", "Hex digits compare case-insensitively")
    allowed_case("encoding.unreserved_decoded", "User-agent: *\nDisallow: /%7Euser\n", G, "/~user",
                 "%7E is an unreserved character: decoded before comparing (RFC §2.2.2; Google says not; D-004)")
    allowed_case("encoding.unreserved_rule_letters", enc + "/foo/bar/%62%61%7A\n", G, "/foo/bar/baz",
                 "Encoded unreserved letters match the plain path (Google says not; D-004)", google="ID_Encoding")
    allowed_case("encoding.invalid_utf8_rule", b"User-agent: *\nDisallow: /caf\xe9\n", G, "/caf%E9",
                 "A rule's invalid UTF-8 byte matches by its original byte, not by the U+FFFD it's reported with")
    allowed_case("encoding.invalid_utf8_rule_not_fffd", b"User-agent: *\nDisallow: /caf\xe9\n", G, "/caf%EF%BF%BD",
                 "The reported U+FFFD isn't what matches (D-004)", differs="matches the U+FFFD replacement text")
    allowed_case("encoding.reserved_not_decoded", "User-agent: *\nDisallow: /a%2Fb\n", G, "/a/b", "%2F is reserved: not decoded")

    # --- matching_rule: which rule decided
    rule_case("rule.longest", "user-agent: FooBot\ndisallow: /x/\nallow: /x/page\n", G, "/x/page.html", "The longest matching rule")
    rule_case("rule.tie_is_allow", "user-agent: FooBot\ndisallow: /p\nallow: /p\n", G, "/p", "A tie reports the allow rule")
    rule_case("rule.none", "user-agent: FooBot\ndisallow: /x/\n", G, "/y", "No rule matched: null")
    rule_case("rule.robots_txt", "User-agent: *\nDisallow: /\n", G, "/robots.txt", "/robots.txt: null, no rule decides")
    rule_case("rule.first_of_equals", "user-agent: FooBot\ndisallow: /a\ndisallow: /a\n", G, "/a", "Equal rules: the first in the file")
    rule_case("rule.across_groups", "user-agent: FooBot\ndisallow: /a\n\nuser-agent: FooBot\ndisallow: /ab\n", G, "/abc",
              "Rules from merged groups compete; line numbers are the file's")

    # --- parse structure
    parse_case("parse.groups", "User-agent: a\nUser-agent: b\nDisallow: /x\nCrawl-delay: 2.5\n\nUser-agent: c\nAllow: /y\n",
               "Two groups; crawl-delay recorded per group")
    parse_case("parse.lines_unix", "User-Agent: foo\nAllow: /some/path\nUser-Agent: bar\n\n\nDisallow: /\n",
               "Line numbers with \\n", google="ID_LinesNumbersAreCountedCorrectly")
    parse_case("parse.lines_dos", "User-Agent: foo\r\nAllow: /some/path\r\nUser-Agent: bar\r\n\r\n\r\nDisallow: /\r\n",
               "Line numbers with \\r\\n", google="ID_LinesNumbersAreCountedCorrectly")
    parse_case("parse.lines_mac", "User-Agent: foo\rAllow: /some/path\rUser-Agent: bar\r\r\rDisallow: /\r",
               "Line numbers with \\r", google="ID_LinesNumbersAreCountedCorrectly")
    parse_case("parse.lines_mixed", "User-Agent: foo\nAllow: /some/path\r\nUser-Agent: bar\n\r\n\nDisallow: /",
               "Mixed line endings, no final newline", google="ID_LinesNumbersAreCountedCorrectly")
    for cid, bom, desc in [("parse.bom_full", b"\xef\xbb\xbf", "A UTF-8 byte order mark is skipped"),
                           ("parse.bom_partial2", b"\xef\xbb", "A partial byte order mark is skipped"),
                           ("parse.bom_partial1", b"\xef", "A partial byte order mark is skipped"),
                           ("parse.bom_broken", b"\xef\x11\xbf", "A broken byte order mark spoils the first line")]:
        parse_case(cid, bom + b"User-Agent: foo\nAllow: /AnyValue\n", desc, google="ID_UTF8ByteOrderMarkIsSkipped")
    parse_case("parse.bom_middle", b"User-Agent: foo\n\xef\xbb\xbfAllow: /AnyValue\n",
               "A byte order mark later in the file is just bytes, so that line's key is unknown", google="ID_UTF8ByteOrderMarkIsSkipped")
    parse_case("parse.sitemap_end", "User-Agent: foo\nAllow: /some/path\nUser-Agent: bar\n\n\nSitemap: http://foo.bar/sitemap.xml\n",
               "Sitemap after the groups", google="ID_NonStandardLineExample_Sitemap")
    parse_case("parse.sitemap_start", "Sitemap: http://foo.bar/sitemap.xml\nUser-Agent: foo\nAllow: /some/path\n",
               "Sitemap before the groups", google="ID_NonStandardLineExample_Sitemap")
    parse_case("parse.sitemaps_in_order", "Sitemap: https://a.example/1.xml\nUser-agent: *\nSitemap: https://a.example/2.xml\nDisallow: /x\n",
               "Every sitemap, in file order; sitemap lines don't belong to groups")
    parse_case("parse.invalid_utf8", b"User-agent: *\nDisallow: /caf\xe9\n", "Invalid UTF-8 is tolerated; the value is reported with U+FFFD")
    parse_case("parse.invalid_utf8_subparts", b"User-agent: *\nDisallow: /a\xc0\x80b\xe2\x82c\xf0\x9f\x98d\xed\xa0\x80e\n",
               "One U+FFFD per maximal invalid subpart (Unicode's recommended practice, as Python, Rust and Swift do)")
    parse_case("parse.crawl_delay_not_finite", "User-agent: a\nCrawl-delay: " + "9" * 400 + "\nCrawl-delay: 4\nDisallow: /\n",
               "A crawl-delay too large for f64 is skipped, like any invalid value")
    parse_case("parse.crawl_delay_invalid", "User-agent: a\nCrawl-delay: soon\nCrawl-delay: -1\nCrawl-delay: 3\nDisallow: /\n",
               "Crawl-delay values that aren't non-negative decimals are skipped; the first valid one is kept")
    body = "User-agent: *\nDisallow: /a\nDisallow: /b\n"
    parse_case("parse.truncated_line_dropped", body, "The limit cuts the third line: it's dropped, and truncated is set (D-005)",
               max_bytes=len("User-agent: *\nDisallow: /a\nDisallow: /"))
    parse_case("parse.truncated_on_boundary", body, "The limit falls just after a newline: nothing is cut mid-line",
               max_bytes=len("User-agent: *\nDisallow: /a\n"))
    parse_case("parse.not_truncated", body, "Exactly at the limit: not truncated", max_bytes=len(body))

    # crawl_delay (extension)
    for cid, txt, ua, desc in [
        ("crawl_delay.specific", "User-agent: *\nCrawl-delay: 10\n\nUser-agent: FooBot\nCrawl-delay: 2.5\nDisallow: /x\n", G, "The crawler's own group"),
        ("crawl_delay.global", "User-agent: *\nCrawl-delay: 10\nDisallow: /x\n", G, "Falls back to *"),
        ("crawl_delay.none", "User-agent: *\nDisallow: /x\n", G, "No crawl-delay: null"),
    ]:
        data = txt.encode()
        got = spec_crawl_delay(spec_parse(data), ua)
        o = Protego.parse(txt).crawl_delay(ua)
        assert (o is None and got is None) or abs(float(o) - got) < 1e-9, (cid, o, got)
        add({"id": cid, "op": "crawl_delay", "level": "core", "group": "crawl_delay", "description": desc + " (extension, not RFC 9309)",
             "input": {**robots_input(data), "args": {"user_agent": ua}}, "expect": {"value": got},
             "compare": "exact" if got is None else "float_tol", "tolerance": None if got is None else 1e-12, "source": "oracle"})

    # status_policy (RFC §2.3.1)
    for status, why in [(200, "2xx: parse"), (204, "2xx: parse"), (301, "3xx: follow the redirect"), (308, "3xx"),
                        (400, "4xx: unavailable, allow all"), (403, "4xx, including 401/403: allow all (RFC §2.3.1.3)"),
                        (404, "4xx"), (429, "429: treated as unreachable, disallow all (D-008)"),
                        (500, "5xx: unreachable, disallow all"), (503, "5xx"), (100, "Not a final status: unreachable"),
                        (199, "Not a final status"), (600, "Out of range: unreachable"), (0, "Out of range")]:
        add({"id": f"status.{status}", "op": "status_policy", "level": "core", "group": "status_policy", "description": why,
             "input": {"value": status}, "expect": {"value": spec_status_policy(status)}, "compare": "exact", "source": "spec"})

    # --- fetch (io): scripted responses; the runner supplies them through a fake transport
    ok = base64.b64encode(b"User-agent: *\nDisallow: /private\n").decode()
    O = "https://example.com"
    for cid, origin, responses, desc in [
        ("fetch.ok", O, {O + "/robots.txt": {"status": 200, "body_base64": ok}}, "200: parsed"),
        ("fetch.not_found", O, {O + "/robots.txt": {"status": 404}}, "404: allow all"),
        ("fetch.server_error", O, {O + "/robots.txt": {"status": 503}}, "503: disallow all"),
        ("fetch.network_error", O, {O + "/robots.txt": {"error": "network"}}, "Unreachable: disallow all"),
        ("fetch.redirect", O, {O + "/robots.txt": {"status": 301, "location": "https://www.example.com/robots.txt"},
                               "https://www.example.com/robots.txt": {"status": 200, "body_base64": ok}}, "One redirect, followed"),
        ("fetch.redirect_relative", O, {O + "/robots.txt": {"status": 302, "location": "/r/robots.txt"},
                                        O + "/r/robots.txt": {"status": 200, "body_base64": ok}}, "A relative Location"),
        ("fetch.redirects_five", O, {**{f"{O}/r{i}": {"status": 301, "location": f"/r{i + 1}"} for i in range(1, 5)},
                                     O + "/robots.txt": {"status": 301, "location": "/r1"},
                                     O + "/r5": {"status": 200, "body_base64": ok}}, "Five redirects: still followed"),
        ("fetch.redirects_six", O, {**{f"{O}/r{i}": {"status": 301, "location": f"/r{i + 1}"} for i in range(1, 6)},
                                    O + "/robots.txt": {"status": 301, "location": "/r1"},
                                    O + "/r6": {"status": 200, "body_base64": ok}}, "Six redirects: unavailable, allow all (D-007)"),
        ("fetch.redirect_no_location", O, {O + "/robots.txt": {"status": 302}}, "A redirect without Location: unavailable, allow all"),
        ("fetch.origin_trailing_slash", O + "/", {O + "/robots.txt": {"status": 200, "body_base64": ok}}, "Trailing slash on the origin"),
    ]:
        add({"id": cid, "op": "fetch", "level": "io", "group": "fetch", "description": desc,
             "input": {"value": {"origin": origin, "responses": responses}},
             "expect": {"value": spec_fetch(origin, responses)}, "compare": "json_equal", "source": "spec"})
    for cid, origin in [("fetch.error.path", O + "/x"), ("fetch.error.scheme", "ftp://example.com"), ("fetch.error.query", O + "?a"),
                       ("fetch.error.userinfo", "https://user:secret@example.com")]:
        try:
            spec_fetch(origin, {})
            raise AssertionError(cid)
        except SpecError as e:
            add({"id": cid, "op": "fetch", "level": "io", "group": "fetch.error", "description": "Not an origin",
                 "input": {"value": {"origin": origin, "responses": {}}}, "expect": err(e.code), "compare": "exact", "source": "spec"})


def main() -> None:
    build()
    if MISMATCHES:
        raise SystemExit("oracle disagreements without a decision:\n  " + "\n  ".join(MISMATCHES))
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    manifest = {"capability": "robotstxt", "spec_version": SPEC_VERSION, "oracle": ORACLE,
                "generated_at": GENERATED_AT, "cases": cases}
    (ROOT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n")
    by_source = {s: sum(c.get("source") == s for c in cases) for s in ("oracle", "spec")}
    by_level = {lv: sum(c["level"] == lv for c in cases) for lv in ("core", "io")}
    print(f"wrote manifest.json: {len(cases)} cases ({by_source['oracle']} oracle, {by_source['spec']} spec; "
          f"core {by_level['core']}, io {by_level['io']}); protego differs on {len(ORACLE_DIFFERS)} by decision")


if __name__ == "__main__":
    main()
