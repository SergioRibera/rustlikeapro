# Keeping Dependencies, Lints and Tooling Current

> Read when: adding or upgrading a dependency, bumping GitHub Actions, refreshing lint/deny configs, or maintaining this skill itself.

Two different things drift over time: **the project** (its dependencies, actions, lint config) and **this skill** (its templates and the versions it mentions). Each has its own loop.

## Adding dependencies

**Never hand-write a version number from memory.** Model knowledge lags crates.io by months; a remembered version is either stale or invented.

Rule: add every dependency through `cargo add` (or `scripts/add-dep.sh`, which wraps it), so the version comes from the registry at the moment of adding, and declare the requirement as **`major.minor`**:

```toml
[dependencies]
thiserror = "2.0"                                   # not "2.0.21", not "2", not "*"
tokio = { version = "1.54", features = ["rt", "macros"] }
```

Why `major.minor`:

- Cargo requirements are caret by default: `"1.54"` means `>=1.54.0, <2.0.0`; `"0.8"` means `>=0.8.0, <0.9.0`. Patch (and, for 1.x, minor) releases stay inside the range, so `cargo update` picks them up without touching `Cargo.toml`.
- The minor floor documents the API level the code was written against. `"1"` would claim compatibility with `1.0.0`, which is almost never tested.
- The exact version lives in `Cargo.lock`, which is the reproducibility mechanism, not `Cargo.toml`. Commit `Cargo.lock` for binaries and workspaces with binaries; libraries may commit it too (Cargo's current guidance leaves it to the project).
- `0.0.x` crates break on every release, so the full version is kept for them.

```bash
scripts/add-dep.sh thiserror                          # single crate: cargo add thiserror@2.0
scripts/add-dep.sh tokio -p app-core --features rt    # workspace: writes [workspace.dependencies] + `workspace = true`
scripts/add-dep.sh --dry-run serde                    # show what would happen
```

Without the script:

```bash
cargo info thiserror                 # "version: 2.0.21" — latest stable (cargo >= 1.82)
cargo add thiserror@2.0              # explicit major.minor requirement
```

In a workspace, the version is declared **once** in the root `[workspace.dependencies]` and members reference it; `cargo add -p member dep` writes `dep = { workspace = true }` automatically once the workspace entry exists. Features belong on the member that needs them.

### MSRV interaction

The latest release may need a newer compiler than the project's `rust-version`. `add-dep.sh` warns in that case. Then either choose an older line deliberately (`cargo add dep@1.40`) or raise `rust-version` as a conscious, recorded decision. The MSRV-aware resolver (`resolver = "3"`, default on edition 2024) picks compatible versions for the **lockfile**, but cannot fix a requirement floor that is already too high.

### Before adding at all

Ask: does std or an existing dependency already cover this? Check maintenance (last release, open advisories via `cargo deny check advisories`), license against `deny.toml`, default features (turn them off with `--no-default-features` and enable only what is needed), and transitive weight (`cargo tree -p dep`). See [supply-chain.md](supply-chain.md).

### Keeping the floor honest

A `major.minor` floor is only true if the code compiles against that minor. Libraries should verify it in CI with a minimal-versions check (nightly): `cargo +nightly update -Z minimal-versions && cargo check --all-targets`, or `cargo hack check --rust-version` / `cargo minimal-versions` if installed. When code starts using an API added in a later minor, raise the floor in the same commit.

## Updating a project

| What | How | Cadence |
|---|---|---|
| Patches & compatible minors | `cargo update` (lockfile only), run the full gate, commit `Cargo.lock` | weekly or via Dependabot/Renovate |
| Incompatible releases | `cargo update --verbose` lists what is held back; bump requirement with `cargo add dep@X.Y`, fix code, read the changelog | deliberate, one crate per commit |
| Outdated overview | `cargo outdated` (if installed) or `cargo update --dry-run --verbose` | before releases |
| GitHub Actions | Dependabot `github-actions` ecosystem (`templates/dependabot.yml`); SHA-pinned actions get bumped with the version comment | weekly |
| Lint config | after a toolchain bump: `cargo clippy --all-targets -- -D warnings`; new lints show up as warnings, renamed/removed lints as `unknown_lints` / `renamed_and_removed_lints` | every toolchain bump |
| cargo-deny config | `cargo deny check` fails on deprecated fields after a cargo-deny upgrade; fix the schema rather than pinning the old tool | on cargo-deny upgrade |
| Toolchain | bump `rust-toolchain.toml` channel deliberately; `rust-version` only when the code needs it | per Rust release (6 weeks) or quarterly |

Scheduled CI job worth having (see [ci-cd.md](ci-cd.md)): run `cargo update` in a throwaway checkout, then `cargo deny check` and the tests, so upcoming breakage and new advisories surface before anyone runs `cargo update` for real.

## Maintaining this skill

`scripts/refresh.sh` checks the skill against the real world:

1. installed/latest `rustc` vs `metadata.verified-against` in `SKILL.md`;
2. every lint in `templates/Cargo.workspace.toml` + `templates/clippy.toml` is known to the installed clippy (unknown, renamed, removed lints flagged);
3. `templates/deny.toml` is accepted by the installed cargo-deny (schema drift);
4. `uses: owner/repo@vN` in `templates/*.yml` vs the latest GitHub release (`--write` bumps the major tag);
5. crate/tool versions mentioned anywhere in the skill vs crates.io, compared at `major.minor`.

```bash
scripts/refresh.sh            # report; exit 1 on drift
scripts/refresh.sh --write    # also rewrite action major tags in templates
GITHUB_TOKEN=... scripts/refresh.sh   # avoid GitHub API rate limits
```

`--write` fixes everything mechanical: action major tags, stale version mentions (keeping their precision: `"2.0"` stays major.minor, `2.0.21` stays full), `metadata.verified-against` (only forward, and only when the clippy probe passes on the newer toolchain) and a `metadata.version` patch bump. Historical mentions that must not be rewritten ("removed in cargo-deny 0.16") carry `refresh:keep` on the same line.

What it cannot fix — renamed/removed lints, a `deny.toml` schema change, breaking inputs of a new action major — stays flagged and needs a human.

Automation: `.github/workflows/refresh.yml` in the skill's repository runs weekly on the latest stable toolchain with cargo-deny installed, commits the mechanical fixes straight to the default branch (`chore: refresh versions, lints and action tags`), then re-runs the report and fails the job only if human-only drift remains. Locally, run it at least on every Rust release and before sharing the skill.

## Anti-patterns

- Writing `serde = "1.0.195"` from memory, or `"*"`.
- Pinning `=1.2.3` in a library (forces downstream duplicates); exact pins are for rare, documented cases in binaries.
- Running `cargo update` and committing without running tests.
- Bumping several incompatible dependencies in one commit.
- Silencing `unknown_lints` instead of fixing the lint name after a toolchain bump.
- Pinning an old cargo-deny to avoid migrating `deny.toml`.

## Checklist

- [ ] Dependency added via `cargo add` / `add-dep.sh`, requirement is `major.minor`
- [ ] Workspace: version only in `[workspace.dependencies]`, members use `workspace = true`
- [ ] No MSRV warning, or MSRV bump recorded in the decision log
- [ ] Default features reviewed; license and advisories pass `cargo deny check`
- [ ] `Cargo.lock` committed (binaries) and updated in the same commit
- [ ] Dependabot/Renovate configured for `cargo` and `github-actions`
