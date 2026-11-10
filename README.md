# rustlikeapro

An agent skill for writing Rust the way I want it written: typed errors, lints in the manifest, no stray `unwrap`, CI that actually gates something.

It started as a single file of personal rules and grew into this after auditing my own repos and a handful of projects I contribute to (winit, smithay, niri, egui, freya, gilrs). It follows the [Agent Skills](https://agentskills.io/specification) format, so Claude Code, Codex, Cursor, Gemini CLI or anything else that reads `SKILL.md` can use it.

## What's inside

```
SKILL.md        hard rules, decision tables, definition of done, index of references
references/     one file per topic, loaded only when the task needs it
templates/      configs you can copy into a project
scripts/        the gate, a repo audit, dependency helper, self-refresh
```

`SKILL.md` is kept short on purpose. It tells the agent what is non-negotiable and which reference to open for what, e.g. `references/async.md` when touching tokio, `references/unsafe-ffi.md` before writing any `unsafe`.

Topics covered in `references/`: errors, API design and semver, testing, async, concurrency, performance, unsafe and FFI, workspaces, supply chain, CI/CD, CI hardening, releases, Nix, observability, CLI and config, serialization, multiplatform, security, dependency maintenance, common LLM mistakes in Rust, and Freya.

## Some of the rules

- Lints live in `[workspace.lints]`, not in a CLI flag. `clippy::pedantic` on, `unsafe_code` forbidden by default, a few restriction lints cherry-picked.
- `#[expect(lint, reason = "...")]` instead of `#[allow]`. An allow without a reason doesn't pass.
- Errors are typed enums with context. A reporting type (miette, color-eyre) is allowed only at the top of a binary.
- `unwrap()` is denied outside tests. `expect()` only when the message states the invariant.
- `foo.rs` + `foo/`, not `foo/mod.rs`.
- Dependencies go in through `cargo add`, never with a version typed from memory, and are declared as `major.minor` so `cargo update` keeps patches coming.
- Nothing is "done" until fmt, clippy, tests, doc tests and `cargo deny` have actually run. Skipped steps get reported, not hidden.

Projects can override any of this in their own `AGENTS.md`. The skill reads that first.

## Templates

| File | Notes |
|---|---|
| `Cargo.workspace.toml` | workspace layout, lint table, profiles, every non-obvious line commented |
| `clippy.toml`, `rustfmt.toml`, `rust-toolchain.toml`, `typos.toml` | |
| `deny.toml` | cargo-deny 0.20 schema |
| `ci.yml` | fmt, typos, clippy + docs, test matrix with nextest, feature checks, MSRV, deny |
| `release.yml`, `release-plz.toml` | tag-triggered release, optional trusted publishing |
| `dependabot.yml` | cargo + GitHub Actions |
| `justfile`, `flake.nix` | local recipes, crane-based flake |
| `AGENTS.md` | project rules plus an append-only decision log |

## Scripts

```bash
scripts/check.sh                 # the local gate: fmt, clippy, tests, doc tests, docs, deny, typos
scripts/check.sh --quick         # fmt + clippy only
scripts/check.sh --features a,b  # for crates with mutually exclusive features
scripts/check.sh --msrv          # also build with the declared rust-version, if installed

scripts/audit.sh path/to/repo    # what's missing and which template fixes it (read-only)

scripts/add-dep.sh tokio -p app-core --features rt,macros
                                 # latest stable, written as "1.54", workspace-aware,
                                 # warns if it needs a newer compiler than your MSRV

scripts/refresh.sh               # is this skill still current? (read-only)
scripts/refresh.sh --write       # fix what can be fixed mechanically
```

They need bash 4+ and GNU coreutils. On macOS, `brew install bash gnu-sed`.

## Keeping it current

Rust moves every six weeks and lints get renamed, so the skill checks itself. `refresh.sh` compiles a probe crate with the template lint table against the installed clippy, validates `deny.toml` with the installed cargo-deny, compares action tags with their latest releases and every version mentioned in the docs against crates.io.

`.github/workflows/refresh.yml` runs it every Monday on the latest stable toolchain and pushes the mechanical fixes straight to `main`. The job fails only when something needs a human, like a removed lint or a cargo-deny schema change. If a line mentions an old version on purpose, put `refresh:keep` on it.

## Suggestions it may make

The skill can suggest three tools of mine when they fit, and only then:

- [istmo](https://github.com/SergioRibera/istmo) for Rust apps that need native Android/iOS APIs
- [sismo](https://github.com/OxidShell/sismo) for profiling and logs, including after release
- [nix-bundle-app](https://github.com/SergioRibera/nix-bundle-app) for native installers from a Nix build

They're suggestions. The agent is told to explain why and let you decide, and not to bring them up otherwise.

## Installing

Clone it somewhere and link it where your agent looks for skills:

```bash
git clone https://github.com/SergioRibera/rustlikeapro ~/src/rustlikeapro

ln -s ~/src/rustlikeapro ~/.claude/skills/rustlikeapro   # Claude Code
ln -s ~/src/rustlikeapro ~/.agents/skills/rustlikeapro   # Codex, Cursor, Gemini CLI, ...
```

Per project works too: put it in `.agents/skills/rustlikeapro` or `.claude/skills/rustlikeapro`.

## License

MIT
