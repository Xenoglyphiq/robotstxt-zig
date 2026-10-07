# Benchmarks

| Path | What |
|---|---|
| `robots.txt` | 79,936-byte file: a global group and 40 crawler groups, 3,310 rules with wildcards and `$`, comments and sitemaps |
| `paths.txt` | 10,000 lookups, one `user_agent path` per line, in 10 blocks of 1,000 (one per crawler). Two crawlers have no group, so `*` applies to them; 4,976 lookups are allowed |
| `generate.py` | Builds both, deterministically; re-running gives identical bytes on every platform. It also checks that `protego` agrees on every lookup |
| `rust/` | The reference: the Rust `texting_robots` crate (pinned `=0.2.2`), a Google-compatible parser |

**Checksum: 24281055.** That's the sum of the 1-based line numbers (in `paths.txt`) of the allowed lookups. Every harness must reproduce it, which proves it gave the right answers and didn't just go fast. The spec's transcription, `protego` and the Rust reference all produce it. The input stays inside what every implementation agrees on: ASCII only, no percent escapes, plain product tokens.

## Method

Every port measures exactly this, so ratios are comparable:

1. Read both files into memory once.
2. **One pass** = for each block of lines with the same crawler, in file order: `parse` `robots.txt`, then `is_allowed` for each of the block's paths, adding the line number of every allowed one. The sum must equal the checksum. (Parsing once per crawler matches the reference, whose parser is per crawler; it also keeps parsing in the measurement.)
3. Run 3 warm-up passes, then 15 timed passes. Report the median and the minimum time per pass.
4. Use an optimized build, a monotonic clock, and a quiet machine.

The ratio is **port median ÷ reference median, measured in the same session** (interleaved rounds). The target is within 2× (`spec/SPEC.md` §8).

## Reference timings

```
cargo run --release --manifest-path bench/rust/Cargo.toml
```

To be recorded in the same session as the first port's numbers.
