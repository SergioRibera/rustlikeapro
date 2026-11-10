# Concurrency

> Read when: using threads, rayon, atomics, channels or locks; reasoning about `Send`/`Sync`; writing lock-free code. For async specifics see [async.md](async.md).

## 1. Choose the model first

| Problem | Tool |
|---|---|
| Data-parallel CPU work over a collection | `rayon` (`par_iter`) |
| Long-lived background worker | named `std::thread` + channel |
| Many concurrent I/O operations | async (`tokio`) — see [async.md](async.md) |
| Shared read-mostly state | `Arc<T>` (immutable), `arc-swap`, `RwLock` |
| Shared mutable state, short sections | `Mutex` (`std` or `parking_lot`) |
| Counters, flags | atomics |
| Ownership handoff between threads | channels |

Default preference: **message passing over shared mutable state**. A component that owns its state and receives commands through a channel has no locks to get wrong. `Arc<Mutex<T>>` is a decision you can justify, never a reflex.

## 2. `Send` and `Sync`

- `T: Send` — ownership of `T` can move to another thread.
- `T: Sync` — `&T` can be shared between threads (`T: Sync` ⇔ `&T: Send`).
- `Rc`, `RefCell`, `Cell` and raw pointers are not `Sync` (and `Rc` is not `Send`). If the compiler says a future or closure is not `Send`, find the `Rc`/`RefCell`/guard captured in it — do not reach for `unsafe impl Send`.
- `unsafe impl Send/Sync` is allowed only with a `// SAFETY:` comment proving thread safety (e.g. a handle to a thread-safe C library), see [unsafe-ffi.md](unsafe-ffi.md).
- Assert auto traits for public types so regressions fail at compile time (see [api-design.md](api-design.md)).

## 3. Threads

Always name threads — names appear in panics, debuggers, profilers and sismo/tracing output:

```rust
let handle = std::thread::Builder::new()
    .name("audio-decoder".into())
    .spawn(move || decoder.run(rx))
    .map_err(|source| PipelineError::SpawnThread { name: "audio-decoder", source })?;
```

Projects can enforce this with `clippy.toml`:

```toml
disallowed-methods = [
    { path = "std::thread::spawn", reason = "name the thread with std::thread::Builder" },
]
```

- Keep the `JoinHandle`; join on shutdown and handle the `Err` (the thread panicked).
- `std::thread::scope` for borrowing stack data in short-lived parallel work without `Arc`:

```rust
std::thread::scope(|scope| {
    for chunk in data.chunks(1024) {
        scope.spawn(|| process(chunk));
    }
}); // all threads joined here
```

## 4. rayon

```rust
use rayon::prelude::*;

let thumbnails: Vec<Thumbnail> = images
    .par_iter()
    .map(Thumbnail::from)
    .collect();
```

- Use for CPU-bound work with enough items to amortize overhead. Measure — small collections are slower in parallel.
- Do not call blocking I/O inside rayon tasks; it starves the pool.
- Bridge from async: run rayon work inside `spawn_blocking` or send results back via a `tokio::sync::oneshot`.
- A custom pool (`ThreadPoolBuilder::new().thread_name(|i| format!("render-{i}"))`) when work must be isolated from the global pool.

## 5. Locks

- `std::sync::Mutex` is fine and poison-aware. Poisoning means another thread panicked while holding the lock; `lock()` returns `Err`. Decide explicitly: `.lock().expect("invariant: no panics while holding the state lock")` is acceptable when a panic elsewhere is already fatal; otherwise recover with `into_inner()`.
- `parking_lot::Mutex`/`RwLock`: no poisoning, smaller, faster under contention. Good default for applications; some projects ban `std::sync::Mutex` via `disallowed-types` in favor of it.
- Keep critical sections short. Never call out to unknown code (callbacks, trait objects, logging sinks that lock) while holding a lock.
- Lock ordering: when two locks are needed, always acquire in the same documented order. Better: merge them into one lock or one owning task.
- `RwLock` only pays off for read-heavy workloads with long reads; under write contention it is slower than `Mutex`.

## 6. Atomics

Pick the weakest ordering that is correct, and comment why.

| Ordering | Use |
|---|---|
| `Relaxed` | counters and statistics where no other memory depends on the value |
| `Release` (store) / `Acquire` (load) | publishing data: writer stores with `Release` after preparing data; reader loads with `Acquire` before reading it |
| `AcqRel` | read-modify-write that both consumes and publishes (`fetch_add` on a ref count used for synchronization) |
| `SeqCst` | only when you need a single total order across several atomics; if unsure *and* not performance-critical, use it and leave a comment |

```rust
pub struct Stats {
    frames: AtomicU64,
}

impl Stats {
    pub fn record_frame(&self) {
        // Relaxed: pure counter, nothing else is synchronized through it.
        self.frames.fetch_add(1, Ordering::Relaxed);
    }
}
```

- Shutdown flags: `AtomicBool` with `Release` store / `Acquire` load, or better a channel/`CancellationToken`.
- Lock-free data structures are rarely worth writing yourself — use `crossbeam` (queues, epoch GC), `arc-swap`, `dashmap` (check its current soundness/maintenance status before adopting).

## 7. Channels

| Channel | When |
|---|---|
| `std::sync::mpsc` | simple thread-to-thread, std only |
| `crossbeam-channel` | MPMC, `select!` across channels, high throughput sync code |
| `flume` | MPMC usable from both sync and async — good for executor-agnostic libraries |
| `tokio::sync::{mpsc, broadcast, watch, oneshot}` | inside tokio applications |

- Prefer **bounded** channels; the bound is your backpressure policy. Document what happens when full (block, drop oldest, error).
- Dropping all senders closes the channel — use that for shutdown instead of a separate flag.

## 8. Testing concurrent code

- Stress tests in release mode with many iterations catch some races, not all.
- `loom` (optional) exhaustively explores interleavings for small lock-free or custom-sync components; gate with `#[cfg(loom)]`.
- Miri detects data races in `unsafe` code (`cargo +nightly miri test`).
- ThreadSanitizer (`RUSTFLAGS="-Zsanitizer=thread"`, nightly) for larger programs.

## Anti-patterns

- `Arc<Mutex<Vec<T>>>` shared by every component as a global bus.
- Spawning unnamed threads and dropping their handles.
- `SeqCst` everywhere "to be safe" without understanding, or `Relaxed` for a flag that publishes data.
- Holding a lock while sending on a bounded channel (deadlock when full).
- `unsafe impl Sync` to silence a compiler error.
- Busy-wait loops on atomics without `std::hint::spin_loop` or a proper wait primitive.
- rayon inside async tasks without `spawn_blocking`.

## Checklist

- [ ] Concurrency model chosen deliberately (rayon / threads / async / channels).
- [ ] All threads named; handles joined and panics handled.
- [ ] No lock held across callbacks, channel sends or `.await`.
- [ ] Atomic orderings justified in comments.
- [ ] Channels bounded with a documented full-policy.
- [ ] No `unsafe impl Send/Sync` without a `SAFETY` proof.
- [ ] Concurrency-sensitive code has stress/loom/Miri coverage.

See also: [async.md](async.md), [performance.md](performance.md), [unsafe-ffi.md](unsafe-ffi.md).
