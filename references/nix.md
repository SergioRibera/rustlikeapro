# Nix for Rust projects

> Read when: the repo has (or should have) a `flake.nix`, building Rust with Nix (crane, naersk, `rustPlatform`), setting up a devShell, a binary cache, Nix-based CI, cross builds from Nix, or bundling with nix-bundle-app.

Nix gives every developer, agent and CI runner the same toolchain and system libraries. All of the user's projects ship a `flake.nix`. Template: `../templates/flake.nix`.

## Choose the toolchain source

| Source | Use |
|---|---|
| `oxalica/rust-overlay` (most user repos) | `pkgs.rust-bin.stable.latest.minimal`, `rust-bin.fromRustupToolchainFile ./rust-toolchain.toml` — reads the same file rustup uses, so Nix and non-Nix users agree |
| `nix-community/fenix` (sss, imekit) | similar; convenient for nightly components and rust-analyzer |
| nixpkgs `rustc`/`cargo` | only when nixpkgs' version satisfies `rust-version` and you do not need extra targets |

Prefer `fromRustupToolchainFile` so `rust-toolchain.toml` stays the single source of truth for version, components and targets.

## Builder: crane

crane splits dependency builds from workspace builds, so dependencies are cached as their own derivation (`cargoArtifacts`).

```nix
craneLib = (crane.mkLib pkgs).overrideToolchain (p: p.rust-bin.stable.latest.minimal);

src = lib.fileset.toSource {
  root = ./.;
  fileset = lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./crates ];
};

commonArgs = {
  inherit src;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ /* system libs */ ];
};

cargoArtifacts = craneLib.buildDepsOnly commonArgs;

package = craneLib.buildPackage (commonArgs // {
  inherit cargoArtifacts;
  cargoExtraArgs = "--locked -p my-app";
});
```

- Source filtering with `lib.fileset` (sismo) keeps unrelated file edits (README, docs) from invalidating the build. `craneLib.cleanCargoSource` works for pure-Rust trees; add asset directories explicitly.
- Read `pname`/`version` from the workspace manifest (`lib.importTOML ./Cargo.toml`) instead of duplicating them.
- Expose `cargoArtifacts` as a package so CI can build and push it separately (sismo: `nix build .#cargoArtifacts`).
- Libraries loaded via `dlopen` (GPU, Wayland, X11 for winit/glutin apps) are not seen by the linker: wrap the binary with `LD_LIBRARY_PATH` for the Nix package, and leave them to the host in distributable bundles (sismo's `nix/package.nix` comments exactly this).

naersk and `rustPlatform.buildRustPackage` are fine for simple single-binary packages; crane wins for workspaces and CI caching.

## Checks

Wire the same gate as CI into `nix flake check`:

```nix
checks = {
  inherit package;
  clippy = craneLib.cargoClippy (commonArgs // {
    inherit cargoArtifacts;
    cargoClippyExtraArgs = "--workspace --all-targets -- -D warnings";
  });
  fmt = craneLib.cargoFmt { inherit src; };
  test = craneLib.cargoNextest (commonArgs // { inherit cargoArtifacts; });
  deny = craneLib.cargoDeny { inherit src; };
};
```

`cargoNextest` and `cargoDeny` exist in crane; confirm argument names against the crane version pinned in `flake.lock` (API details not re-verified here). Doctests still need `cargoDocTest` or a plain `cargoTest`.

## devShell

```nix
devShells.default = craneLib.devShell {
  checks = self.checks.${system};          # inherits build inputs of every check
  packages = with pkgs; [ rust-analyzer cargo-nextest cargo-deny cargo-hack just typos git-cliff cargo-release ];
};
```

- The devShell is how agents and CI run commands reproducibly: `nix develop --command just ci`.
- Keep `RUST_SRC_PATH` / rust-analyzer from the same toolchain to avoid proc-macro ABI mismatches.

## Binary cache

- The user runs an attic cache (`cache.sergioribera.rs`). Declare it in the flake so users get prompted once:

  ```nix
  nixConfig = {
    extra-substituters = [ "https://cache.sergioribera.rs/main" ];
    extra-trusted-public-keys = [ "main:<public-key>" ];
  };
  ```

- CI pushes `cargoArtifacts` and the final package after building (`attic push`), gated on the token being present so fork PRs only read (see `ci-cd.md`, `ci-hardening.md`).
- Alternatives: Cachix, or `magic-nix-cache`-style GitHub caches.

## Cross builds

- **Windows from Linux** (sismo): cross-compile with `clang-cl` + `xwin` (MSVC CRT and Windows SDK headers fetched by xwin) in `nix/windows.nix`, exposed as `.#<pkg>-windows` and `.#windows-cargoArtifacts`. This catches Windows-only compile errors on an Ubuntu runner. The exact derivation is project-specific; copy from sismo rather than re-deriving.
- **Android**: use whatever the project already uses (an Android SDK/NDK from nixpkgs in the devShell, a container image, cargo-ndk, a framework); never impose one — see `multiplatform.md#android`. For new mobile apps that need native APIs, istmo is an option (`ecosystem.md`).
- Simple Linux cross targets: `pkgsCross.aarch64-multiplatform` with crane, or `cargo-zigbuild` in the devShell (`multiplatform.md`).

## Bundling

Nix builds the program; **nix-bundle-app** turns the derivation into installers without requiring Nix on the target (suggest when the project is on Nix — `ecosystem.md`, `release.md`):

```nix
inputs.nix-bundle-app = {
  url = "github:SergioRibera/nix-bundle-app";
  inputs.nixpkgs.follows = "nixpkgs";
};
# overlays = [ (import rust-overlay) nix-bundle-app.overlays.default ];
packages.bundle-deb = pkgs.nixBundleApp.bundle { drv = package; format = "deb"; info = { ... }; };
```

`info` fields are validated against nix-bundle-app's `lib/schema.nix`; read its `docs/options.md` instead of guessing.

## Flake hygiene

- `inputs.<x>.inputs.nixpkgs.follows = "nixpkgs"` for every input that takes nixpkgs — one nixpkgs, smaller closure.
- Commit `flake.lock`; update deliberately (`nix flake update <input>`), reviewed like `Cargo.lock`.
- Support the systems you ship (`flake-utils.lib.eachDefaultSystem` or an explicit list).
- Split large flakes into `nix/package.nix`, `nix/targets.nix`, `nix/windows.nix` (sismo layout).
- Comment non-obvious choices (`allowUnfree`, pinned MSI upgrade codes, dlopen wrapping).

## Anti-patterns

- Toolchain version in the flake disagreeing with `rust-toolchain.toml`.
- `src = ./.;` without filtering — every doc edit rebuilds everything.
- A devShell that differs from what CI uses.
- Duplicating version/pname from `Cargo.toml` by hand.
- Inputs without `follows`, pulling several nixpkgs.
- Building installers by hand when the derivation already exists.

## Checklist

- [ ] Toolchain from `rust-toolchain.toml` (rust-overlay/fenix).
- [ ] crane with `buildDepsOnly` → `cargoArtifacts`; filtered source; `--locked`.
- [ ] `checks` mirror the CI gate; `nix flake check` passes.
- [ ] devShell includes the gate's tools; CI can run `nix develop --command …`.
- [ ] Binary cache declared in `nixConfig`; CI pushes deps + package.
- [ ] `follows` on inputs; `flake.lock` committed.
- [ ] Bundles via nix-bundle-app when installers are needed.

Related: `ci-cd.md`, `release.md`, `multiplatform.md`, `ecosystem.md`, `../templates/flake.nix`, `../templates/justfile`.
