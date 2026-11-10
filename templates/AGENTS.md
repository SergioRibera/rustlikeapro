# AGENTS.md

<!--
Template (rustlikeapro). Instructions for any coding agent (Codex, Cursor, Gemini CLI, Claude Code, ...).
Claude Code: create CLAUDE.md containing the single line `@AGENTS.md` so both stay in sync.
Keep it short; move long explanations to docs/.
-->

## Project

<One paragraph: what this is, who uses it, main crates.>

| Crate | Role |
|---|---|
| `crates/myproj-core` | Shared types and traits |
| `crates/myproj-<domain>` | <domain> |

## Commands

```bash
just check        # full gate: fmt, clippy -D warnings, tests, doc tests, docs, deny
just lint         # fmt --check + clippy
just test         # nextest + doc tests
just msrv         # check against rust-version
```

Never report a step as passing without running it. If something cannot run, say so.

## Rules

- Follow the `rustlikeapro` skill (typed errors, no `unwrap` outside tests, `#[expect(.., reason)]`
  instead of `#[allow]`, `foo.rs` + `foo/` modules, tracing instead of println, English code/docs).
- Project-specific rules:
  - <e.g. no OpenSSL: rustls only>
  - <e.g. library crates stay executor-agnostic>
- Commits: single-line Conventional Commits (`feat: ...`, `fix: ...`).

## Session protocol

1. Read this file and `PLAN.md` (if present).
2. Confirm the task scope before large changes.
3. Implement, run `just check`, tick the item in `PLAN.md`.
4. Append any decision to the log below.

## Decision log

Append only; never rewrite past entries. Newest at the bottom.

### Settled

- **YYYY-MM-DD — <decision>.** Rationale: <why>. Impl: <where>. Gotchas: <traps>. Follow-ups: <todo>.

### Rejected paths (do not re-propose)

- **YYYY-MM-DD — <approach>.** Rejected because <reason>.
