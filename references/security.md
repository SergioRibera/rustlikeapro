# Security

> Read when: handling secrets, credentials or personal data; parsing untrusted input (network, files, IPC, plugins); using cryptography or TLS; exposing a service; reviewing `unsafe`; or hardening a release.

Rust removes whole bug classes (use-after-free, data races) only in **safe** code. It does not protect against logic bugs, resource exhaustion, injection, leaked secrets, or a malicious dependency. Treat every trust boundary explicitly.

## Secrets

- Wrap secrets in `secrecy::SecretString` / `SecretBox<T>`. `Debug` prints `[REDACTED]`, and access requires an explicit `.expose_secret()`, which makes every use greppable.

  ```rust
  use secrecy::{ExposeSecret, SecretString};

  pub struct Credentials {
      pub user: String,
      pub token: SecretString,
  }

  client.bearer_auth(creds.token.expose_secret());
  ```

- `zeroize` (pulled in by `secrecy`) wipes memory on drop. Use `Zeroizing<Vec<u8>>` for key material in buffers you manage. This is best-effort: copies made by `clone`, reallocation or swap are not covered, so minimize copies.
- Never log, `Debug`-print, serialize or put secrets in error messages. Use `#[instrument(skip(token))]` / `skip_all` on functions that receive them.
- Secrets come from env vars, a secret manager or the OS keyring (`keyring` crate). Never from committed config files, and never compiled in via `include_str!` / `env!`.
- CI secrets are scoped to the single step that needs them (see `references/ci-hardening.md`).

## Comparing secrets: constant time

`==` on byte slices short-circuits on the first mismatch, which leaks timing. Compare MACs, tokens and password hashes in constant time:

```rust
use subtle::ConstantTimeEq;

fn token_matches(given: &[u8], expected: &[u8]) -> bool {
    given.ct_eq(expected).into()
}
```

Better still, let the primitive do it: verify via `hmac::Mac::verify_slice`, or the password-hash crate's `verify_password`.

## Cryptography

- **Never implement your own crypto primitives or protocols.** Use audited crates: RustCrypto (`sha2`, `hmac`, `aes-gcm`, `chacha20poly1305`, `argon2`, `ed25519-dalek`) or `ring` / `aws-lc-rs`.
- Passwords: `argon2` (or `scrypt` / `bcrypt`) with per-user salts, never a plain hash.
- Randomness for keys, tokens and nonces: the OS CSPRNG directly (`getrandom`, or `rand::rngs::OsRng`). `rand`'s thread-local RNG (`rand::rng()` in rand 0.9, formerly `thread_rng()`) is a CSPRNG seeded from the OS, fine for general use, but for long-lived key material prefer the OS source. Never `SmallRng`/`StdRng::seed_from_u64` or any time-based seed for secrets.
- AEAD nonces must never repeat under the same key. Use random 192-bit nonces (XChaCha20-Poly1305) or a counter you can prove unique.

## TLS

- **Default to `rustls`**, not OpenSSL: pure Rust, memory-safe, no system library version drift, easy cross-compilation. Disable default features of HTTP clients and select rustls explicitly:

  ```toml
  reqwest = { workspace = true, default-features = false, features = ["rustls-tls", "json"] }
  ```

  The exact feature names vary by crate and version, so check the crate's `Cargo.toml` features table.
- Never disable certificate verification ("danger" APIs) outside a test-only, cfg-gated code path.
- Use `cargo deny` `[bans]` to keep `openssl-sys` out of the tree when the project has decided on rustls.

## Untrusted input

Everything from the network, a file the user didn't author, IPC, a plugin or a child process is hostile until validated.

- **Bound sizes before reading or parsing**: `reader.take(MAX_BYTES)`, HTTP body limits (`axum::extract::DefaultBodyLimit`, `tower_http::limit`), maximum message length in framed protocols. An attacker-supplied `len` field must never drive `Vec::with_capacity` unchecked.

  ```rust
  const MAX_FRAME: u32 = 16 * 1024 * 1024;
  let len = u32::from_le_bytes(header);
  if len > MAX_FRAME {
      return Err(ProtocolError::FrameTooLarge { len, max: MAX_FRAME });
  }
  ```

- **Bound counts, depth and time**: collection lengths, recursion depth (deeply nested JSON), decompression ratio (zip bombs), regex complexity (the `regex` crate is linear-time, good; avoid backtracking engines on user patterns), request timeouts and connection limits.
- **Parse, then validate into domain types**: DTO → `TryFrom` → type with invariants (`NonZero*`, newtypes, enums). The rest of the code never sees unvalidated data. See `references/serialization.md`.
- **Arithmetic on untrusted values**: `checked_*` / `saturating_*`. Overflow panics in debug builds and wraps silently in release unless `overflow-checks = true`.
- **Indexing with untrusted values**: `get()` instead of `[]`, because a panic is a DoS.

## Paths and filesystem

- **Path traversal**: never join a user-supplied path onto a base directory and trust the result. `base.join("../../etc/passwd")` escapes, and an absolute input *replaces* the base.

  ```rust
  fn safe_join(base: &Path, user: &Path) -> Result<PathBuf, PathError> {
      // RootDir too: on Windows `\x` is not `is_absolute()` but still escapes the base.
      if user.is_absolute()
          || user.components().any(|c| {
              matches!(c, Component::ParentDir | Component::RootDir | Component::Prefix(_))
          })
      {
          return Err(PathError::Escapes);
      }
      Ok(base.join(user))
  }
  ```

  For stronger guarantees (symlinks), canonicalize and check `starts_with(base)`, or use capability-based APIs (`cap-std`).
- Archive extraction (zip/tar): validate every entry path with the same check ("zip slip").
- Temporary files: `tempfile` (secure creation), not hand-built names in `/tmp`. Watch for TOCTOU between check and use.
- Create files with restrictive permissions when they hold secrets (`OpenOptions` + `std::os::unix::fs::OpenOptionsExt::mode(0o600)` inside a `#[cfg(unix)]` platform module).

## Processes and injection

- Spawn processes with `std::process::Command` and **separate arguments** (`.arg(user_value)`), never via a shell string (`sh -c format!(…)`).
- SQL: parameterized queries only (`sqlx` macros / bind parameters). Never `format!` into SQL.
- HTML/templating: an escaping template engine; never concatenate user input into markup.

## Deserialization and plugins

- Untrusted serialized data: size limits (cap the input buffer before decoding with `postcard`/`bitcode`, `serde_json` with a bounded reader), no `#[serde(untagged)]` on security-relevant types (ambiguous matching), and validation via `TryFrom`.
- Dynamically loaded plugins (`libloading`, `stabby`) run with full process privileges. Loading one is executing code; treat plugin directories as trusted-only and document it.

## Fuzzing

Fuzz every parser of untrusted input (custom binary formats, protocol decoders, config parsers, codecs):

```bash
cargo install --locked cargo-fuzz   # installs on stable; running needs nightly
cargo fuzz init
cargo fuzz add parse_frame
cargo +nightly fuzz run parse_frame
```

```rust
// fuzz/fuzz_targets/parse_frame.rs
#![no_main]
libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    let _ = my_proto::Frame::parse(data); // must never panic, hang or OOM
});
```

- Keep the corpus and any crash reproducers as regression tests in `tests/`.
- For structured inputs, use `arbitrary` derives so the fuzzer generates valid-ish values.
- Property tests (`proptest`) complement fuzzing for invariants such as round-trips (`decode(encode(x)) == x`). See `references/testing.md`.

## `unsafe` review

Every `unsafe` block is security-relevant. Review rules (details in `references/unsafe-ffi.md`):

- A `// SAFETY:` comment states the invariants, and the reviewer checks each one against the code.
- Prefer safe abstractions from audited crates (`bytemuck`, `zerocopy`) over hand-rolled transmutes.
- Run Miri on crates with `unsafe` (`cargo +nightly miri test`). Don't cache Miri jobs and don't expose secrets to them in CI (see `references/ci-hardening.md`).
- FFI boundaries validate every pointer, length and UTF-8 string coming from the other side.

## Supply chain

A malicious or compromised dependency runs code at build time (`build.rs`, proc macros) and at runtime. This is not hypothetical: the Rust blog reported a compromised crate pulling in a malicious build-script dependency (https://blog.rust-lang.org/2026/08/20/supply-chain-attack-on-arrayref/). Defenses live in `references/supply-chain.md`:

- `cargo deny check` (advisories, licenses, bans, sources) in CI and on a schedule.
- `Cargo.lock` committed in every project, libraries included; `--locked` in CI.
- Review new dependencies (maintainers, download count, `build.rs`, proc macros) before adding them; prefer fewer dependencies.

## Checklist

- [ ] Secrets in `SecretString`, never logged/serialized; sourced from env/secret store.
- [ ] Constant-time comparison for tokens/MACs; audited crypto only; OS CSPRNG.
- [ ] rustls by default; no disabled cert verification outside tests.
- [ ] Input sizes, counts, depth and time bounded; validated into domain types.
- [ ] Path joins checked for traversal; no shell-string commands; parameterized SQL.
- [ ] Parsers fuzzed; `unsafe` reviewed and Miri-tested; `cargo deny` in CI.
