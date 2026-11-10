# Observability

> Read when: adding logging/diagnostics, setting up `tracing` in a binary, choosing log levels, instrumenting async code, or investigating runtime behavior in production.

## The split: libraries emit, binaries collect

| Crate kind | Does | Never does |
|---|---|---|
| Library | emits `tracing` events and spans (`tracing::debug!`, `#[instrument]`) | installs a subscriber, prints, decides format or destination |
| Binary | installs exactly one subscriber at the start of `main`, picks filter/format/sink | sprinkles `println!` for diagnostics |

Installing a global subscriber inside a library hijacks the host application's logging and fails (or silently no-ops) when the host installs its own. A library depends on `tracing` alone, never on `tracing-subscriber` (except as a dev-dependency for tests).

```toml
# library
[dependencies]
tracing = { workspace = true }

# binary
[dependencies]
tracing = { workspace = true }
tracing-subscriber = { workspace = true, features = ["env-filter", "fmt"] }
```

## Binary setup

```rust
use tracing_subscriber::{EnvFilter, fmt, prelude::*};

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,my_app=debug"));

    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().with_target(true))
        .init();
}
```

- `RUST_LOG` (read by `EnvFilter::try_from_default_env`) is the standard override: `RUST_LOG=warn,my_app::net=trace`.
- The default filter in code should be quiet for dependencies (`info` or `warn`) and more verbose for your own crates.
- Choose the format by audience:
  - human terminal → `fmt::layer()` (optionally `.pretty()` for dev);
  - log aggregation → `fmt::layer().json()` (requires the `json` feature of `tracing-subscriber`);
  - systemd services → `tracing-journald` layer;
  - long-running desktop apps → `tracing-appender` for rotating files. Keep its `WorkerGuard` alive for the program's lifetime or buffered lines are lost on exit.
- Install the subscriber before anything else logs. Initialize once; calling `.init()` twice panics. Use `.try_init()` in tests.

## Events and spans

- **Structured fields over formatted strings.** Fields are queryable; interpolated strings are not.

  ```rust
  // ✓
  tracing::warn!(path = %path.display(), attempt, "retrying config read");
  // ✗
  tracing::warn!("retrying config read of {} attempt {}", path.display(), attempt);
  ```

  `%` uses `Display`, `?` uses `Debug`. Bare identifiers record the value directly.

- **Spans for units of work** (a request, a job, a frame, a connection). Events inside inherit the span's fields, so you don't repeat IDs in every message.

- **`#[instrument]`** on functions that represent a unit of work:

  ```rust
  #[tracing::instrument(skip(self, payload), fields(len = payload.len()), err)]
  async fn upload(&self, id: DeviceId, payload: &[u8]) -> Result<(), UploadError> { … }
  ```

  - `skip(...)` anything large, secret, or without a useful `Debug` (`self`, buffers, credentials). `skip_all` + explicit `fields(...)` is the safest default for public APIs.
  - `err` records the returned error at `ERROR` level when the function fails; use `err(level = "warn")` for expected failures.
  - Do not instrument hot inner loops; the per-call span cost adds up.

- **Async**: spans must follow the future, not the thread. `#[instrument]` handles this. For manually spawned tasks, use `.instrument(span)` from `tracing::Instrument`. Never hold a `span.enter()` guard across `.await`; it attaches the wrong span to other tasks polled on the same thread.

## Levels

| Level | Use for | Example |
|---|---|---|
| `error!` | operation failed and needs attention; user-visible impact | "failed to persist settings" |
| `warn!` | something unexpected, recovered or degraded | "falling back to software encoder" |
| `info!` | lifecycle milestones, low-volume and useful in production | "listening on 0.0.0.0:7720", "connected to device" |
| `debug!` | developer detail per operation | "decoded frame header" |
| `trace!` | very high volume, step-by-step | per-packet, per-frame internals |

- Log an error **once**, where it is handled, not at every `?` on the way up. Propagate with context; the handler logs.
- Never log secrets, tokens, full request bodies or personal data. Wrap secrets in `secrecy::SecretString` so `Debug` redacts them (see `references/security.md`).

## `log` vs `tracing`

`tracing` is the default. Use the `log` facade when:

- the target ecosystem expects it (e.g. Android via `android_logger`, or a project that already standardized on `log`/`env_logger`);
- you write a small library whose users predominantly use `log`.

The two interoperate. `tracing` events reach `log` consumers via the `log` feature of `tracing`, and `log` records reach a tracing subscriber via `tracing-log` (enabled by default in `tracing-subscriber`'s `tracing-log` feature). Pick one per project and stay consistent.

## Errors and panics

- In binaries, install a panic hook that logs through tracing before aborting, so crashes in GUI/daemon processes leave a trace:

  ```rust
  std::panic::set_hook(Box::new(|info| {
      tracing::error!(panic = %info, "panicked");
  }));
  ```

  `color-eyre` and `miette` install their own hooks. Use one hook owner, not several.
- With `panic = "abort"` in release, the hook still runs before the abort. The process just does not unwind.

## Metrics and profiling (optional)

- Counters/histograms for services: the `metrics` crate facade with an exporter (Prometheus, OTLP). For distributed services, OpenTelemetry via `tracing-opentelemetry`. Only add these when someone will actually consume the data.
- Profiling: `tracing` spans are not a profiler. For CPU profiles use `perf`/`samply`/`cargo flamegraph`. For in-app timelines, frame times, allocations and post-release recordings, see **sismo** in `references/ecosystem.md`. It ingests `log` and `tracing` events via features and adds `#[sismo::function]` scopes and a flight recorder.

## Tests

- Capture logs in tests with `tracing-subscriber`'s test writer: `tracing_subscriber::fmt().with_test_writer().try_init()`. `try_init` avoids double-init panics across tests.
- Assert on behavior, not on log lines. Log text is not API.

## Checklist

- [ ] Libraries depend only on `tracing`; no subscriber, no `print*` (enforce with `clippy::print_stdout`/`print_stderr`).
- [ ] Binary installs one subscriber with `EnvFilter` honoring `RUST_LOG`.
- [ ] Structured fields, not interpolated strings.
- [ ] `#[instrument(skip(...))]` on units of work; secrets and large values skipped.
- [ ] Errors logged once, where handled.
- [ ] File appender guard kept alive; panic hook routes to tracing.
