# LLM agent anti-patterns in Rust

> Read when: reviewing Rust you (an agent) just wrote, before declaring a task done, or when reviewing a PR produced by an AI agent.

These are the recurring mistakes AI agents make in Rust. Each entry gives the symptom, why it hurts, and the fix. Go through your diff against this list before running `scripts/check.sh`.

---

### 1. `.clone()` to silence the borrow checker
**Symptom**: `.clone()` added at the exact spot the compiler complained.
**Why bad**: hides an ownership design problem, costs allocations, and diverges state (you mutate a copy).
**Fix**: reorder borrows, narrow a borrow's scope, pass `&T`, split the struct so disjoint fields borrow independently, or move the value if the caller doesn't need it.

```rust
// ✗
let name = self.config.name.clone();
self.update(&name);
// ✓ when update only needs other fields: borrow disjoint fields, or take &str from a local scope
```

### 2. `Arc<Mutex<T>>` / `Rc<RefCell<T>>` by reflex
**Symptom**: shared mutable state wrapped in a lock "to make it compile".
**Why bad**: runtime borrow panics, lock contention, deadlocks, and an unclear owner.
**Fix**: find the owner. Use message passing (channels), pass `&mut` down the call stack, or give one task/actor ownership and send it commands. Use a lock only after deciding shared state is the design.

### 3. Hallucinated crates, versions, features or APIs
**Symptom**: `use foo::bar::Baz` that doesn't exist; a feature flag that the crate never had; a version that isn't published.
**Why bad**: compile failure at best; at worst a typo-squatted malicious crate.
**Fix**: verify before using. Check `~/.cargo/registry/src/*/<crate>-<ver>/`, `cargo add <crate>` (which resolves real versions), `cargo info <crate>`, or docs.rs for the exact version in `Cargo.lock`. Never write a version number from memory.

### 4. `unwrap()` in examples and "temporary" code
**Symptom**: `.unwrap()` in a snippet, a `main`, or "I'll fix later" code.
**Why bad**: examples get copied into production paths; "later" never comes.
**Fix**: use `?` with a typed error. If the failure is truly impossible, write `.expect("invariant: …")` explaining why. Doc examples can use `?` with a hidden `# fn main() -> Result<(), Box<dyn std::error::Error>> {`.

### 5. `String` everywhere
**Symptom**: parameters typed `String`, `Vec<String>`, IDs as `String`.
**Why bad**: forced allocations at every call site; swapped arguments compile fine.
**Fix**: take `&str` / `&[T]` / `impl AsRef<Path>`. Use newtypes for IDs (`UserId(u64)`). Use `Cow<'static, str>` for "usually static, sometimes owned".

### 6. Returning `Vec` where an iterator suffices
**Symptom**: `fn items(&self) -> Vec<Item>` that just collects.
**Why bad**: allocation plus copy for callers that only iterate once.
**Fix**: `fn items(&self) -> impl Iterator<Item = &Item> + '_`.

### 7. New dependency for a std one-liner
**Symptom**: adding `itertools`, `lazy_static`, `once_cell`, `chrono` or `regex` for one trivial use.
**Why bad**: compile time, supply-chain surface, MSRV pressure.
**Fix**: check std first:
- `std::sync::LazyLock` / `OnceLock` replace `lazy_static` / `once_cell`;
- `Iterator` methods cover most `itertools` uses;
- `std::time` for simple durations.

Check whether an existing workspace dependency already covers the need. Add a dependency only with a reason.

### 8. `#[allow(...)]` to make clippy pass
**Symptom**: `#[allow(clippy::too_many_arguments)]` slapped on the function that triggered it.
**Why bad**: the lint was pointing at a design problem.
**Fix**: fix the code (introduce a params struct or builder). If the lint is genuinely wrong here, use `#[expect(clippy::lint, reason = "…")]` at the narrowest scope.

### 9. Claiming success without running anything
**Symptom**: "All tests pass" or "this compiles" with no command output to back it.
**Why bad**: false confidence; the user ships broken code.
**Fix**: run `scripts/check.sh` (or the individual gates) and report actual results. If a step couldn't run, say so explicitly.

### 10. Catch-all `_ =>` on your own enums
**Symptom**: `match state { State::A => …, _ => {} }`.
**Why bad**: a new variant silently falls into the wildcard; the compiler can't help.
**Fix**: list every variant. A wildcard is only for foreign `#[non_exhaustive]` enums, and then it does something explicit.

### 11. Stringly-typed errors
**Symptom**: `Err(format!("failed to read {path}"))`, `Result<T, String>`, `Box<dyn Error>` in library code.
**Why bad**: callers can't match on failure modes; context gets lost; there is no `source()` chain.
**Fix**: a `thiserror` enum with context-carrying variants. See `references/errors.md`.

### 12. Blocking inside async
**Symptom**: `std::fs::read`, `std::thread::sleep`, `reqwest::blocking` or heavy CPU loops inside an `async fn`.
**Why bad**: stalls the executor thread; with nested runtimes it panics.
**Fix**: `tokio::fs`, `tokio::time::sleep`, async clients, or `tokio::task::spawn_blocking` for CPU/blocking work.

### 13. Holding a lock guard across `.await`
**Symptom**: `let g = mutex.lock().unwrap(); something.await; g.push(..)`.
**Why bad**: the future becomes `!Send` (it won't spawn) or deadlocks.
**Fix**: scope the guard in a block that ends before `.await`, copy out what you need, or use `tokio::sync::Mutex` when holding across await is truly required.

### 14. Spawning tasks and forgetting them
**Symptom**: `tokio::spawn(async { … });` with the `JoinHandle` dropped.
**Why bad**: panics and errors vanish; there's no shutdown path; tasks outlive their owner.
**Fix**: keep handles in a `JoinSet`, propagate errors, and wire cancellation (`CancellationToken` from `tokio-util`) for graceful shutdown.

### 15. Indexing with `[]` on untrusted or computed indices
**Symptom**: `buf[offset..offset + len]` with values from input.
**Why bad**: a panic, which is a DoS in services.
**Fix**: `buf.get(offset..offset.checked_add(len)?)` and return a typed error on `None`.

### 16. Over-generic code nobody asked for
**Symptom**: a trait with one implementation, `<T: Into<String> + Clone + Send + 'static>` on internal helpers, a builder for a two-field struct.
**Why bad**: harder to read, slower to compile, worse error messages.
**Fix**: concrete types until a second real use appears. (This doesn't override the skill's preference for methods over free functions. It's about speculative generality.)

### 17. Reinventing what the framework already provides
**Symptom**: hand-written `.width()` / `.padding()` builders on a UI component; a custom retry loop when the client has a retry layer; a manual `Display` that duplicates `thiserror`'s `#[error]`.
**Why bad**: duplicated behavior that drifts from the framework.
**Fix**: look for the framework's extension traits or middleware first (e.g. Freya's `LayoutExt` / `ContainerExt`, see `references/frameworks/freya.md`).

### 18. `mod.rs`, loose helpers and reflexive new files
**Symptom**: `utils.rs` / `helpers.rs` grab-bags, `foo/mod.rs`, a new file for every function.
**Why bad**: no domain structure, near-duplicate helpers, visually lost module roots.
**Fix**: put behavior on the owning type (`impl Struct`), use the `foo.rs` + `foo/` layout, and create a file only for a new concept.

### 19. Dead code kept "just in case"
**Symptom**: `#[allow(dead_code)]`, commented-out blocks, `let _ = unused_param;`, `_old_impl` functions.
**Why bad**: noise that rots; it confuses future readers and agents.
**Fix**: delete it; git has the history. Prefix truly-required unused parameters (`_ctx`) or remove them.

### 20. Narrating comments
**Symptom**: `// increment counter` above `counter += 1;`, or a comment block restating the function name.
**Why bad**: it doubles the reading cost and goes stale.
**Fix**: delete it. Keep only *why* comments (constraint, workaround link, SAFETY, `TODO(owner)`). Put design rationale in the decision log (`AGENTS.md` / `docs/adr/`).

### 21. Silently changing project-level settings
**Symptom**: bumping `edition`, `rust-version` or dependency major versions, enabling `nursery`, or rewriting `rustfmt.toml` as a side effect of an unrelated task.
**Why bad**: surprise breakage for other contributors; the change is out of scope.
**Fix**: respect the declared settings. Propose changes separately, with a reason, and record accepted ones in the decision log.

### 22. Ignoring the project's decision log
**Symptom**: proposing a crate or approach the repo already listed under "rejected paths".
**Why bad**: it wastes the user's time and re-litigates settled decisions.
**Fix**: read `AGENTS.md` / `CLAUDE.md` / `PLAN.md` / `docs/adr/` before designing anything (SKILL.md §0).

### 23. Unsafe without a convincing SAFETY comment
**Symptom**: `unsafe { … }` to get around a borrow error, `transmute` between types, `// SAFETY: this is safe`.
**Why bad**: undefined behavior that safe Rust's guarantees no longer cover.
**Fix**: find the safe API first (`split_at_mut`, `bytemuck`, `zerocopy`). If `unsafe` is truly needed, write a SAFETY comment that names each invariant and who upholds it, and run Miri.

### 24. Tests that test nothing
**Symptom**: tests asserting that a constructor returns `Ok`, tests mirroring the implementation line by line, `#[ignore]`d failing tests.
**Why bad**: the coverage number goes up while confidence doesn't.
**Fix**: assert on behavior and edge cases (empty, max, invalid, concurrent); use property tests for invariants and snapshots for complex output. A failing test is fixed or deleted with a reason, never silently ignored.

---

## Final self-review prompt

Before reporting done, answer each with "yes" or a fix:

1. Did I run fmt, clippy (`-D warnings`), tests and doc tests, and am I reporting the real output?
2. Is every new dependency, crate and API verified to exist at the version used?
3. Is every error typed with context? Is there no `unwrap`, and is every `expect` explaining an invariant?
4. Did I add any `clone`, `Arc<Mutex>`, `#[allow]`, `_ =>` or `unsafe`, and is each one justified?
5. Did I change anything outside the task's scope?
6. Does any decision I made belong in the decision log?
