# Unsafe and FFI

> Read when: writing or reviewing any `unsafe` block, `unsafe fn`, `unsafe impl`, `extern` declaration, `#[no_mangle]` export, bindgen/cbindgen/cxx/JNI glue, a dynamic plugin system, or setting up Miri.

`unsafe` is not "turning the checks off": it is a promise that the code upholds invariants the compiler cannot verify. Every promise must be written down, scoped as narrowly as possible, and tested with tools that can actually see undefined behavior.

## Default: forbid

- Workspace default in `Cargo.toml` (see `../templates/Cargo.workspace.toml`):

  ```toml
  [workspace.lints.rust]
  unsafe_code = "forbid"
  unsafe_op_in_unsafe_fn = "deny"

  [workspace.lints.clippy]
  undocumented_unsafe_blocks = "deny"
  multiple_unsafe_ops_per_block = "warn"
  ```

- A crate that genuinely needs `unsafe` (FFI, SIMD, a low-level primitive) **does not inherit** the `forbid`. Inheritance is all or nothing: Cargo rejects a `[lints.rust]` table next to `[lints] workspace = true`, and a source-level `#[allow]` cannot override `forbid`. So the crate drops `workspace = true` and writes **complete** local tables — the whole workspace baseline copied, only the unsafe entry changed, with the reason in a comment:

  ```toml
  # FFI boundary to the Android/iOS hosts — the only crate allowed to use unsafe.
  # Copy of [workspace.lints] with unsafe_code relaxed; keep in sync with the root.
  [lints.rust]
  unsafe_code = "allow"
  unsafe_op_in_unsafe_fn = "deny"
  unreachable_pub = "warn"
  missing_debug_implementations = "warn"

  [lints.clippy]
  pedantic = { level = "warn", priority = -1 }
  undocumented_unsafe_blocks = "deny"
  multiple_unsafe_ops_per_block = "warn"
  # ...rest of the workspace clippy table
  ```

  Example: istmo's `notinplus` crate follows this recipe.
- Alternative when the copy is a maintenance burden: set the workspace value to `unsafe_code = "deny"` instead of `forbid`; a reviewed module can then opt in with `#[expect(unsafe_code, reason = "FFI boundary, see SAFETY comments")]` while every other crate keeps inheriting.
- Keep unsafe in **one crate or one module** with a safe public wrapper. Callers of the wrapper never write `unsafe`.
- `forbid` cannot be overridden by inner `#[allow]`; `deny` can. Use `forbid` where unsafe must never appear, `deny` where a reviewed module may opt in.

## SAFETY comments

Every `unsafe` block, `unsafe impl` and `unsafe fn` gets documentation that a reviewer can check against the code.

```rust
/// Returns the native handle registered under `id`.
///
/// # Safety
///
/// `ptr` must come from [`Registry::register`] and must not have been
/// released with [`Registry::release`]. The caller must not alias the
/// returned reference mutably.
pub unsafe fn handle_from_raw<'a>(ptr: *const Handle) -> &'a Handle {
    // SAFETY: the caller guarantees `ptr` was produced by `register` and is
    // still live (see `# Safety`), so it is non-null, aligned and points to
    // an initialized `Handle`.
    unsafe { &*ptr }
}
```

Format:

- `// SAFETY:` immediately above the block (clippy's `undocumented_unsafe_blocks` looks for exactly this).
- Name **each invariant** (non-null, aligned, initialized, live, not aliased, valid UTF-8, thread affinity) and **who upholds it** (this function, the caller per `# Safety`, the C library per its docs — link them).
- One unsafe operation per block when practical (`multiple_unsafe_ops_per_block`), so each comment justifies one thing.
- `unsafe impl Send/Sync for T` explains why sharing across threads is sound (smithay's dmabuf allocator is a good model: it explains what the raw handle refers to and why no thread-local state exists).
- If the comment cannot be written convincingly, the code is unsound — redesign instead of rewording.

## Edition 2024 syntax

- `unsafe_op_in_unsafe_fn` is warn-by-default in 2024: the body of an `unsafe fn` is no longer an implicit unsafe block. Wrap each operation in its own `unsafe {}` with a `SAFETY` comment.
- Unsafe attributes: `#[unsafe(no_mangle)]`, `#[unsafe(export_name = "...")]`, `#[unsafe(link_section = "...")]`.
- Extern blocks must be marked: `unsafe extern "C" { ... }`. Items inside can be declared `safe fn` when calling them has no preconditions:

  ```rust
  unsafe extern "C" {
      pub safe fn istmo_abi_version() -> u32;
      pub unsafe fn istmo_dispatch(frame: *const u8, len: usize) -> i32;
  }
  ```

- Taking references to a `static mut` triggers `static_mut_refs`, a **deny-by-default lint** in edition 2024 (not a hard error — but do not `allow` it). Prefer a plain `static` with interior mutability (atomics, `Mutex`, `OnceLock`/`LazyLock`), or access through raw pointers with `&raw const`/`&raw mut`. (`SyncUnsafeCell` is still unstable.)

## Design the boundary narrow

The cheapest FFI to keep sound is the smallest one.

- **One frame protocol, not N trampolines.** Example (istmo): Rust and the host (Kotlin/Swift) exchange a single `dispatch(frame: &[u8]) -> Vec<u8>`-style call carrying a typed, versioned, serialized message (istmo uses bincode 2, now flagged unmaintained — RUSTSEC-2025-0141; postcard or bitcode are maintained alternatives). Adding a feature adds a message variant, not a new `extern` function, new JNI signatures and new unsafe code.
- Pass **plain data across the boundary**: `#[repr(C)]` structs, pointer + length pairs, integer handles (`NativeHandleId(u64)` newtype) instead of raw pointers to Rust objects.
- Ownership is explicit: whoever allocates frees. Export a matching `free` for every buffer handed out; never let C call Rust's allocator implicitly.
- **Never unwind across `extern "C"`.** Panics crossing FFI abort (since 1.81 for `extern "C"`); catch at the boundary with `std::panic::catch_unwind` and turn the panic into an error code if the host must survive. Use `extern "C-unwind"` only when unwinding through foreign frames is intended.
- Validate everything coming in: lengths, UTF-8 (`CStr::to_str`), enum discriminants (never transmute an integer into a Rust enum).

## Tools

| Need | Tool | Notes |
|---|---|---|
| Call C from Rust | `bindgen` | Generate in `build.rs` or commit generated bindings behind a feature (`use_bindgen` in smithay). Allowlist the symbols you need. |
| Expose Rust to C | `cbindgen` | Generates headers from `#[repr(C)]` items and exported functions; keep the header in CI and diff it. |
| C++ interop | `cxx` | Safe bridge with a shared type model; prefer over hand-written C shims for C++. |
| Android/JVM | `jni` crate | Keep `JNIEnv` usage in one module; attach threads explicitly; cache class/method IDs once. |
| Rust↔Rust dynamic plugins | `stabby` + `libloading` | Rust has no stable ABI: use `stabby` types/traits (`#[stabby::stabby]`) for anything crossing the dylib boundary and version the plugin interface. `libloading::Library` must outlive every symbol taken from it. |
| Detect UB | Miri | See below. |

For plugin registries prefer an explicit registry macro (`istmo::runtime!`, `plugin_registry!`) over link-time magic like `inventory`/`linkme` — registration is visible and greppable.

## Miri

Miri interprets MIR and detects UB: out-of-bounds, use-after-free, invalid values, data races, Stacked/Tree Borrows violations.

```bash
rustup +nightly component add miri
cargo +nightly miri test -p <unsafe-crate>
MIRIFLAGS="-Zmiri-strict-provenance" cargo +nightly miri test -p <unsafe-crate>
```

- Run it on every crate containing `unsafe`, at least in a scheduled CI job.
- Miri cannot execute real FFI calls; isolate FFI behind a trait and test the unsafe Rust logic with a fake backend.
- **CI caution:** never cache Miri jobs (or any job that runs untrusted code) in a cache that jobs holding secrets restore, and keep secrets out of the Miri job environment. A 2026 incident reportedly leaked CI secrets through a cached `target/`; the principle holds regardless of the details. See `ci-hardening.md`.
- Complements: `cargo careful` (extra runtime checks on stable-ish code), sanitizers (`-Zsanitizer=address|thread` on nightly), and `loom` for lock-free code (see `concurrency.md`).

## Anti-patterns

- `unsafe` to work around the borrow checker (`transmute` lifetimes, `&*(x as *const _)` to get a second `&mut`). Fix the ownership model instead.
- `std::mem::transmute` where `from_ne_bytes`, `bytemuck::cast`, `as` or a safe constructor exists.
- `unsafe impl Send` without a SAFETY comment, or to silence a compiler error on a type containing `Rc`/raw pointers.
- Large `unsafe {}` blocks containing safe code — the reviewer cannot tell which line needs the justification.
- `// SAFETY: this is safe` or `// SAFETY: trust me` — restating, not justifying.
- Exporting Rust structs without `#[repr(C)]` across FFI.
- A new `extern "C"` function per feature instead of extending a message protocol.
- Running Miri only locally and never in CI; caching Miri artifacts.

## Checklist

- [ ] Workspace has `unsafe_code = "forbid"`; opt-outs are per crate with a comment.
- [ ] `unsafe_op_in_unsafe_fn` and `undocumented_unsafe_blocks` deny.
- [ ] Every `unsafe` block / impl has a `// SAFETY:` naming invariants and owner.
- [ ] Every `pub unsafe fn` has a `# Safety` doc section.
- [ ] Edition 2024 syntax: `#[unsafe(no_mangle)]`, `unsafe extern`.
- [ ] FFI boundary is one narrow protocol; ownership and freeing explicit; panics caught at the boundary.
- [ ] Miri runs on unsafe-bearing crates in CI (uncached, no secrets).
- [ ] Safe wrapper API is the only thing other crates use.

Related: `concurrency.md` (Send/Sync, atomics), `testing.md`, `ci-cd.md`, `multiplatform.md`, `ecosystem.md` (istmo for mobile FFI).
