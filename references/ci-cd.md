# CI/CD for Rust

> Read when: creating or fixing a CI workflow, adding a job (MSRV, features, wasm, mobile targets, deny), speeding up CI, wiring a Nix-based pipeline, or making local checks match CI.

Principles:

1. **CI enforces what the manifest declares.** Lints, MSRV, features and licenses are configured in files (`Cargo.toml`, `clippy.toml`, `deny.toml`); CI only runs the tools with `-D warnings`.
2. **One local command mirrors CI** (`scripts/check.sh` or `just ci`). If CI fails on something the local gate does not check, fix the gate.
3. **Fast feedback first**: cheap jobs (fmt, typos) fail in seconds; expensive matrices run in parallel, not after.

Template: `../templates/ci.yml`. Security settings (permissions, SHA pinning): `ci-hardening.md`.

## Job layout

| Job | Command | Profile |
|---|---|---|
| fmt | `cargo fmt --all -- --check` | all |
| typos | `typos` (via `taiki-e/install-action` `tool: typos-cli`, or `crate-ci/typos`) | all |
| lint | `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings` | all |
| docs | `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps --all-features` (+ `--document-private-items` for apps) | libraries required |
| test | `cargo nextest run --workspace --all-features --locked` **and** `cargo test --doc --workspace --all-features` (nextest does not run doctests) | all |
| features | `cargo hack check --each-feature --no-dev-deps` (or `--feature-powerset --depth 2`) | crates with features |
| msrv | toolchain = `rust-version`, `cargo check --workspace --all-targets --locked` | libraries, anything declaring `rust-version` |
| targets | `cargo check --target <t>` for wasm/android/ios/windows | multiplatform |
| deny | `EmbarkStudios/cargo-deny-action@v2` or `cargo deny check` | all |
| unused deps | `cargo machete` | optional |
| semver | `cargo semver-checks` (see `release.md`) | published libraries |
| miri | `cargo +nightly miri test -p <crate>` (uncached) | crates with unsafe |

Run `fmt` with nightly only when `rustfmt.toml` uses unstable options (winit, niri, freya do; freya pins the nightly in a separate `rust-toolchain-nightly.toml`).

## Workflow-level settings

```yaml
on:
  push: { branches: [main] }
  pull_request:
  workflow_dispatch:
  schedule: [{ cron: "0 6 * * 1" }]   # weekly: catches toolchain/dependency drift

permissions: { contents: read }

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  CARGO_TERM_COLOR: always
  RUSTFLAGS: -D warnings
  RUSTDOCFLAGS: -D warnings
```

- `RUSTFLAGS: -D warnings` turns rustc warnings into errors **only in CI**, keeping local iteration pleasant and downstream users unaffected. Changing `RUSTFLAGS` invalidates the cache, so keep it identical across jobs.
- Alternative for libraries: `#![cfg_attr(clippy, deny(warnings))]` in `lib.rs` (winit) — strict under clippy without breaking dependents.
- Matrices use `fail-fast: false` so one OS failure does not hide the others.
- Set `timeout-minutes` per job (the user's sismo uses 60–120).
- Path filters (`paths-ignore: ["**.md", "docs/**"]`) skip CI for doc-only changes; careful — required status checks then never report. Prefer filters on expensive optional jobs only.

## Toolchains and caching

- `dtolnay/rust-toolchain@stable` / `@nightly` / `@1.85.0` — the ref *is* the toolchain. `with: components: clippy, rustfmt` and `targets: wasm32-unknown-unknown`.
- When `rust-toolchain.toml` pins a version, rustup honors it automatically; the action just installs rustup.
- `Swatinem/rust-cache@v2` (v2.9.3 current): caches `~/.cargo` and `target/`. Use `shared-key` across jobs with identical builds and `save-if: ${{ github.ref == 'refs/heads/main' }}` so PRs read but do not write (freya).
- Never cache Miri jobs (see `ci-hardening.md`).
- Install tools as prebuilt binaries with `taiki-e/install-action@v2` (`tool: nextest`, `cargo-hack`, `cargo-deny`, `typos-cli`, `cargo-machete`) instead of `cargo install` (minutes saved per job).
- **Do not use `actions-rs/*`** — archived and deprecated (still present in the user's sss and bevy template; migrate).

## Target matrix (multiplatform)

Build or check every target you ship; run tests where the target can execute them.

```yaml
test:
  strategy:
    fail-fast: false
    matrix:
      os: [ubuntu-latest, windows-latest, macos-latest]
  runs-on: ${{ matrix.os }}

targets:
  strategy:
    fail-fast: false
    matrix:
      target: [wasm32-unknown-unknown, aarch64-linux-android, aarch64-apple-ios]
  runs-on: ${{ matrix.target == 'aarch64-apple-ios' && 'macos-latest' || 'ubuntu-latest' }}
  steps:
    - uses: actions/checkout@v7
    - uses: dtolnay/rust-toolchain@stable
      with: { targets: "${{ matrix.target }}" }
    - uses: Swatinem/rust-cache@v2
      with: { key: "${{ matrix.target }}" }
    - run: cargo check --workspace --lib --target ${{ matrix.target }}
```

- Android linking needs the NDK; reuse whatever toolchain the project already uses (local NDK, cargo-ndk, Gradle plugin, container image, framework, Nix) — never impose one (`multiplatform.md#android`).
- winit also tests feature subsets per platform (X11-only, Wayland-only) and docs.rs targets.
- egui runs tests on macOS "because it will run with an actual GPU"; GUI smoke tests on Linux can use `xvfb-run` (freya).

## Scheduled and supply-chain jobs

- **Audit on dependency changes**: trigger on `paths: [Cargo.toml, Cargo.lock, "**/Cargo.toml", deny.toml]` plus daily cron (freya `audit.yml`).
- **Upstream drift**: weekly job runs `cargo update` (no commit), then `cargo deny check` and tests — finds breakage from new dependency releases early.
- **Long property tests**: monthly cron with `PROPTEST_CASES=200000` in release mode (niri).
- Dependabot or Renovate for both `cargo` and `github-actions` ecosystems.

## Nix-based CI (the user's pipelines)

Two variants exist in the user's repos:

1. **Dev-shell commands** (ansync, database-mcp): install Nix, then run the same gate inside the flake's devShell so CI uses the exact toolchain and system libs:

   ```yaml
   - uses: cachix/install-nix-action@v30
   - run: nix develop --command cargo clippy --workspace --all-targets --locked -- -D warnings
   - run: nix develop --command cargo test --workspace --locked
   ```

2. **crane derivations + attic** (sismo, notinplus): build `.#cargoArtifacts` (dependencies only) and the package, then push both to the attic cache so the next run and the release reuse them. sismo wraps this in local composite actions `setup-nix` (installs Nix, trusts `cache.sergioribera.rs`, logs in with `ATTIC_TOKEN` when present — fork PRs read only) and `attic-push`.

   ```yaml
   - id: nix
     uses: ./.github/actions/setup-nix
     with: { attic-token: "${{ secrets.ATTIC_TOKEN }}" }
   - run: nix build -L .#cargoArtifacts -o result-deps
   - run: nix build -L .#<package> -o result-app
   ```

   The Windows build is a Nix cross build on an Ubuntu runner (`.#<pkg>-windows`), catching Windows-only compile errors without a Windows runner. `nix flake check` runs crane's clippy/fmt/test checks (`nix.md`).

Keep a plain-cargo job too (fast feedback, rust-cache) — sismo runs both.

## Local mirror

- `scripts/check.sh` in this skill, or a `just ci` recipe (`../templates/justfile`) that runs fmt-check, clippy, tests, doctests, docs, deny in the same order with the same flags.
- egui's `scripts/check.sh` and freya's `just c-ci` are the models: CI calls the script, so drift is impossible.

## Optional: performance gate

For apps instrumented with sismo, record a scenario in CI and gate on regressions with `sismo summary --json` or `sismo compare a.sismo b.sismo --metric p95` (see `ecosystem.md`). For libraries, criterion/divan benchmarks on a dedicated runner (shared runners are noisy — treat results as trends, not hard gates).

## Anti-patterns

- Lints enforced only by CLI flags in CI; clippy without `-D warnings`.
- `cargo test` without `--locked`; no doctest run when using nextest.
- One giant sequential job.
- `actions-rs/*`, `actions/cache` hand-rolled for cargo when rust-cache fits.
- `cargo install` of tools on every run.
- No MSRV job while declaring `rust-version`.
- CI-only scripts nobody can run locally.
- Caching across trust boundaries (fork PRs writing cache, Miri artifacts).

## Checklist

- [ ] fmt, typos, clippy (-D warnings, --all-targets --all-features --locked), docs, tests + doctests, deny.
- [ ] MSRV job matching `rust-version`; feature check with cargo-hack.
- [ ] Target matrix covers every shipped target.
- [ ] `permissions: contents: read`, `concurrency` cancel, `fail-fast: false`, timeouts.
- [ ] rust-cache with `save-if` on main; tools via install-action.
- [ ] Scheduled drift/audit job; Dependabot/Renovate for cargo and actions.
- [ ] Local script/recipe identical to CI.

Related: `ci-hardening.md`, `supply-chain.md`, `release.md`, `nix.md`, `testing.md`, `multiplatform.md`, `../templates/ci.yml`, `../templates/justfile`.
