---
name: rustlikeapro
description: Engineering standards, decision rules, templates and CI/CD for production-grade Rust. Use BEFORE writing, modifying, reviewing or scaffolding any Rust code — whenever the task touches a .rs file, Cargo.toml, a crate or workspace, clippy/rustfmt/lints, cargo-deny, MSRV, tests or benchmarks, unsafe/FFI, async (tokio), releases or publishing crates, CI for Rust, Nix builds of Rust, cross-compilation or multiplatform (Android/iOS/desktop/wasm) Rust apps — even if "best practices" is never mentioned. Also applies to Rust snippets inside larger tasks. Not needed for merely explaining existing Rust code.
license: MIT
compatibility: Requires a Rust toolchain (rustup/cargo). Scripts need bash >= 4 and GNU coreutils/sed (macOS: install bash and gnu-sed via Homebrew); optional tools (cargo-deny, cargo-nextest, typos, cargo-hack) are detected and reported when missing.
metadata:
  version: "1.0.0"
  verified-against: "rust 1.99, clippy 1.99, cargo-deny 0.20, edition 2024 (2026-11)"
---

# rustlikeapro

Standards for Rust that is **explicit, readable at a glance, reproducible, modular and hard to break**. If code fails any of those, it needs rework — cleverness is not a substitute for clarity.

This file holds the hard rules and the decision tables. Depth lives in `references/` — load a reference only when the task needs it (index at the end). Ready-to-copy configs live in `templates/`; runnable gates live in `scripts/`.

## 0. Before writing code

1. **Read the project's own rules first**: `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `PLAN.md`, `docs/adr/`. Project rules override this skill. Decisions listed as "rejected" must not be re-proposed.
2. **Read the manifest**: edition, `rust-version`, `[workspace.lints]`, `clippy.toml`, `rust-toolchain.toml`, features. Respect what is declared; never silently upgrade edition/MSRV.
3. **Study real usage before shaping types** (see §2). Prefer semantic tooling (rust-analyzer via LSP/MCP, a code-graph index, "find references") over grep when available; fall back to reading code. Never invent CLI flags — check `--help`.
4. **Pick the profile** (it changes lints, CI and error rules):

| Profile | Signals | Key differences |
|---|---|---|
| **Library** | published crate, `lib.rs` only, used by others | `missing_docs`, semver discipline, `#[non_exhaustive]`, no reporting crates, no `print*`, MSRV job, docs.rs config |
| **Binary / CLI / service** | `main.rs`, deploys or ships to users | reporting layer allowed in `main`, `panic = "abort"` ok, tracing subscriber, release bundling |
| **App (GUI / multiplatform)** | UI framework, mobile/desktop targets | target matrix, platform abstraction, bundling, perf profiling, frame-time budgets |

## 1. Project conventions (non-negotiable defaults)

- **Edition**: respect `Cargo.toml`. New projects: edition 2024, `resolver = "3"`, explicit `rust-version` (default 1.88: edition 2024 needs ≥ 1.85, let chains need ≥ 1.88), `rust-toolchain.toml` with `profile = "minimal"` + `rustfmt`, `clippy`. **Before using a std/language feature, check it is stable at the declared `rust-version`** (e.g. `cfg_select!` 1.95, `assert_matches!` 1.96); clippy's MSRV-aware lints read `rust-version` too.
- **`Cargo.lock` is committed in every project**, libraries included; CI builds with `--locked`.
- **Lints live in the manifest, not on the command line.** `[workspace.lints]` + `[lints] workspace = true` in every member, so editors, CI and every agent share one config. Baseline in `templates/Cargo.workspace.toml`:
  - `clippy::pedantic` at warn, `priority = -1`; nursery is opt-in per project.
  - `unsafe_code = "forbid"` at workspace level; FFI crates override locally with justification.
  - Cherry-picked restriction lints: `unwrap_used`, `dbg_macro`, `todo`, `print_stdout`/`print_stderr` (libs), `undocumented_unsafe_blocks`, `allow_attributes_without_reason`.
  - Gate: `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`. Lint flags passed only on the command line (`-W clippy::pedantic`) are invisible to editors, rust-analyzer, `cargo check` and other agents — the manifest is the single source of truth.
- **Suppressing a lint**: `#[expect(lint, reason = "…")]` by default — it fails when the lint stops firing, so stale suppressions die. `#[allow(lint, reason = "…")]` only when the lint fires conditionally (per cfg/target/feature, or inside macro expansions), where `expect` would be unfulfilled. A **bare `#[allow]`** — one without `reason` — is never acceptable (`allow_attributes_without_reason = "deny"`). Suppress at the narrowest scope; crate-wide allows go in the manifest with a comment.
- **Policy as config**: project bans (`std::thread::spawn` without a name, `println!` in libs, a footgun API) go in `clippy.toml` `disallowed-methods`/`disallowed-types` with a `reason`, so tooling enforces what prose only asks for.
- **Dependencies are added with `cargo add`, never with a version typed from memory.** Requirement is `major.minor` (`thiserror = "2.0"`, `rand = "0.9"`; full version only for `0.0.x`): the minor floor documents the API level, caret semantics let `cargo update` pull patches, `Cargo.lock` pins the exact build. Workspaces declare the version once in `[workspace.dependencies]`; members use `workspace = true`. `scripts/add-dep.sh <crate> [-p member] [--features …]` does all of this and warns when the latest release exceeds the project's MSRV. Policy: `references/maintenance.md`.
- **Formatting**: `cargo fmt`. Never hand-format against rustfmt.
- **Every non-obvious config line gets a comment explaining why** (`[patch]`, profile tweaks, lint allows, cargo aliases).

## 2. Types first

Lean on the type system as the primary design tool: types are documentation, validation and architecture at once. Before a runtime check, a stringly-typed field or a new abstraction layer, ask whether a type can encode the invariant (newtype, enum, typestate, `NonZero*`, generics with bounds). A runtime check that a well-chosen type would have made impossible is an unfinished design.

**Model types from actual usage, not guesses.** Before designing or refactoring a type, check how its fields and methods are really used: is a field ever reassigned or only read? Is an `Option` ever genuinely `None`, or does the `None` arm force defensive code downstream? Do two structs always travel together? Owned vs borrowed, `Option<T>` vs `T`, one struct vs two — these are conclusions from usage, never defaults. The analysis is per case and non-negotiable.

- Newtypes for IDs and units (`struct DeviceId([u8; 16])`, `struct Millis(u64)`); never pass raw `u64`/`String` where two meanings can be swapped.
- Enums over boolean flags and over `Option` combinations that encode states.
- Typestate when an operation is only valid in some state (builder that cannot `build()` before required fields).
- Sealed traits for closed sets you do not want implemented downstream.

## 3. Errors

Errors are public API and get the same design care as types. Deep dive: `references/errors.md`.

| Where | Rule |
|---|---|
| Libraries and every internal/domain layer | Typed `enum` per domain/module (`thiserror` or hand-written). Each variant names one failure mode and carries context (path, expected vs actual, `#[source]`). |
| Binary `main` / outermost reporting layer | One reporting type is allowed: a typed top-level enum, `miette` (diagnostics with spans) or `color-eyre` (pretty CLI reports). `anyhow` is discouraged, never in library or domain code, never in a public signature. |
| Stringly variants (`Error(String)`) | Last resort, only for a truly opaque external failure. |

- Propagate with `?`; convert at module boundaries with `From` so errors compose instead of leaking internals.
- **Context over bare `#[from]`**: a single `#[from] io::Error` used by five operations loses *which* operation and *which* path failed. Prefer variants like `ReadConfig { path: PathBuf, #[source] source: io::Error }`.
- Public fallible functions document `# Errors` (pedantic requires it for public items).

### Panics

A panic means **a bug**, never an expected failure.

- `unwrap()` is denied outside tests (`clippy::unwrap_used` + `allow-unwrap-in-tests = true` in `clippy.toml`).
- `expect()` is allowed only when the message states the invariant that makes failure impossible: `.expect("invariant: regex literal is valid")`. Prefer restructuring so the type system proves it (split the type, `NonZero*`, exhaustive match, `let … else`).
- Functions that can panic document `# Panics`.
- Hidden panics count too: slice indexing (`v[i]` → `get`), `RefCell::borrow_mut`, integer overflow (`checked_*`/`saturating_*` where input is untrusted), `Duration - Duration` and `Instant ± Duration` (use `checked_sub`/`checked_add`; `Instant - Instant` saturates).
- Tests, build scripts and examples may `unwrap` — a panic is the right response there.

## 4. Style and idioms

- **Iterators over index loops** (`iter().enumerate()`, `zip`, `filter_map`, `fold`): no off-by-one, fewer bounds checks. Explicit loops only when genuinely clearer (complex early exit, in-place mutation).
- **Exhaustive matching**: no `_ =>` on enums you own — a new variant must break every match site at compile time. Exception: foreign `#[non_exhaustive]` enums require a wildcard; make it explicit (log/return an error), never silently ignore.
- Use modern control flow: `let … else` for early returns, let chains (edition 2024, rust-version ≥ 1.88) instead of nested `if let`.
- **Unused parameters**: never `let _ = param;`. Prefix (`_ctx`) when a trait signature requires it; otherwise remove the parameter. No `#[allow(unused_*)]` / `dead_code` to hide leftovers — delete them.
- `#[must_use]` on constructors, pure functions and builders where ignoring the result is a bug.
- **Constructors** — priority: `#[derive(Default)]` > manual `Default` > `From`/`TryFrom` > builder (`T::default().with_x(..)`) > `fn new(..)`.
  - A zero-argument `new()` is a smell: implement (ideally derive) `Default` instead. If a `new()` exists anyway (e.g. it must be `const fn`), `Default` must exist too (`clippy::new_without_default`).
  - Conversions from existing data are `From`/`TryFrom` — they compose with `?`, `.into()` and bounds.
  - `fn new(...)` is reserved for constructors that enforce invariants or take several unrelated arguments. Judge per case; never invent a `From` impl whose meaning is not an obvious conversion.
- Prefer `#[derive(...)]` over manual impls; a manual impl means the derived behavior is wrong, and that divergence deserves a comment.
- **API surface**: accept `&str`, `&[T]`, `&Path`/`impl AsRef<Path>` at boundaries; return concrete owned types or `impl Iterator`. `impl Into<T>` only where it removes real friction (it hurts inference and bloats monomorphization). Builders for many optional fields. Details: `references/api-design.md`.
- Visibility is API design: as private as possible; `pub(crate)` before `pub`; enable `unreachable_pub`.

## 5. Architecture and structure

- **Prefer abstractions over loose functions.** A free function is the last resort, not the first reach. Priority for new behavior: method on the relevant type (`impl Struct`) → trait / extension trait (also on foreign types) → improve the construction/conversion flow (`Default`, `From`, builder) → only then a standalone function. Scattered helpers and near-duplicates are exactly what this avoids; a small private `impl Struct` block next to the type beats a loose helper, even for one function.
- **State shared across functions is a type asking to exist.** When two or more functions thread the same value (client, config, pool, buffer), introduce a type that owns it and exposes the behavior as methods. Related configuration (limits, retries, timeouts) then lives there without churning signatures.
- **Don't create files reflexively.** New files are for new concepts; first check whether extending an existing type serves the need. A UI component, backend or domain concept with its own state *is* a new concept.
- **Module layout: `foo.rs` + `foo/`, never `foo/mod.rs`** (except tiny projects or `#[path]` platform tricks). The root file sits beside its directory and holds the module's base abstractions, base structs and re-exports; submodules stay encapsulated behind it. The module tree should read as a description of the system.
- **Workspaces**: `crates/<proj>-core` (shared types), `crates/<proj>-<domain>`, `bins/` or `tools/` when useful. All versions in `[workspace.dependencies]`, members use `dep.workspace = true`. Duplicated type definitions across crates are a smell — they drift. Details: `references/workspace.md`.
- **Backends behind traits + features**: one trait per swappable backend (`Transport`, `AudioBackend`), implementations behind additive cargo features. Mutually exclusive features fail with `compile_error!` and a fix-it message — and then cannot use `--all-features` in gates (see §12).
- **Generics vs `dyn`**:

| Use generics (default) | Use `dyn Trait` |
|---|---|
| Single concrete type per call site, hot paths, zero-cost needed | Heterogeneous collections, plugin/ABI boundaries (`stabby`, `libloading`), measured monomorphization bloat, compile-time pressure |

Never introduce `dyn` just to shorten signatures.

## 6. Async and concurrency

Deep dives: `references/async.md`, `references/concurrency.md`.

- `tokio` is the default runtime for applications. **Libraries should be executor-agnostic** when feasible (channels such as `flume`, no runtime spawn inside the lib), or gate runtime integration behind a feature.
- List tokio features explicitly (`default-features = false, features = [...]`); never `features = ["full"]` in a library.
- Never block inside async: blocking I/O, `reqwest::blocking`, heavy CPU → async API or `spawn_blocking`. Calling `Runtime::block_on` (or `Handle::block_on`, `reqwest::blocking`) from inside a runtime, or dropping a runtime in async context, **panics**.
- **Locks**: `std::sync::Mutex` (or `parking_lot`) is the default for short critical sections that do not cross `.await`. Use `tokio::sync::Mutex` only when the guard must be held across `.await`. A std guard across `.await` makes the future `!Send` / risks deadlock — `clippy::await_holding_lock` catches it.
- Concurrency over tasks: `tokio::task::JoinSet` before pulling in `futures::join_all`; add `futures` only for real combinator needs (`StreamExt`, `buffer_unordered`).
- Every `tokio::select!` branch must be **cancellation-safe**; document when it is not.
- CPU parallelism: `rayon`, not async. Name threads (`std::thread::Builder::new().name(..)`).
- Shared state: prefer message passing; `Arc<Mutex<T>>` is a decision, not a reflex.

## 7. Unsafe and FFI

`#![forbid(unsafe_code)]` by default. Exceptions (FFI, SIMD, a justified low-level primitive) live in a dedicated crate or module that opts out locally. Every `unsafe` block carries a `// SAFETY:` comment naming the invariants and who upholds them; if the comment cannot be written convincingly, the code is unsound — redesign. Enforce with `undocumented_unsafe_blocks` and `unsafe_op_in_unsafe_fn`; run Miri on unsafe-bearing crates. Edition 2024 syntax: `#[unsafe(no_mangle)]`, `unsafe extern "C" { … }`. Keep one narrow FFI boundary (one frame protocol), never per-feature trampolines. Details: `references/unsafe-ffi.md`.

## 8. Observability

`tracing` for diagnostics (`info!`, `error!`, spans with fields), never `println!`/`eprintln!` in libraries or long-running binaries. **Libraries emit events, never install a subscriber**; binaries install `tracing-subscriber` with `EnvFilter`. Plain printing only for CLI *output* meant for the user. Details: `references/observability.md`.

## 9. Comments, docs and decisions

- All code, identifiers, comments and docs are in **English**, whatever the conversation language.
- Comment sparingly: delete comments that restate code. Comments explain **why** — a constraint, a workaround with a link, a SAFETY justification, a `TODO(owner): …`.
- Public items get `///` docs with `# Errors`, `# Panics`, `# Safety` and an example where useful (doc tests run in CI). Libraries enable `missing_docs`.
- **Design decisions, trade-offs and rejected approaches go in the project's decision log**, not scattered in source comments: `AGENTS.md` (portable across agents; `CLAUDE.md` can be the one line `@AGENTS.md`) or `docs/adr/`. Append, never rewrite history; record "rejected paths (do not re-propose)". Template: `templates/AGENTS.md`.

## 10. Agent failure modes (self-check)

Mistakes LLM agents make in Rust — check your diff for them. Full list with fixes: `references/llm-antipatterns.md`.

- `.clone()` to silence the borrow checker instead of fixing ownership.
- `Arc<Mutex<_>>` / `Rc<RefCell<_>>` by reflex.
- Inventing crates, versions, features or APIs — verify on crates.io/docs.rs or in `~/.cargo/registry` before using.
- `unwrap()` in examples that get copied into production paths.
- `String` everywhere instead of `&str`/newtypes; `Vec` returned where an iterator suffices.
- Adding a dependency for something std or an existing dep already does.
- `#[allow(...)]` to make clippy pass instead of fixing the code.
- Claiming "tests pass" without running them.

## 11. Ecosystem suggestions (optional — suggest, never impose)

Mention one only when its trigger matches; explain why in one line and let the user decide. Details, commands and limits: `references/ecosystem.md`.

| Tool | Suggest when | Don't suggest when |
|---|---|---|
| **istmo** | Rust app must run on Android and/or iOS (± desktop) and needs native APIs (sign-in, biometrics, camera, share, file picker) or someone is hand-writing JNI/Swift FFI | desktop-only, web/wasm, pure libraries/servers, needs a stable API today (early alpha) |
| **sismo** | "why is it slow/janky", frame drops, perf regression between builds (`sismo compare`), logs/perf from devices you cannot reach (flight recorder), CI perf gates (`sismo summary --json`) | micro-benchmarks (criterion/divan), distributed server tracing (OpenTelemetry), zero-instrumentation profiling (perf/samply) |
| **nix-bundle-app** | Nix-built project needs native installers (deb, rpm, AppImage, dmg, pkg, msi, NSIS) or a release matrix with install scripts and checksums | project does not use and won't adopt Nix (use cargo-dist / cargo-packager), mobile APK/IPA, crates.io-only libraries |

## 12. Definition of done

Run `scripts/check.sh` (the local gate; prints every skipped step). The feature-powerset (`cargo hack`) and the MSRV build run in CI; `check.sh --msrv` runs the latter locally when that toolchain is installed. Equivalent manual gate:

1. `cargo fmt --all --check`
2. `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`
3. `cargo nextest run --workspace --all-features --locked` (or `cargo test`) **and** `cargo test --doc --workspace --all-features` (nextest skips doc tests)
4. `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps --all-features` (libraries)
5. `cargo deny check` when `deny.toml` exists

Projects with mutually exclusive features (`compile_error!` guards) cannot use `--all-features`: pass an explicit set everywhere (`check.sh --features a,b`, CI `--features …`) and cover the rest with `cargo hack --each-feature`.
6. Re-read the diff: every error typed and contextual? any `unwrap` or uncommented `expect`? any bare `#[allow]`? any file or dependency that did not need to exist? any comment that says nothing? any decision that belongs in the decision log?

**Never claim a step passed without running it.** If a step could not run (missing tool, no network, platform), say so explicitly in the final report.

To bring an existing repo up to standard, run `scripts/audit.sh` first — it lists missing hygiene and the template that fixes each gap.

## Reference index — read X when Y

| Read | When |
|---|---|
| `references/errors.md` | designing error types, reporting in binaries, exit codes |
| `references/api-design.md` | public API, semver, features, `non_exhaustive`, sealed traits, docs |
| `references/testing.md` | adding tests, snapshots, property tests, coverage, mutation testing |
| `references/async.md` | tokio, cancellation, select!, runtime setup, executor-agnostic libs |
| `references/concurrency.md` | threads, rayon, atomics, Send/Sync, channels, locks |
| `references/performance.md` | benchmarks, allocations, profiles, profiling, binary size |
| `references/unsafe-ffi.md` | any `unsafe`, FFI, bindgen/cbindgen/cxx, Miri |
| `references/workspace.md` | creating/restructuring a workspace, dependency inheritance, profiles |
| `references/supply-chain.md` | evaluating deps, cargo-deny, audit, vet, unused deps, `[patch]` |
| `references/maintenance.md` | adding/upgrading deps (`cargo add`, `major.minor`), Dependabot, refreshing lints/deny/actions, maintaining this skill |
| `references/ci-cd.md` | writing or fixing CI workflows, job matrix, caching |
| `references/ci-hardening.md` | permissions, SHA pinning, secrets, zizmor, Miri cache leak |
| `references/release.md` | versioning, changelog, cargo-release/release-plz, dist, publishing |
| `references/observability.md` | tracing setup, spans, log levels, metrics |
| `references/cli-config.md` | clap, config files, env vars, exit codes |
| `references/serialization.md` | serde, wire formats, versioning, `deny_unknown_fields` |
| `references/multiplatform.md` | cfg/platform abstraction, cross-compilation, Android/iOS/wasm/Windows |
| `references/nix.md` | flake, crane, rust-overlay/fenix, devShell, binary cache |
| `references/security.md` | secrets, untrusted input, crypto, DoS limits |
| `references/llm-antipatterns.md` | self-review of agent-written Rust |
| `references/ecosystem.md` | istmo, sismo, nix-bundle-app details |
| `references/frameworks/freya.md` | working in a Freya project (version-stamped) |

Templates (`templates/`): `Cargo.workspace.toml`, `clippy.toml`, `rustfmt.toml`, `deny.toml`, `rust-toolchain.toml`, `typos.toml`, `justfile`, `ci.yml`, `release.yml`, `release-plz.toml`, `dependabot.yml`, `AGENTS.md`, `flake.nix`.

Scripts (`scripts/`): `check.sh` (definition-of-done gate), `audit.sh` (repo hygiene report), `add-dep.sh` (dependency policy), `refresh.sh` (keeps this skill's lints, deny schema, action tags and version mentions current — run on every Rust release).
