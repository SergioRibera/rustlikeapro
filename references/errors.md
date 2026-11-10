# Errors

> Read when: designing error types for a module or crate, converting errors across layers, deciding how a binary reports failures, or choosing exit codes.

Errors are part of a module's public API. A caller should be able to `match` on a failure and decide what to do; a human reading a report should learn *what* failed, *where*, and *why* without opening the source.

## 1. Policy (from SKILL.md §3)

| Layer | Error shape |
|---|---|
| Library crates, domain modules, internal layers | Typed `enum` per domain (`thiserror` 2.x or hand-written `Display` + `Error`). |
| Binary `main` / outermost reporting layer | One reporting type: a typed top-level enum, `miette` or `color-eyre`. `anyhow` is discouraged and never appears in library code or public signatures. |
| `Error(String)` variants | Last resort for a truly opaque external failure. |

## 2. Designing a domain error

One enum per domain concept, each variant one failure mode, each carrying the context needed to act on it.

```rust
use std::path::PathBuf;

/// Failures while loading the application configuration.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum ConfigError {
    #[error("failed to read config file {path}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("invalid TOML in {path}")]
    Parse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },

    #[error("`{field}` must be between {min} and {max}, got {actual}")]
    OutOfRange {
        field: &'static str,
        min: u32,
        max: u32,
        actual: u32,
    },
}
```

Rules:

- **Message style**: lowercase, no trailing period, describes the failed operation. Do not repeat the source error's text in the message — reporters print the `source()` chain themselves; duplicating it produces `read failed: No such file: No such file`.
- **`#[source]` vs `#[from]`**: `#[from]` is fine only when a source error type maps to exactly one meaning in this domain. If `io::Error` can come from reading the config *or* creating the cache dir, a bare `#[from] io::Error` erases which one failed. Use context-carrying variants instead.
- **`#[non_exhaustive]`** on public error enums in libraries, so adding a variant is not a breaking change (see [api-design.md](api-design.md)).
- **No `Box<dyn Error>`** in signatures of domain code. It is type-erased `anyhow` with worse ergonomics.
- **Crate-level alias**: `pub type Result<T, E = Error> = std::result::Result<T, E>;` in the crate root when one error type dominates.

### Adding context without `anyhow`

Map at the call site, where the context is known:

```rust
impl Config {
    /// Loads the configuration from `path`.
    ///
    /// # Errors
    ///
    /// Returns [`ConfigError::Read`] if the file cannot be read and
    /// [`ConfigError::Parse`] if it is not valid TOML.
    pub fn load(path: &Path) -> Result<Self, ConfigError> {
        let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Read {
            path: path.to_owned(),
            source,
        })?;
        toml::from_str(&text).map_err(|source| ConfigError::Parse {
            path: path.to_owned(),
            source,
        })
    }
}
```

If the same mapping repeats, give the error a method (`ConfigError::read(path)` returning a closure) rather than a loose helper function.

## 3. Composing errors across layers

Each layer owns its error type and wraps the layer below. Conversions are `From` impls at the module boundary, so `?` works and internals do not leak upward.

```rust
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("configuration error")]
    Config(#[from] ConfigError),

    #[error("database error")]
    Storage(#[from] StorageError),
}
```

Here `#[from]` is correct: `ConfigError` has exactly one meaning inside `AppError`.

Do not re-export a dependency's error type as your own variant payload in a public library API unless you also commit to that dependency's semver. Wrap it opaquely when in doubt:

```rust
#[derive(Debug, thiserror::Error)]
#[error(transparent)]
pub struct HttpError(reqwest::Error); // private field, no `#[from]`

impl HttpError {
    // pub(crate): a public `From<reqwest::Error>` would put reqwest in the semver surface.
    pub(crate) fn new(source: reqwest::Error) -> Self {
        Self(source)
    }
}

// internal call sites: client.get(url).send().await.map_err(HttpError::new)?
```

`#[from]` generates a **public** `impl From<reqwest::Error> for HttpError`, so callers could rely on it and a reqwest major bump becomes your breaking change. Keep the constructor crate-private and convert with `map_err`.

## 4. Reporting in binaries

`main` is the only place where errors are turned into text for a human. Pick one approach per binary:

| Approach | Use when |
|---|---|
| Typed top-level enum + manual printing of the `source()` chain | small binaries, services, full control over output and exit codes |
| `miette` | compilers, config/DSL parsers, CLIs that point at spans in input |
| `color-eyre` | developer-facing CLIs that want pretty reports, backtraces and span traces |

### Typed top-level enum

```rust
use std::process::ExitCode;

fn main() -> ExitCode {
    tracing_subscriber::fmt().with_env_filter(EnvFilter::from_default_env()).init();
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            report(&err);
            err.exit_code()
        }
    }
}

fn report(err: &dyn std::error::Error) {
    let mut message = err.to_string();
    let mut source = err.source();
    while let Some(cause) = source {
        message.push_str(&format!("\n  caused by: {cause}"));
        source = cause.source();
    }
    tracing::error!("{message}");
}

impl AppError {
    fn exit_code(&self) -> ExitCode {
        match self {
            Self::Config(_) => ExitCode::from(78), // EX_CONFIG
            Self::Storage(_) => ExitCode::from(74), // EX_IOERR
        }
    }
}
```

`main` and `report` are legitimate free functions: the entry point has no owning type.

### miette

Domain errors derive `miette::Diagnostic` alongside `thiserror::Error` when they carry spans; `main` returns `miette::Result<()>`. Keep `miette` out of library crates unless the library *is* a diagnostics producer (parser, linter) — then expose `Diagnostic` behind a feature.

### Exit codes

- `0` success, `1` generic failure, `2` usage error (clap does this already).
- For CLIs used in scripts, map error variants to stable codes (BSD `sysexits` values 64–78 are a common convention) and document them.
- Return `ExitCode` from `main` rather than calling `std::process::exit` deep in the code — `exit` skips destructors (flushes, temp-file cleanup).

## 5. Panics vs errors

- Expected failure (bad input, missing file, network down) → `Result`.
- Broken invariant (a bug) → panic. `unwrap()` is denied outside tests; `expect("invariant: …")` must state why failure is impossible, and the function documents `# Panics`.
- Libraries never panic on user input. Validate and return an error.
- `panic = "abort"` in release profiles of applications is fine; libraries must not assume either strategy.

## 6. Documentation

Pedantic's `missing_errors_doc` and `missing_panics_doc` require these sections on public items. Even when a project allows those lints, write them on public library APIs:

```rust
/// # Errors
///
/// Returns [`StorageError::NotFound`] if no row matches `id`.
```

Link variants with intra-doc links so renames break the docs build (`RUSTDOCFLAGS="-D warnings"`).

## Anti-patterns

- `anyhow::Result` in a library or domain module signature.
- `#[error("{0}")] Other(String)` as the default catch-all.
- One giant crate-wide `Error` with 40 variants used by every module — split per domain.
- `.map_err(|e| e.to_string())` — destroys the source chain.
- Logging an error *and* returning it — it gets reported twice. Log at the point where it is handled, not where it is propagated.
- `#[from] std::io::Error` on an enum where several operations produce I/O errors.
- `process::exit` inside library or deep application code.
- `Box<dyn Error + Send + Sync>` as a "temporary" return type that never gets replaced.

## Checklist

- [ ] Each module/domain with fallible operations has its own typed error.
- [ ] Every variant carries enough context to act on (path, id, expected vs actual).
- [ ] Source errors are chained with `#[source]`/`#[from]`, not stringified.
- [ ] `From` conversions exist at layer boundaries; `?` composes without manual mapping noise.
- [ ] Public library error enums are `#[non_exhaustive]`.
- [ ] Public fallible functions document `# Errors`; panicking ones document `# Panics`.
- [ ] `main` reports the full chain once and returns a meaningful `ExitCode`.
- [ ] No `anyhow` outside the binary's reporting layer.

See also: [api-design.md](api-design.md), [cli-config.md](cli-config.md), [observability.md](observability.md).
