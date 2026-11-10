# Workspaces, manifests and build profiles

> Read when: creating a project or workspace, splitting a crate, adding a member, touching `[workspace.*]` tables, dependency inheritance, build profiles, cargo aliases, `[patch]`, or platform-specific dependencies.

## Layout

```
my-project/
  Cargo.toml              # virtual manifest: [workspace] only
  Cargo.lock              # committed in every project (libraries too); CI uses --locked
  rust-toolchain.toml
  clippy.toml  rustfmt.toml  deny.toml  typos.toml  justfile
  AGENTS.md               # decision log + agent rules (CLAUDE.md -> "@AGENTS.md")
  crates/
    my-project-core/      # shared types, errors, traits — no heavy deps
    my-project-proto/     # wire format / messages
    my-project-transport/ # one domain per crate
    my-project-macros/    # proc-macros (must be their own crate)
  bins/ or tools/         # executables, xtask, dev tools
  examples/  benches/  tests/
```

- Crate names: `<project>-core`, `<project>-<domain>` in kebab-case (projects such as istmo, sismo or ferricast follow this). Import names become `my_project_core`.
- **`-core` holds what more than one member needs**: domain types, error enums, traits, newtype IDs. Duplicated type definitions across crates drift; conversions between near-identical types are noise.
- Split crates by **compile boundary and dependency weight**, not by file count: a proc-macro, an FFI crate (allowed to use unsafe), a heavy UI crate, a crate published separately.
- Do not create a crate per module "for cleanliness" — each crate costs compile time, a manifest and a version.

## Root manifest

Start from `../templates/Cargo.workspace.toml`. Essentials:

```toml
[workspace]
resolver = "3"
members = ["crates/*", "bins/*"]

[workspace.package]
edition = "2024"
rust-version = "1.88"   # let chains need 1.88
version = "0.1.0"
license = "MIT OR Apache-2.0"
repository = "https://github.com/<owner>/<repo>"

[workspace.dependencies]
my-project-core = { path = "crates/my-project-core", version = "0.1.0" }
# Versions come from `cargo add` (major.minor), never typed from memory.
thiserror = "2.0"
tracing = "0.1"
tokio = { version = "1.54", default-features = false }

[workspace.lints.rust]
unsafe_code = "forbid"
unreachable_pub = "warn"
missing_debug_implementations = "warn"

[workspace.lints.clippy]
pedantic = { level = "warn", priority = -1 }
```

Member manifest:

```toml
[package]
name = "my-project-transport"
edition.workspace = true
rust-version.workspace = true
version.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
my-project-core.workspace = true
tokio = { workspace = true, features = ["net", "rt"] }

[lints]
workspace = true
```

Rules:

- **Every** version lives in `[workspace.dependencies]`; members write `dep.workspace = true` and only add `features`/`optional`.
- Intra-workspace path deps also carry `version` so the crates can be published.
- Group `[workspace.dependencies]` by purpose with comments (`# async`, `# serialization`, `# ui`) once the list grows.
- `resolver = "3"` (default for edition 2024, must be explicit in a virtual manifest) is **MSRV-aware**: it prefers dependency versions compatible with `rust-version`. Keep `rust-version` truthful — the MSRV CI job proves it (`ci-cd.md`).
- **Default features of inherited dependencies:** a member cannot turn off default features the workspace entry leaves on — on edition 2024 a member-side `default-features = false` on such an entry is an error (earlier editions only warned and ignored it). Declare `default-features = false` in `[workspace.dependencies]` and enable features per member. See the Cargo reference, "Inheriting a dependency from a workspace".
- Tokio and other big crates: explicit feature lists, never `"full"` in libraries.

## Lint inheritance

- `[workspace.lints]` + `[lints] workspace = true` in every member. A member needing different lints (FFI crate) drops `workspace = true` and writes its own **complete** `[lints.rust]` / `[lints.clippy]` tables (copy the baseline, change `unsafe_code`, comment why) — inheritance is all or nothing, and Cargo rejects `[lints.rust]` next to `workspace = true`. Same recipe as `unsafe-ffi.md`.
- Lint groups need `priority = -1` so individual overrides win; otherwise clippy reports `lint_groups_priority`.
- Lints never apply to dependencies (cargo passes `--cap-lints`).
- See `../templates/Cargo.workspace.toml` for the full baseline and `../templates/clippy.toml` for config-level policy (`allow-unwrap-in-tests`, `disallowed-methods`; clippy reads the MSRV from `rust-version`).

## Build profiles

A proven baseline (used in projects such as sismo and notinplus); comment each line in the real manifest:

```toml
[profile.dev]
opt-level = 1            # usable debug builds without killing incremental compile
debug = "limited"        # smaller debug info, faster links

[profile.dev.package."*"]
opt-level = 3            # dependencies optimized once; own code stays fast to rebuild

[profile.release]
lto = "thin"             # fat LTO made the final link the longest CI step for little gain
codegen-units = 1
strip = "symbols"
panic = "abort"          # apps only — libraries must not force this on users

[profile.profiling]      # for sismo / perf / samply: release speed, readable stacks
inherits = "release"
debug = "line-tables-only"
strip = "none"
```

- `panic = "abort"` belongs in **binary** workspaces; it removes unwinding (smaller, faster) but `catch_unwind` stops working.
- Consider `overflow-checks = true` in release for code handling untrusted arithmetic (niri does this).
- Per-package overrides for hot dependencies in dev (`[profile.dev.package.insta] opt-level = 3`, codec crates in ferricast).
- Since Rust 1.90, `lld` is the default linker on `x86_64-unknown-linux-gnu`; do not add mold/lld config unless measured.

## Cargo config and aliases

`.cargo/config.toml` is for **project-wide, reproducible** settings only. Every alias gets a comment explaining when to use it:

```toml
[alias]
# Minimal feature set used by the CI "min" job; mirrors what embedded users build.
b-min = "build --no-default-features --features minimal"
# xtask pattern: repo automation written in Rust (egui uses this).
xtask = "run --quiet --package xtask --"
```

- Do not commit machine-specific settings (local linker paths, `target-dir` on a personal disk).
- Since 1.94, `include` lets a config file pull others — useful for an optional `.cargo/local.toml` that is gitignored.

## `[patch]`

```toml
[patch.crates-io]
# Upstream PR https://github.com/<org>/<crate>/pull/123 (fixes Wayland IME);
# drop once a release containing it is published.
winit = { git = "https://github.com/<fork>/winit", rev = "<sha>" }
```

- Always pin `rev` (never a moving branch) and always comment the reason plus the removal condition.
- `[patch]` only applies in the root workspace: it is **not** applied for downstream users of a published crate, so a library that only works with the patch is broken for everyone else. Keep patches in binary workspaces, or wait for the upstream release before publishing.
- `cargo deny` with `[sources]` must allow that git source explicitly (`supply-chain.md`).

## Platform-specific dependencies

```toml
[target.'cfg(target_os = "android")'.dependencies]
jni = { workspace = true }

[target.'cfg(any(target_os = "linux", target_os = "freebsd"))'.dependencies]
wayland-client = { workspace = true, optional = true }
```

- Gate the code with the same `cfg`; prefer `cfg_aliases!` in `build.rs` for long expressions (winit pattern, see `multiplatform.md`).
- Declare custom cfgs for `check-cfg`: `[lints.rust] unexpected_cfgs = { level = "warn", check-cfg = ["cfg(docsrs)"] }`.

## Features

- Additive only: enabling a feature must never remove API or change behavior of other features.
- Mutually exclusive choices fail loudly: `#[cfg(all(feature = "a", feature = "b"))] compile_error!("features `a` and `b` are mutually exclusive; pick one");`
- Name optional-dependency features explicitly with `dep:` syntax (`tracing = ["dep:tracing"]`) so internal crate names don't leak as features.
- CI checks each feature in isolation with `cargo hack` (`ci-cd.md`).

## Anti-patterns

- Versions repeated in member manifests instead of `[workspace.dependencies]`.
- `foo/mod.rs` crates; a crate per tiny module; a `utils` / `common` crate that becomes a junk drawer (that is what `-core` with real domain types replaces).
- `[patch]` pointing at a branch, or without a comment.
- `panic = "abort"` or `lto = "fat"` copied into library manifests.
- `tokio = { features = ["full"] }` in a library.
- Lint configuration passed only on the command line.
- `Cargo.lock` in `.gitignore`.

## Checklist

- [ ] Virtual root manifest, `resolver = "3"`, `[workspace.package]` inherited by members.
- [ ] All versions in `[workspace.dependencies]`; intra-workspace deps carry `version`.
- [ ] `[workspace.lints]` with `lints.workspace = true` everywhere (or a complete local table with a reason).
- [ ] `rust-version` declared and verified by CI.
- [ ] Profiles commented; `panic = "abort"` only for binaries; a `profiling` profile exists for perf work.
- [ ] Every alias and `[patch]` entry commented with reason and exit condition.
- [ ] Features additive, `dep:` syntax, exclusive ones guarded by `compile_error!`.
- [ ] `Cargo.lock` committed.

Related: `supply-chain.md`, `ci-cd.md`, `multiplatform.md`, `release.md`, `nix.md`, `../templates/Cargo.workspace.toml`.
