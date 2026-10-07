//! Reference timings for the robots.txt spec: the Rust `texting_robots` crate (a
//! Google-compatible parser), over bench/robots.txt and bench/paths.txt. Method (shared by
//! every port, see bench/README.md): load both files once; one pass = for each crawler's
//! block of paths, parse robots.txt for that crawler and check each of its paths; 3 warm-up
//! passes, then 15 timed passes; report the median and min per pass. The checksum (sum of the
//! 1-based line numbers of allowed paths) must match bench/README.md.
//!
//! Run from the repo root:  cargo run --release --manifest-path bench/rust/Cargo.toml

use std::time::Instant;

use texting_robots::Robot;

const WARMUP: usize = 3;
const RUNS: usize = 15;
const CHECKSUM: u64 = 24_281_055;

fn main() {
    let dir = std::env::args().nth(1).unwrap_or_else(|| "bench".into());
    let robots = std::fs::read(format!("{dir}/robots.txt")).expect("read robots.txt");
    let text = std::fs::read_to_string(format!("{dir}/paths.txt")).expect("read paths.txt");
    let lines: Vec<(String, String)> = text
        .lines()
        .map(|l| {
            let (agent, path) = l.split_once(' ').expect("agent path");
            (agent.to_string(), format!("https://www.example.com{path}"))
        })
        .collect();
    // Blocks of consecutive lines for one crawler: (agent, first line index, end).
    let mut blocks: Vec<(String, usize, usize)> = Vec::new();
    for (i, (agent, _)) in lines.iter().enumerate() {
        match blocks.last_mut() {
            Some(b) if &b.0 == agent => b.2 = i + 1,
            _ => blocks.push((agent.clone(), i, i + 1)),
        }
    }

    let mut ms = Vec::with_capacity(RUNS);
    for run in 0..WARMUP + RUNS {
        let start = Instant::now();
        let mut sum = 0u64;
        for (agent, from, to) in &blocks {
            let robot = Robot::new(agent, &robots).expect("parse robots.txt");
            for i in *from..*to {
                if robot.allowed(&lines[i].1) {
                    sum += i as u64 + 1;
                }
            }
        }
        let elapsed = start.elapsed().as_secs_f64() * 1e3;
        assert_eq!(sum, CHECKSUM, "checksum mismatch: wrong answers");
        if run >= WARMUP {
            ms.push(elapsed);
        }
    }
    ms.sort_by(f64::total_cmp);
    println!(
        "rust texting_robots 0.2.2 ({} lookups, {} parses): pass median {:.3} ms (min {:.3}), checksum {CHECKSUM} ok",
        lines.len(),
        blocks.len(),
        ms[RUNS / 2],
        ms[0]
    );
}
