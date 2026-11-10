# API Design

> Read when: designing or changing a public API, publishing a crate, adding cargo features, deciding what is `pub`, or reviewing semver impact.

Baseline: the [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/checklist.html). This file lists the parts that matter most in practice and how this skill enforces them.

## 1. Surface area

- Everything starts private. Promote to `pub(crate)`, then `pub`, only when a caller needs it. Enable `unreachable_pub` so accidental `pub` inside private modules is flagged.
- The crate root (`lib.rs`) and each module root (`foo.rs`) define the public surface through explicit `pub use` re-exports. Users should not need to know your internal module tree.
- Do not expose dependency types in public signatures unless you accept their semver as yours. If you do, re-export the dependency (`pub use serde;`) so users get a matching version.

## 2. Common traits (C-COMMON-TRAITS)

Public types should implement, where semantically valid: `Debug` (always — `missing_debug_implementations`), `Clone`, `Copy` (small value types), `PartialEq`/`Eq`, `PartialOrd`/`Ord`, `Hash`, `Default`, `Display` (user-facing types and errors).

- Derive them (`#[derive(Debug, Clone, PartialEq, Eq, Hash)]`); a manual impl needs a reason.
- `serde::{Serialize, Deserialize}` behind an optional `serde` feature in libraries.
- Check auto traits: public types should be `Send + Sync` unless there is a reason. A static assertion catches regressions:

```rust
const _: () = {
    const fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Client>();
};
```

## 3. Constructors and conversions

Priority from SKILL.md §4: `#[derive(Default)]` > manual `Default` > `From`/`TryFrom` > builder > `fn new(..)`.

```rust
#[derive(Debug, Clone, Default)]
#[must_use]
pub struct RetryPolicy {
    max_attempts: u32,
    backoff: Duration,
}

impl RetryPolicy {
    pub fn with_max_attempts(mut self, max_attempts: u32) -> Self {
        self.max_attempts = max_attempts;
        self
    }

    pub fn with_backoff(mut self, backoff: Duration) -> Self {
        self.backoff = backoff;
        self
    }
}

// Caller
let policy = RetryPolicy::default().with_max_attempts(5);
```

- Validating conversions are `TryFrom` with a typed error: `impl TryFrom<u16> for Port`.
- Conversion method naming (C-CONV): `as_` (cheap borrow), `to_` (expensive or owned), `into_` (consumes self).
- Getters have no `get_` prefix: `fn name(&self) -> &str`.

## 4. Parameters and return types

| Parameter | Prefer | Why |
|---|---|---|
| read-only string | `&str` | no allocation, accepts `String` via deref |
| path | `impl AsRef<Path>` or `&Path` | accepts `&str`, `String`, `PathBuf` |
| slice of items | `&[T]` | works for `Vec`, arrays |
| owned value that will be stored | `T` or `impl Into<T>` | caller decides when to allocate |
| callback | `impl FnMut(..)` / generic `F: Fn(..)` | zero cost |

Use `impl Into<T>` sparingly: it breaks type inference at call sites (`.into()` ambiguity) and monomorphizes per caller type. Reach for it when it removes real friction (`impl Into<Cow<'static, str>>` for labels).

Return concrete owned types. When a function produces a sequence that callers usually iterate once, return `impl Iterator<Item = T> + '_` instead of building a `Vec`; let the caller `collect()` if needed.

```rust
impl Inventory {
    pub fn low_stock(&self, threshold: u32) -> impl Iterator<Item = &Item> + '_ {
        self.items.iter().filter(move |item| item.quantity < threshold)
    }
}
```

## 5. Evolving without breaking

### `#[non_exhaustive]`

On public enums and structs in libraries that may grow. Callers must use `_ =>` / `..`, so you can add variants or fields in a minor release. Do not use it on internal types — there, exhaustive matching is the point.

### Sealed traits

When users may call a trait but must not implement it:

```rust
mod sealed {
    pub trait Sealed {}
}

pub trait Backend: sealed::Sealed {
    fn name(&self) -> &str;
}

impl sealed::Sealed for WaylandBackend {}
impl Backend for WaylandBackend {
    fn name(&self) -> &str { "wayland" }
}
```

Adding methods to a sealed trait is not a breaking change.

### Deprecation

`#[deprecated(since = "0.4.0", note = "use `Client::connect` instead")]` for at least one minor release before removal.

### Semver checks

Run `cargo semver-checks` before every release of a published library (in CI via `obi1kenobi/cargo-semver-checks-action`). It catches removed items, changed signatures and added required trait items. See [release.md](release.md).

## 6. Cargo features

- **Features are additive.** Enabling a feature must never remove API or change behavior of existing API. Cargo unifies features across the dependency graph, so a non-additive feature breaks someone else's build.
- Keep `default` minimal for libraries. Use `dep:` syntax to avoid implicit features: `serde = ["dep:serde"]`.
- Mutually exclusive features are a design smell; when unavoidable (two backends), fail loudly:

```rust
#[cfg(all(feature = "backend-a", feature = "backend-b"))]
compile_error!("features `backend-a` and `backend-b` are mutually exclusive; enable only one");
```

- Verify every feature compiles in isolation: `cargo hack check --each-feature --no-dev-deps` (or `--feature-powerset` for small feature sets) in CI.
- Document each feature in the crate docs and in `Cargo.toml` comments.

## 7. Documentation

- `#![warn(missing_docs)]` (or `missing_docs = "warn"` in `[lints.rust]`) for libraries.
- Every public item: one-line summary, then details, then `# Errors`, `# Panics`, `# Safety` (for `unsafe fn`), `# Examples`.
- Examples are doc tests — they run in CI (`cargo test --doc`). Use `?` in examples with a hidden `# fn main() -> Result<(), Box<dyn std::error::Error>> {` wrapper instead of `unwrap()`.
- Intra-doc links (`[`Client::connect`]`) and `rustdoc::broken_intra_doc_links = "deny"`.
- docs.rs configuration:

```toml
[package.metadata.docs.rs]
all-features = true
rustdoc-args = ["--cfg", "docsrs"]
```

```rust
#![cfg_attr(docsrs, feature(doc_cfg))]

#[cfg(feature = "serde")]
#[cfg_attr(docsrs, doc(cfg(feature = "serde")))]
pub mod serde_support;
```

Declare the cfg so rustc does not warn: `[lints.rust] unexpected_cfgs = { level = "warn", check-cfg = ["cfg(docsrs)"] }`.

## 8. Naming

- Types `UpperCamelCase`, functions/modules `snake_case`, constants `SCREAMING_SNAKE_CASE`.
- No module-name stutter in public paths users see: `http::Client`, not `http::HttpClient` (projects that allow `module_name_repetitions` do so for internal clarity; keep public paths clean).
- Iterator methods: `iter`, `iter_mut`, `into_iter`; iterator types named after the method (`Iter`, `IntoIter`).

## Anti-patterns

- `pub` fields on types with invariants — use private fields plus accessors.
- A public function taking `String` when it only reads the data.
- `bool` parameters (`connect(true, false)`) — use enums or a config struct.
- Exposing `Arc<Mutex<T>>` in a public API — wrap it in a handle type.
- Non-additive features (`no-std` feature that removes items instead of `std` feature that adds them).
- Returning `Vec<T>` from a getter that copies internal data every call.
- Breaking changes in a patch release because semver-checks was not run.

## Checklist

- [ ] Public surface is intentional; internal modules are private with explicit re-exports.
- [ ] Public types implement `Debug` and the applicable common traits; `Send + Sync` asserted where expected.
- [ ] Constructors follow the priority order; conversions are `From`/`TryFrom`.
- [ ] Public enums/structs that may grow are `#[non_exhaustive]`; extension-only traits are sealed.
- [ ] Features are additive; `cargo hack check --each-feature` passes.
- [ ] Docs: `missing_docs` clean, doc tests pass, docs.rs metadata set.
- [ ] `cargo semver-checks` clean before release.

See also: [errors.md](errors.md), [release.md](release.md), [workspace.md](workspace.md).
