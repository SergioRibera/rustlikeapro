# Testing

> Read when: adding or restructuring tests, choosing a test tool (snapshots, property tests, fuzzing), setting up coverage or mutation testing, or testing UI headlessly.

Tests are executable specifications. A test suite is good when a wrong change fails loudly and a correct refactor stays green.

## 1. Layout

| Kind | Location | Tests |
|---|---|---|
| Unit | `#[cfg(test)] mod tests` at the bottom of the file | private functions and invariants of one module |
| Integration | `tests/<area>.rs` (one file per module/feature area) | the public API only, as a user sees it |
| Doc tests | `///` examples | that documented usage compiles and works |
| Benchmarks | `benches/` | see [performance.md](performance.md) |
| Examples | `examples/` | runnable usage; compiled by `cargo test --all-targets` |

- Group integration tests by module (`tests/config.rs`, `tests/storage.rs`). Each file is a separate crate and binary; for large suites prefer one `tests/it/main.rs` with `mod config; mod storage;` to cut link time.
- Shared helpers go in `tests/common.rs` (or `tests/it/common.rs`) as a fixture type with methods, not loose functions.
- `#[cfg(test)]` code may `unwrap()`; set `allow-unwrap-in-tests = true` (and `allow-expect-in-tests`) in `clippy.toml`.

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn port_rejects_zero() {
        assert!(matches!(Port::try_from(0), Err(PortError::Zero)));
    }
}
```

On Rust 1.96+, prefer `assert_matches!(Port::try_from(0), Err(PortError::Zero));` — it prints the actual value on failure.

## 2. Writing good tests

- Name tests after behavior: `expired_token_is_rejected`, not `test_token_3`.
- One behavior per test; arrange–act–assert.
- Test errors as carefully as success paths: match the variant, not the message string.
- Return `Result` from tests when setup is fallible: `fn loads() -> Result<(), ConfigError> { … }`.
- No sleeps for synchronization. Use channels, `tokio::time::pause()` in async tests, or explicit barriers.
- Use `tempfile::TempDir` for filesystem tests; never write into the repo or a fixed `/tmp` path.

### Parametrized tests with `rstest`

```rust
#[rstest::rstest]
#[case("8080", Ok(8080))]
#[case("0", Err(PortError::Zero))]
#[case("abc", Err(PortError::NotANumber))]
fn parses_port(#[case] input: &str, #[case] expected: Result<u16, PortError>) {
    assert_eq!(input.parse::<Port>().map(u16::from), expected);
}
```

## 3. Snapshot tests (`insta` 1.49)

Use for outputs that are large, structured or tedious to assert by hand: rendered text, generated code, serialized structs, CLI output.

```rust
#[test]
fn renders_summary() {
    let report = Report::from(sample_events());
    insta::assert_snapshot!(report.to_string());
}

#[test]
fn inline_value() {
    insta::assert_snapshot!(format_duration(Duration::from_millis(1500)), @"1.5s");
}
```

- Review changes with `cargo insta review` (install `cargo-insta`); accept with `cargo insta accept`.
- Commit `snapshots/` directories. In CI, `INSTA_UPDATE=no` (default on CI) makes new or changed snapshots fail.
- Redact unstable values (timestamps, UUIDs) with insta's redaction support (`yaml`/`json` features) instead of making the code nondeterministic.

### Golden files without insta

For generated code (codegen, bindings), compare against checked-in files and regenerate behind an env var — the pattern used in istmo:

```rust
#[test]
fn kotlin_dispatcher_matches_golden() {
    let generated = KotlinHost::from(&sample_contract()).render();
    let golden = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/dispatcher.kt");
    if std::env::var_os("PROJECT_UPDATE_GOLDEN").is_some() {
        std::fs::write(&golden, &generated).expect("invariant: golden dir exists in repo");
        return;
    }
    let expected = std::fs::read_to_string(&golden).expect("invariant: golden file committed");
    assert_eq!(generated, expected, "run with PROJECT_UPDATE_GOLDEN=1 to regenerate");
}
```

## 4. Property-based tests (`proptest` 1.12)

Use for parsers, encoders, data structures and anything with an invariant that should hold for *all* inputs. Typical properties: round-trip (`decode(encode(x)) == x`), idempotence, ordering, "never panics".

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn frame_roundtrip(payload in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let frame = Frame::from(payload.clone());
        let decoded = Frame::decode(&frame.encode()).expect("invariant: encoded frame decodes");
        prop_assert_eq!(decoded.payload(), payload.as_slice());
    }
}
```

- Commit `proptest-regressions/` files — they replay previously found failures.
- Run a long campaign on a schedule (e.g. monthly cron in release mode with `PROPTEST_CASES=200000`, as niri does), not on every PR.

## 5. Running tests

- `cargo nextest run --workspace --all-features --locked` — faster, per-test process isolation, better output (cargo-nextest 0.9.x).
- **nextest does not run doc tests.** Always also run `cargo test --doc --workspace --all-features`.
- Plain `cargo test --workspace --all-features --locked` is the fallback when nextest is unavailable.
- Feature combinations: `cargo hack test --each-feature` for libraries with features (see [api-design.md](api-design.md)).

## 6. Coverage and mutation testing

- Coverage: `cargo llvm-cov nextest --workspace --lcov --output-path lcov.info` (cargo-llvm-cov 0.9). Use it to find untested modules, not as a target number.
- Mutation testing: `cargo mutants` (cargo-mutants 27) changes code and checks that tests fail. Surviving mutants reveal assertions that do not assert. Run on a module (`cargo mutants -f src/parser.rs`) or on a schedule; it is too slow for every PR.

## 7. Unsafe and concurrency tests

- `cargo +nightly miri test` for crates containing `unsafe` (see [unsafe-ffi.md](unsafe-ffi.md)). Never cache Miri jobs' `target/` or expose secrets to them in CI (see [ci-hardening.md](ci-hardening.md)).
- `loom` for lock-free code and custom synchronization primitives (see [concurrency.md](concurrency.md)).

## 8. Async tests

```rust
#[tokio::test(start_paused = true)]
async fn retries_after_backoff() {
    let client = FlakyClient::default();
    let result = client.fetch_with_retry().await; // tokio::time::sleep advances instantly
    assert!(result.is_ok());
}
```

`start_paused` needs the `test-util` feature of tokio (dev-dependency only).

## 9. UI and headless tests

- Keep logic out of view code so it is unit-testable (state machines, view models).
- egui: `egui_kittest` for headless interaction and image snapshots.
- Freya: its testing utilities (`freya-testing`) for headless component tests; check the version in use.
- Window smoke tests on Linux CI: run under `xvfb-run`.
- Upload snapshot diffs as CI artifacts on failure.

## 10. Fuzzing (optional)

For parsers, decoders and anything fed untrusted bytes: `cargo fuzz` (cargo-fuzz, needs nightly) with targets in `fuzz/fuzz_targets/`. Reuse proptest strategies or `arbitrary` derives for structured input. Run campaigns locally or on a schedule; commit found crash inputs as regression tests.

## Anti-patterns

- Tests that assert on `Display` strings of errors instead of variants.
- `#[ignore]`d tests with no issue link and no owner.
- `thread::sleep` to wait for background work.
- Tests depending on execution order or shared global state.
- Snapshot files accepted blindly with `cargo insta accept` without review.
- Doc examples using `unwrap()` that get copied into production code.
- Claiming tests pass without running them; skipping doc tests because nextest was green.

## Checklist

- [ ] Unit tests next to the code, integration tests in `tests/` grouped by area.
- [ ] Error paths tested by variant.
- [ ] Snapshot/golden files committed and reviewed; regeneration documented.
- [ ] Property tests for parsers/encoders/invariants; regressions committed.
- [ ] `cargo nextest run` **and** `cargo test --doc` pass.
- [ ] Unsafe crates run under Miri; feature combinations checked for libraries.

See also: [performance.md](performance.md), [ci-cd.md](ci-cd.md), [async.md](async.md).
