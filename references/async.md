# Async

> Read when: writing async code, setting up a tokio runtime, using `select!`, adding timeouts or graceful shutdown, or designing a library that should not force a runtime on users.

## 1. Runtime choice and setup

- Applications: `tokio`, unless the project already uses something else.
- Libraries: be **executor-agnostic** when feasible — expose `async fn`/futures and plain channels (`flume`, `async-channel`, `futures-channel`), never spawn onto a runtime the caller did not choose. When runtime integration is required, gate it behind a feature (`tokio = ["dep:tokio"]`).
- List features explicitly. Never `features = ["full"]` in a library; applications should also prefer the minimal set:

```toml
[workspace.dependencies]
tokio = { version = "1", default-features = false, features = ["rt-multi-thread", "macros", "net", "time", "sync", "signal"] }
```

- Configure the runtime in `main` only:

```rust
#[tokio::main]
async fn main() -> ExitCode {
    // ...
}
```

For custom worker counts or thread names, build it explicitly with `tokio::runtime::Builder::new_multi_thread().thread_name("app-worker").enable_all().build()`.

## 2. Never block the executor

Blocking inside an async task stalls every other task on that worker.

| Blocking work | Do instead |
|---|---|
| `std::fs`, blocking sockets | `tokio::fs`, `tokio::net` |
| `reqwest::blocking` | async `reqwest` |
| CPU-heavy work (hashing, compression, parsing big files) | `tokio::task::spawn_blocking`, or `rayon` with a oneshot channel |
| a synchronous library call you cannot avoid | `spawn_blocking` |

`Runtime::block_on` or `#[tokio::main]` inside an existing runtime **panics** ("Cannot start a runtime from within a runtime"). This often happens through `reqwest::blocking` in async code.

## 3. Locks across `.await`

| Situation | Lock |
|---|---|
| Short critical section, no `.await` while held | `std::sync::Mutex` or `parking_lot::Mutex` (faster, recommended by tokio docs) |
| Guard must be held across `.await` | `tokio::sync::Mutex` |
| Read-mostly shared config | `arc-swap`, or `tokio::sync::watch` |

Holding a `std` guard across `.await` makes the future `!Send` (compile error with `tokio::spawn`) and risks deadlock; `clippy::await_holding_lock` flags it. Scope the guard so it drops before the await:

```rust
let next = {
    let mut queue = self.queue.lock();
    queue.pop_front()
}; // guard dropped here
if let Some(job) = next {
    job.run().await;
}
```

Better still: make the state owned by one task and talk to it via channels (actor pattern), so there is no lock at all.

## 4. Spawning and structured concurrency

- `tokio::task::JoinSet` for a dynamic set of tasks; it aborts remaining tasks on drop and avoids the `futures` dependency.

```rust
let mut set = JoinSet::new();
for url in urls {
    let client = self.client.clone();
    set.spawn(async move { client.fetch(&url).await });
}
while let Some(result) = set.join_next().await {
    match result {
        Ok(Ok(page)) => pages.push(page),
        Ok(Err(err)) => tracing::warn!(%err, "fetch failed"),
        Err(join_err) => tracing::error!(%join_err, "fetch task panicked or was cancelled"),
    }
}
```

- Bounded concurrency: `tokio::sync::Semaphore` with `acquire_owned`, or `futures::StreamExt::buffer_unordered` when `futures` is already a dependency.
- Never fire-and-forget a `tokio::spawn` whose failure matters. Keep the `JoinHandle` or put it in a `JoinSet`; detached tasks swallow panics and errors.
- Group related tasks in a type (a service/handle struct owning its `JoinSet` and `CancellationToken`), not in free functions passing handles around.

## 5. `select!` and cancellation safety

When one `select!` branch completes, the other futures are **dropped**. A future is cancellation-safe if dropping it mid-way loses nothing.

- Safe: `mpsc::Receiver::recv`, `broadcast::Receiver::recv`, `TcpListener::accept`, `sleep`, `CancellationToken::cancelled`.
- Not safe: `AsyncReadExt::read_exact`, `read_to_end`, `write_all`, anything that buffers partial progress internally, most hand-written `async fn` with multiple awaits.

Rules:

- Only put cancellation-safe futures directly in a `select!` loop. For unsafe ones, create the future once outside the loop, pin it (`tokio::pin!`), and poll `&mut fut`.
- Document cancellation safety on public async methods ("This method is cancel-safe").
- Use `biased;` when branch priority matters (e.g. shutdown first).

## 6. Timeouts and retries

- Wrap every network call in `tokio::time::timeout` (or the client's own timeout setting). An unbounded await is a hang waiting to happen.
- `timeout` returns `Err(Elapsed)`; map it to a typed error variant (`FetchError::Timeout { url, after }`).
- Retries: exponential backoff with jitter and a max attempt count stored in a policy type (see [api-design.md](api-design.md) builder example). Only retry idempotent operations.

## 7. Graceful shutdown

Use `tokio_util::sync::CancellationToken` (from `tokio-util`) as the shutdown signal, and a `JoinSet`/`TaskTracker` to wait for tasks.

```rust
pub struct Server {
    shutdown: CancellationToken,
    tasks: JoinSet<()>,
}

impl Server {
    pub async fn run(mut self, listener: TcpListener) {
        loop {
            tokio::select! {
                biased;
                () = self.shutdown.cancelled() => break,
                accepted = listener.accept() => match accepted {
                    Ok((stream, peer)) => {
                        let token = self.shutdown.child_token();
                        self.tasks.spawn(Connection::from(stream).serve(token, peer));
                    }
                    Err(err) => tracing::warn!(%err, "accept failed"),
                },
            }
        }
        while self.tasks.join_next().await.is_some() {}
    }
}
```

In `main`, cancel the token on `tokio::signal::ctrl_c()` (and `SIGTERM` via `tokio::signal::unix` on Unix). Give tasks a deadline (`timeout`) to finish before exiting.

## 8. Async traits

- Native `async fn` in traits is stable (1.75+). Use it for internal traits.
- For public traits where callers need `Send` futures, declare it: `fn fetch(&self) -> impl Future<Output = Result<Page, FetchError>> + Send;`, or use `trait-variant` to generate a `Send` variant.
- `async-trait` (boxing) only when you need `dyn Trait` with async methods.
- Async closures (`async || {}`, stable since 1.85) replace many `move || async move {}` patterns.

## 9. Streams and channels

- `tokio::sync::mpsc` (bounded) by default — bounded channels give backpressure. Unbounded channels are a memory leak waiting for a slow consumer.
- `broadcast` for fan-out events, `watch` for latest-value state, `oneshot` for request/response.
- `tokio-stream` / `futures::Stream` only when you need stream combinators.

## Anti-patterns

- `std::thread::sleep` inside async code.
- `futures::executor::block_on` inside a tokio task.
- `tokio = { features = ["full"] }` in a library.
- Spawning tasks and dropping the `JoinHandle` for work whose errors matter.
- `select!` on `read_exact` in a loop (data loss on cancel).
- Unbounded channels between producer and consumer of different speeds.
- `Arc<tokio::sync::Mutex<T>>` where no guard ever crosses an await (slower and pointless).
- Network calls without timeouts.

## Checklist

- [ ] Runtime is chosen in `main`; libraries do not force one.
- [ ] tokio features are explicit and minimal.
- [ ] No blocking calls on async workers; CPU work in `spawn_blocking`/rayon.
- [ ] No std lock guard held across `.await` (`await_holding_lock` clean).
- [ ] All spawned tasks are tracked; their errors are observed.
- [ ] Every `select!` branch is cancellation-safe or pinned outside the loop.
- [ ] Network operations have timeouts; retries are bounded and only for idempotent ops.
- [ ] Shutdown is cooperative via `CancellationToken` with a deadline.

See also: [concurrency.md](concurrency.md), [errors.md](errors.md), [testing.md](testing.md).
