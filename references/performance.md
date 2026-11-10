# Performance

> Read when: something is slow, writing benchmarks, tuning build profiles, reducing allocations or binary size, or profiling an application before or after release.

## 1. Measure first

No optimization without a measurement that shows the problem and a measurement that shows the fix. Order of work:

1. Reproduce with a realistic workload (release build — debug numbers are meaningless).
2. Profile to find where time/memory actually goes.
3. Fix the algorithm or data layout first; micro-optimizations last.
4. Lock the win in with a benchmark or a CI perf gate.

## 2. Profiling tools

| Question | Tool |
|---|---|
| Where does CPU time go (Linux/macOS)? | `samply record ./target/release/app` (Firefox profiler UI), `perf record -g` + `cargo flamegraph` |
| Where do allocations come from? | `dhat` (heap profiling via `dhat::Profiler` in a feature-gated build), `heaptrack` |
| Why is my app janky / slow frames / regressed since vX? On a device I can't reach? | **sismo** — in-app scopes, frame marks, flight recorder, `sismo compare a.sismo b.sismo --metric p95` (see [ecosystem.md](ecosystem.md)) |
| Compile time | `cargo build --timings` |
| Binary size | `cargo bloat --release` (cargo-bloat) |

Profile release builds with symbols: set `debug = "line-tables-only"` (or a dedicated `profiling` profile, below).

## 3. Benchmarks

| | `criterion` 0.8 | `divan` 0.1 |
|---|---|---|
| Strength | statistical rigor, baselines, HTML reports, history comparison | ergonomic attribute API, fast to write, allocation counting |
| Use for | benchmarks tracked over time / in CI | quick micro-benchmarks during development |

Both live in `benches/` with `harness = false`:

```toml
[[bench]]
name = "codec"
harness = false
```

```rust
// benches/codec.rs (divan)
fn main() {
    divan::main();
}

#[divan::bench(args = [64, 1024, 65536])]
fn encode(bencher: divan::Bencher, size: usize) {
    let frame = Frame::from(vec![0u8; size]);
    bencher.bench(|| divan::black_box(&frame).encode());
}
```

- Always `black_box` inputs/outputs so the optimizer does not delete the work.
- Benchmark the public API at realistic sizes, not internals with toy data.
- CI runners are noisy: compare against a baseline on the same machine, or use relative thresholds, never absolute nanoseconds.
- Micro-benchmarks answer "is this function faster"; sismo answers "is the app faster for users". Use both for their purpose.

## 4. Allocation habits

- Pre-size: `Vec::with_capacity(n)`, `String::with_capacity(n)`, `HashMap::with_capacity(n)` when the size is known.
- Reuse buffers in hot loops: `buf.clear()` instead of allocating a new `Vec` each iteration.
- Borrow instead of clone: take `&str`/`&[T]`; return borrowed views or iterators.
- `Cow<'a, str>` when a value is usually borrowed but sometimes needs modification.
- `SmallVec<[T; N]>` / `ArrayVec` for small collections that are usually under `N` items (measure — larger stack frames have a cost).
- `Box<str>` / `Arc<str>` for immutable strings stored long-term (smaller than `String`, cheap clone with `Arc`).
- Avoid `format!` in hot paths; `write!` into a reused buffer.
- `clippy::perf` lints are on by default — do not silence them; pedantic adds more (`inefficient_to_string`, `needless_pass_by_value`).

## 5. Data layout and algorithms

- Choose the right collection: `Vec` + binary search or `sort_unstable` often beats `BTreeMap` for small static sets; `HashMap` with a faster hasher (`rustc-hash`/`ahash`) when keys are not attacker-controlled.
- Struct-of-arrays for hot loops over one field of many items.
- Avoid repeated lookups: use the `entry` API.
- Bound checks: iterators and `chunks_exact` let the compiler elide them; indexing in loops often does not.
- Cache-unfriendly pointer chasing (`Vec<Box<T>>`, linked lists) is a common hidden cost.

## 6. Build profiles

A baseline that works well for applications (it matches `templates/Cargo.workspace.toml`):

```toml
[profile.dev]
opt-level = 1            # usable debug builds for apps/games

[profile.dev.package."*"]
opt-level = 3            # dependencies (codecs, renderers) fast even in dev; compiled once, cached

[profile.release]
lto = "thin"             # most of fat LTO's gain at a fraction of link time
codegen-units = 1
strip = true             # smallest binary; panic messages keep file:line, backtraces lose symbols
panic = "abort"          # applications only; libraries must not rely on it

[profile.profiling]      # cargo build --profile profiling
inherits = "release"
debug = "line-tables-only" # symbolized profiles and backtraces without full debuginfo
strip = "none"           # `strip = true` would delete the line tables just requested
```

Notes:

- Never combine `strip = true` with `debug = ...` in the same profile: stripping removes the debug info. If shipped binaries need symbolized backtraces, set `debug = "line-tables-only"` with `strip = "none"` (or `split-debuginfo = "packed"` and keep the debug file out of the artifact).
- `lto = "fat"` can win a few percent more; measure, and watch CI link time (in one example project, fat LTO made the final link the slowest CI step).
- `overflow-checks = true` in release is a reasonable choice for code handling untrusted input (niri does it).
- `opt-level = "s"`/`"z"` for size-constrained targets (wasm, embedded).
- `target-cpu=native` only for binaries that never leave the build machine; never in distributed artifacts.
- `panic = "abort"` changes behavior: `catch_unwind` stops working and destructors do not run on panic.

## 7. Binary size

- `strip = true`, `lto`, `codegen-units = 1`, `panic = "abort"`, `opt-level = "z"` (in that order of impact-per-risk).
- `cargo bloat --release --crates` to find heavy dependencies; disable unused default features.
- Generic code monomorphized many times bloats binaries; a non-generic inner function (`fn inner(&Path)` called from `fn outer(impl AsRef<Path>)`) fixes it.

## 8. Compile-time performance

- Disable unused default features of heavy dependencies.
- Split large crates into workspace members so incremental builds touch less.
- The default linker on x86_64 Linux is lld since 1.90; on other targets consider `mold`/`lld` via `.cargo/config.toml`.
- Use `cargo build --timings` to find the crates that serialize the build.

## 9. Async and concurrency performance

- Blocking in async tasks is a performance bug before it is a correctness bug (see [async.md](async.md)).
- Contended locks: measure with a profiler; fix by sharding, message passing or reducing critical sections (see [concurrency.md](concurrency.md)).
- Parallelism has overhead: rayon on 100 tiny items is slower than a loop.

## Anti-patterns

- Optimizing without a profile ("I think this clone is slow").
- Benchmarking debug builds.
- `.clone()` in hot loops to satisfy the borrow checker.
- `collect::<Vec<_>>()` just to iterate again.
- `unsafe` (e.g. `get_unchecked`) for speed without a benchmark proving the bounds check mattered and a `SAFETY` proof.
- `lto = "fat"` + `codegen-units = 1` applied to dev profiles.
- Absolute-time perf assertions in CI on shared runners.

## Checklist

- [ ] Problem reproduced and profiled on a release build.
- [ ] Fix verified by a benchmark or sismo comparison, numbers recorded in the PR/decision log.
- [ ] Hot paths pre-size and reuse allocations; no needless clones.
- [ ] Release profile tuned (LTO, codegen-units, strip, debug line tables); `panic = "abort"` only for apps.
- [ ] Dev profile keeps dependencies optimized for apps with heavy deps.
- [ ] Regression guard exists (criterion baseline or `sismo compare` in CI) for performance-critical paths.

See also: [concurrency.md](concurrency.md), [async.md](async.md), [ecosystem.md](ecosystem.md), [testing.md](testing.md).
