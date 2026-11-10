# Supply chain: dependencies, licenses and advisories

> Read when: adding, upgrading or removing a dependency, writing `deny.toml`, setting up audit jobs, using `[patch]`/git sources, or reacting to a security advisory.

Every dependency is code you ship and code that runs on your machine at build time (`build.rs`, proc-macros). Treat adding one as a design decision.

## Before adding a dependency

1. **Does std or an existing dependency already do it?** Check `Cargo.lock` — the crate may already be in the tree. Common std replacements: `LazyLock`/`OnceLock` (not `lazy_static`/`once_cell`), `std::thread::scope`, `Option::is_none_or`, `assert_matches!` (1.96), `cfg_select!` (1.95).
2. **Verify it exists and is the right crate.** Look it up on crates.io / docs.rs or in `~/.cargo/registry`. Agents hallucinate crate names; attackers register similar names (the 2026 `arrayref` compromise pulled in a malicious `proc-macro1` build dependency — note the near-miss with `proc-macro2`).
3. **Assess**: maintainers and recent activity, download count, number of transitive deps (`cargo tree -p <crate> -e normal`), `build.rs` / proc-macro presence, `unsafe` usage, license.
4. **Minimize features**: `default-features = false` plus exactly what you need.
5. **Add it with `cargo add` (or `../scripts/add-dep.sh`), never with a version typed from memory**, as a `major.minor` requirement (`"2.0"`, `"0.8"`) so `cargo update` keeps patches flowing. In workspaces the version goes to `[workspace.dependencies]`, not to a member directly (`workspace.md`). Full policy, MSRV interaction and minimal-versions check: [maintenance.md](maintenance.md#adding-dependencies).
6. Prefer pure-Rust TLS: `rustls` with `default-features = false` over OpenSSL (easier cross-compilation, no system lib, smaller attack surface). The user's ansync rules forbid OpenSSL outright.

## Lockfile discipline

- Commit `Cargo.lock` for every project (binaries and libraries).
- CI builds with `--locked` so a stale lockfile fails instead of silently resolving new versions.
- Upgrade deliberately: `cargo update -p <crate>` or a scheduled job (below), reviewed like code.
- Libraries: verify lower bounds with `cargo +nightly update -Z minimal-versions && cargo check` (smithay's `check-minimal` job). Your `Cargo.toml` claims `serde = "1.0"` works; this proves it.

## cargo-deny (0.20.x)

`cargo deny check` covers four areas: advisories, licenses, bans, sources. Template: `../templates/deny.toml`.

Schema notes for 0.16+ (current 0.20.2):

- Removed from `[advisories]`: `vulnerability`, `notice`, `severity-threshold` and the old forms of `unmaintained`/`unsound`. Vulnerabilities are always errors; exceptions go in `ignore`.
- `unmaintained` and `unsound` now take a scope: `"all" | "workspace" | "transitive" | "none"`.
- Removed from `[licenses]`: `unlicensed`, `allow-osi-fsf-free`, `copyleft`, `default`, `deny`. Only `allow` (SPDX list) and `exceptions` decide.
- Old configs with removed fields are **hard errors** — do not copy pre-2024 templates.
- `version = 2` in `[advisories]`/`[licenses]` is harmless; whether it is still required is unverified.

```toml
[graph]
# Only check targets we actually ship (winit/egui do this per platform).
targets = ["x86_64-unknown-linux-gnu", "aarch64-linux-android", "x86_64-pc-windows-msvc"]
all-features = true

[advisories]
unmaintained = "workspace"
ignore = [
  # RUSTSEC-YYYY-NNNN: <crate> unmaintained; only used by <dev tool>; tracked in #123.
  # { id = "RUSTSEC-YYYY-NNNN", reason = "..." },
]

[licenses]
allow = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Unicode-3.0", "Zlib"]
exceptions = [
  # { allow = ["MPL-2.0"], crate = "<crate>" },
]

[bans]
multiple-versions = "warn"   # "deny" for mature libraries (winit) with a reasoned skip list
wildcards = "deny"
skip = [
  # { crate = "windows-sys@0.52", reason = "winit still on 0.52; remove after winit 0.31" },
]
deny = [
  # { crate = "openssl-sys", reason = "rustls only" },
]

[sources]
unknown-registry = "deny"
unknown-git = "deny"
allow-git = []   # list every [patch] git source here
```

Advanced (freya, winit): `[bans.build]` with `allow-build-scripts` allowlist and `interpreted = "deny"` to stop build scripts from shipping interpreted payloads — strong defense against `build.rs` supply-chain attacks, at the cost of maintaining the allowlist.

## Other tools

| Tool | Version (2026-11) | Use |
|---|---|---|
| `cargo-deny` | 0.20.2 | licenses, bans, sources, advisories — the one to run in every CI |
| `cargo-audit` | 0.23.0 | RustSec advisories only; redundant if `cargo deny check advisories` runs, useful for `cargo audit fix` |
| `cargo-vet` | 0.10.3 | audit trail ("someone reviewed this version"); adopt for high-assurance projects, imports audits from Mozilla/Google |
| `cargo-machete` | 0.9.2 | fast, stable, heuristic unused-dependency detection (egui CI) — may false-positive on macro-only use; ignore via `[package.metadata.cargo-machete]` |
| `cargo-udeps` | 0.1.61 | accurate unused deps, requires nightly |
| `cargo-hack` | 0.6.46 | feature powerset / `--rust-version` checks |
| `cargo tree -d` | built in | see duplicated versions |

## Scheduled upstream check

freya's pattern: a cron job that runs `cargo update` in CI (without committing) and then `cargo deny check` + tests, so breakage from upcoming dependency releases is caught before a user hits it. Plus run `deny` on every change to `Cargo.toml`/`Cargo.lock` via path filters. See `ci-cd.md`.

## Responding to an advisory

1. `cargo deny check advisories` / `cargo audit` to see the path: `cargo tree -i <crate>`.
2. Upgrade (`cargo update -p <crate> --precise <fixed>`), or replace the dependency.
3. If not exploitable in your usage, add an `ignore` entry with `reason` and a tracking issue — never a silent ignore.
4. For a compromised crate (malicious release): pin to the last good version, rotate any secrets that a build on an affected machine/CI could have read, check CI logs for the window.

## Anti-patterns

- Adding a crate without checking it exists and is the intended one.
- `"*"` or unbounded version requirements (`wildcards = "deny"` catches them).
- Enabling default features of heavy crates you use one function from.
- A git dependency pinned to a branch.
- `ignore`-ing advisories without a reason.
- Removing `Cargo.lock` from version control; CI without `--locked`.
- Trusting `cargo audit` alone (it does not check licenses or sources).
- Copying a deny.toml with removed fields (`copyleft`, `vulnerability`) — fails on 0.16+.

## Checklist

- [ ] `deny.toml` present, current schema, `cargo deny check` in CI.
- [ ] License allowlist reviewed for the project's distribution model.
- [ ] `[sources]` denies unknown registries/git; every `[patch]` git source is listed.
- [ ] Each `skip`/`ignore`/`exception` has a reason.
- [ ] `--locked` in CI; `Cargo.lock` committed.
- [ ] Scheduled upstream job (cargo update + deny + test).
- [ ] Unused dependency check (machete or udeps).
- [ ] New deps reviewed: existence, maintenance, features, build scripts, license.

Related: `workspace.md`, `ci-cd.md`, `ci-hardening.md`, `security.md`, `../templates/deny.toml`.
