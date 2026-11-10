# Multiplatform and cross-compilation

> Read when: code must run on more than one OS/target, adding `#[cfg]` platform code, structuring backends per platform, cross-compiling (Windows, macOS, Android, iOS, wasm, musl), or building a CI target matrix.

## Adopt platforms in tiers

Don't design for every platform on day one. Grow in tiers and keep each tier green in CI before starting the next:

| Tier | Targets | What it forces |
|---|---|---|
| 1 | Linux (`x86_64-unknown-linux-gnu`) | the core: clean architecture, platform code isolated behind traits from the start |
| 2 | Windows (`x86_64-pc-windows-msvc`), macOS (`aarch64-apple-darwin`) | path handling, line endings, case-insensitive FS, file locking, process APIs |
| 3 | Android (`aarch64-linux-android`), iOS (`aarch64-apple-ios`), wasm (`wasm32-unknown-unknown`) | no `std::process`/filesystem assumptions, lifecycle callbacks, native API bridges, packaging |

Even in tier 1, keep platform-specific code behind the abstraction below. Retrofitting it later is the expensive part.

## Platform abstraction layout (winit pattern)

```
src/
  platform.rs          // public, per-OS extension traits: pub mod wayland; pub mod windows; ...
  platform/
    wayland.rs         // pub trait WindowExtWayland { fn wayland_surface(&self) -> ... }
    windows.rs
  platform_impl.rs     // private: selects exactly one backend
  platform_impl/
    linux.rs
    windows.rs
    macos.rs
    android.rs
    web.rs
```

```rust
// platform_impl.rs
#[cfg(windows_platform)]
mod windows;
#[cfg(windows_platform)]
use windows as platform;

#[cfg(free_unix)]
mod linux;
#[cfg(free_unix)]
use linux as platform;

#[cfg(web_platform)]
mod web;
#[cfg(web_platform)]
use web as platform;

pub(crate) use self::platform::*;
```

- **Every backend exports the same internal API** (same type names, same method signatures). The cross-platform layer is written once against `platform::Window`, `platform::EventLoop`, etc. Document that contract in the root file, as gilrs-core does in `platform/mod.rs`.
- **Public platform-specific functionality goes through extension traits** (`EventLoopExtWayland`, `WindowExtWindows`), implemented only on the relevant target. Users opt in explicitly, and the common API stays clean.
- **Provide a fallback backend** for unsupported targets when the crate should still compile there (gilrs has a `default` backend that reports "no gamepads"). Otherwise fail loudly at compile time with a clear message.
- `#[cfg]` belongs in the platform modules, not scattered through business logic. A `#[cfg(target_os = …)]` deep inside domain code is a missing abstraction.
- Module layout follows the skill rule: `platform_impl.rs` + `platform_impl/`. The `#[path = "linux/mod.rs"]` trick is an accepted exception for platform selection only.

## `cfg_aliases` and check-cfg

Long `cfg` expressions repeated everywhere drift. Define named aliases once in `build.rs` with the `cfg_aliases` crate:

```rust
// build.rs
use cfg_aliases::cfg_aliases;

fn main() {
    cfg_aliases! {
        web_platform: { all(target_family = "wasm", target_os = "unknown") },
        android_platform: { target_os = "android" },
        apple_mobile: { any(target_os = "ios", target_os = "tvos", target_os = "visionos") },
        free_unix: { all(unix, not(target_vendor = "apple"), not(android_platform)) },
        x11_platform: { all(feature = "x11", free_unix) },
        wayland_platform: { all(feature = "wayland", free_unix) },
    }
}
```

Since Rust 1.80, rustc checks `cfg` names (`unexpected_cfgs` lint). Custom cfgs must be declared:

- from `build.rs`: `println!("cargo::rustc-check-cfg=cfg(my_cfg)");` (recent `cfg_aliases` versions emit this for their aliases);
- or in the manifest for cfgs set externally (e.g. `docsrs`):

  ```toml
  [lints.rust]
  unexpected_cfgs = { level = "warn", check-cfg = ["cfg(docsrs)"] }
  ```

Since Rust 1.95, `cfg_select!` offers match-like selection inside expressions, which is useful for small per-platform values without a module split.

## Features and platforms

- Platform backends that are optional (X11 vs Wayland) are **additive features**, enabled by default where sensible.
- **Mutually exclusive features** (two backends that cannot coexist) fail fast with a fix-it message, as gilrs does:

  ```rust
  #[cfg(all(feature = "xinput", feature = "wgi"))]
  compile_error!("features `xinput` and `wgi` are mutually exclusive; disable default features and pick one");
  ```

  Prefer designs where features stay additive. `compile_error!` is the honest fallback when they cannot.
- Put platform-only dependencies under target tables so other platforms never download or build them:

  ```toml
  [target.'cfg(target_os = "android")'.dependencies]
  jni = { workspace = true }

  [target.'cfg(windows)'.dependencies]
  windows-sys = { workspace = true, features = ["Win32_UI_WindowsAndMessaging"] }
  ```

## Toolchains and targets

- Declare targets in `rust-toolchain.toml` so every contributor and CI job has them:

  ```toml
  [toolchain]
  channel = "stable"
  profile = "minimal"
  components = ["rustfmt", "clippy"]
  targets = ["aarch64-linux-android", "aarch64-apple-ios", "wasm32-unknown-unknown"]
  ```

  Manually: `rustup target add aarch64-linux-android`. Check what exists with `rustup target list --installed`.
- Pure-Rust crates usually cross-*check* trivially: `cargo check --target <triple>`. Linking needs a linker and a sysroot for the target, and that is where the tools below come in.

## Cross-compilation tools

| Need | Tool |
|---|---|
| Linux targets (aarch64, armv7, musl) from Linux | `cross` (Docker/Podman images per target: `cross build --target aarch64-unknown-linux-gnu`) or `cargo-zigbuild` (zig as linker, also good for glibc-version targeting: `cargo zigbuild --target x86_64-unknown-linux-gnu.2.28`) |
| Static Linux binaries | `x86_64-unknown-linux-musl` (via `cross`, zigbuild or Nix `pkgsStatic`) |
| Windows MSVC from Linux | `clang-cl` + `lld-link` against the Windows SDK/CRT fetched by `xwin` (the approach sismo uses in `nix/windows.nix`, pinned as a fixed-output derivation); alternatively `cargo-xwin` |
| macOS | build on macOS runners. Cross-linking from Linux is fragile and against Apple's SDK license terms in many setups |
| Android | NDK toolchain; see the next section |
| Reproducible cross builds | Nix (`pkgsCross.*`, crane), see `references/nix.md` |

## Android

Android Rust code usually builds as a `cdylib` loaded by a Kotlin/Java app, or through a framework that owns the Gradle side.

- **The build toolchain is the user's choice — never impose one.** First look at what the project already uses (justfile, CI workflow, Gradle files, decision log) and follow it. If nothing is set up yet, ask instead of picking. Common, equally valid options:

  | Option | What it is |
  |---|---|
  | Local SDK + NDK | `rustup target add aarch64-linux-android …` plus the NDK linker configured in `.cargo/config.toml` |
  | `cargo-ndk` | sets NDK linker/env per ABI: `cargo ndk -t arm64-v8a build --release` |
  | Gradle Rust plugin | Gradle drives cargo as part of the app build |
  | Container image | a pinned image with Rust + SDK + NDK (e.g. `sergioribera/rust-android`) for reproducible CI |
  | Framework-owned | the framework (istmo, cargo-mobile2, Dioxus, Tauri mobile…) owns the Gradle side |
  | Nix | an Android SDK/NDK from nixpkgs in the devShell |

  A project's decision log may reject some of these (istmo, for example, owns its own build integration); respect it and don't re-propose rejected tooling.
- **Native APIs from Rust** (sign-in, biometrics, camera, file picker, share): consider **istmo**. It gives a typed plugin contract with generated Kotlin/Swift glue instead of hand-written JNI. See `references/ecosystem.md`; it is early alpha.
- Logging goes to logcat via `android_logger` with the `log` facade, or a tracing layer that targets logcat.
- Never assume a writable CWD or a `$HOME`. Get app directories from the platform (via JNI or the framework).

## iOS

- Targets: `aarch64-apple-ios` (devices), `aarch64-apple-ios-sim` (Apple-silicon simulator). Build `staticlib`, then wrap it in an XCFramework for Xcode/SPM.
- Bridge to Swift through one narrow FFI boundary: a C ABI with `#[unsafe(no_mangle)] pub extern "C"`, `cbindgen` for headers, or a generator (UniFFI, swift-bridge, or istmo for app plugins).
- Builds require macOS runners in CI.

## WebAssembly

- `wasm32-unknown-unknown` has no filesystem, threads (without atomics + `-Zbuild-std` on nightly), or `std::time::Instant` (use `web-time`). Code that assumes these must be cfg-gated or abstracted.
- Check the library builds for wasm in CI: `cargo check --workspace --lib --target wasm32-unknown-unknown`.
- Ban unavailable APIs at lint level with a wasm-specific clippy config, the way egui keeps `scripts/clippy_wasm/clippy.toml` with `disallowed-methods` for `std::thread::spawn`, `Instant::now`, and so on:

  ```toml
  # clippy_wasm/clippy.toml (used via CLIPPY_CONF_DIR in the wasm CI job)
  disallowed-methods = [
    { path = "std::time::Instant::now", reason = "not available on wasm32; use web_time::Instant" },
    { path = "std::thread::spawn", reason = "no threads on wasm32-unknown-unknown" },
  ]
  ```

- `wasm-bindgen` / `trunk` / `wasm-pack` for browser apps. Test with `wasm-bindgen-test`.

## Portable-code rules

- Paths: `PathBuf`/`Path` and `join`, never string concatenation with `/`. Use the `directories`/`dirs` crates for config/cache/data locations.
- Text: don't assume `\n` line endings when parsing user files. Pin `newline_style = "Unix"` in rustfmt and use `.gitattributes` for repo files.
- Never assume a case-sensitive filesystem, `/tmp`, or POSIX permissions. Gate Unix-only APIs (`std::os::unix`) behind `#[cfg(unix)]` inside the platform layer.
- Integer widths: `usize` differs on 32-bit targets (wasm32, armv7, i686). Serialize explicit widths (`u64`), never `usize`.
- Endianness: use `to_le_bytes`/`from_le_bytes` explicitly for binary formats.

## CI matrix

Build or check every supported tier on every PR; run tests where they can execute. Build tests where they can't run (`cargo test --no-run --target …`).

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - { os: ubuntu-24.04,   target: x86_64-unknown-linux-gnu, test: true }
      - { os: windows-latest, target: x86_64-pc-windows-msvc,  test: true }
      - { os: macos-latest,   target: aarch64-apple-darwin,    test: true }
      - { os: ubuntu-24.04,   target: aarch64-linux-android,   test: false }
      - { os: macos-latest,   target: aarch64-apple-ios,       test: false }
      - { os: ubuntu-24.04,   target: wasm32-unknown-unknown,  test: false }
```

- With `test: false`, run `cargo check --workspace --all-targets --target ${{ matrix.target }}` (or `clippy` with `-D warnings`).
- Lint per target, not just on Linux: clippy only sees `#[cfg]` code that is compiled for the current target.
- Feature/backend combinations per platform (X11-only, Wayland-only) as extra matrix rows, as winit does.
- Full workflow conventions: `references/ci-cd.md`.

## Bundling and shipping

- Desktop installers (deb, rpm, AppImage, dmg, pkg, msi, NSIS) from a Nix build: **nix-bundle-app**. Without Nix: `cargo-dist` or `cargo-packager`. See `references/ecosystem.md` and `references/release.md`.
- Mobile packages (APK/AAB, IPA) come from the Gradle/Xcode side, e.g. the istmo template's release workflows or the Android container image.
