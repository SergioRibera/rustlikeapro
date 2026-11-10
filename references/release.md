# Releases, versioning and distribution

> Read when: bumping versions, writing changelogs, tagging, publishing to crates.io, building release artifacts or installers, or choosing release tooling.

## Versioning

- SemVer as Cargo interprets it: before 1.0, a **minor** bump (`0.3 → 0.4`) is breaking, patch is compatible.
- What is breaking for a library: removing/renaming public items, adding a field to a public struct without `#[non_exhaustive]`, adding an enum variant to a non-`#[non_exhaustive]` enum, tightening trait bounds, raising MSRV (treat as minor at least, and say so in the changelog), removing a feature, changing default features. Details: `api-design.md`.
- Verify with **cargo-semver-checks** (0.51.0) before every library release:

  ```bash
  cargo semver-checks --workspace
  ```

  In CI: `obi1kenobi/cargo-semver-checks-action@v2` on PRs for published crates.
- Workspaces either share one version (`shared-version = true`; example: sismo, istmo) or version crates independently (release-plz default). Shared is simpler for tightly coupled crates.

## Commits and changelog

- Conventional Commits, **single line** (`feat: …`, `fix: …`, `perf: …`, `refactor: …`, `docs: …`, `ci: …`, `build: …`, `chore: …`); `!` or `BREAKING CHANGE` marks breaking changes. The changelog is generated from these.
- `CHANGELOG.md` with an `## Unreleased` section; group by user-visible impact. For breaking changes, show old vs new (smithay style):

  ````markdown
  ### Breaking changes

  `Seat::add_keyboard` now takes a `XkbConfig` by reference:

  ```diff
  -seat.add_keyboard(config, 200, 25)?;
  +seat.add_keyboard(&config, 200, 25)?;
  ```
  ````

- Example: sismo's `cliff.toml` lists only `feat`/`fix`/`perf` in release notes and skips the rest — users read notes, contributors read history.

## Tooling options

| Tool | Model | Fits |
|---|---|---|
| **cargo-release + git-cliff** (examples: sismo, simplemoji) | Local `cargo release <level>` bumps versions (workspace shared), rewrites intra-workspace deps, commits `chore(release): X`, tags `vX`; the tag triggers the release workflow; git-cliff writes notes | Apps and workspaces you release by hand; publishing kept manual or in the tag workflow |
| **release-plz** (0.4.3, action `release-plz/action@v0.5`) | Bot opens a release PR with bumps + changelog (git-cliff based); merging publishes to crates.io and tags | Published libraries with frequent releases (youtui) |
| **letmerelease** | Manual `workflow_dispatch`, dry run, then publishes crates in dependency order, tags, `gh release create --generate-notes` | Large multi-crate workspaces (freya) |
| **cargo publish --workspace** (Cargo 1.90+) | Publishes all members in dependency order in one command | Simple workspaces, scripted releases |

Example `release.toml` (sismo) for reference:

```toml
publish = false              # crates.io publishing stays manual, in dependency order
verify = false
shared-version = true
consolidate-commits = true
allow-branch = ["main"]
pre-release-commit-message = "chore(release): {{version}}"
tag-name = "v{{version}}"
dependent-version = "upgrade"
```

Template for release-plz: `../templates/release-plz.toml`.

## Tag-triggered release workflow

Template: `../templates/release.yml`.

```yaml
on:
  push:
    tags: ["v*"]
permissions: { contents: read }
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: ubuntu-latest, target: x86_64-unknown-linux-gnu }
          - { os: macos-latest, target: aarch64-apple-darwin }
          - { os: windows-latest, target: x86_64-pc-windows-msvc }
    # build --release --locked --target ..., upload artifact
  publish:
    needs: build
    permissions: { contents: write }
    # download artifacts, generate SHA256SUMS, gh release create "$GITHUB_REF_NAME" --notes-file NOTES.md
```

- Build with `--locked`, from a clean or main-only cache (`ci-hardening.md`).
- Generate notes with git-cliff (`git cliff --latest --strip header`) or `gh release create --generate-notes`.
- Attach checksums; sign where the platform expects it.
- niri uses `softprops/action-gh-release@v2`; `gh release create` avoids a third-party action.

## Distribution of binaries

Pick by build system:

- **Nix projects → nix-bundle-app** (suggest, don't impose; see `ecosystem.md`). From the Nix derivation it produces deb, rpm, Arch/AUR, AppImage, Flatpak/Snap source layouts, brew, tarballs/zip, macOS app/dmg/pkg, Windows NSIS/MSI, plus `bundler.release { info; matrix; releaseUrl; installScripts = true; }` for a flat upload directory with `install.sh`/`install.ps1` and `SHA256SUMS`. Signing runs afterwards via `./result/sign.sh`. sismo's flake uses it for native + Windows bundles.
- **Non-Nix projects → dist (cargo-dist 0.34)**: config in `dist-workspace.toml` / `[workspace.metadata.dist]`, generates its own release workflow, installers (shell, PowerShell, MSI, Homebrew) and checksums. Examples: simplemoji, worship-screens. Config details from memory — run `dist init` and read what it writes.
- **cargo-packager / tauri-bundler**: GUI app bundles without Nix.
- **AUR**: publish PKGBUILDs from CI on release (examples: sss, simplemoji).
- **Mobile**: Play Store / App Store workflows come from the istmo template (`ecosystem.md`).

## Publishing crates

- `cargo publish --dry-run -p <crate>` (or `--workspace`) in CI before the real publish.
- Path-only deps cannot be published — every intra-workspace dep needs `version`. `[patch]` does not block publishing, but it is root-only and **not applied for downstream users**: a crate that only builds with the patch is broken for everyone else, so wait for the upstream release.
- Fill `description`, `license`, `repository`, `readme`, `keywords`, `categories`, `rust-version`; `[package.metadata.docs.rs]` for features/targets (`api-design.md`).
- Exclude junk: `exclude = ["demo-traces/", "assets/raw/"]` or `include` whitelist; check with `cargo package --list`.
- Yanking is for broken releases, not for undoing a publish of secrets — rotate secrets instead.

## Pre-release checklist

- [ ] CI green on the release commit (including MSRV, deny, semver-checks for libraries).
- [ ] Version bumped consistently (shared or per crate); intra-workspace deps updated.
- [ ] CHANGELOG `Unreleased` → version + date; breaking changes have diff blocks.
- [ ] MSRV change called out explicitly.
- [ ] `cargo publish --dry-run` / `cargo package --list` clean.
- [ ] Tag `vX.Y.Z` (or `<crate>-vX.Y.Z` for independent versions — `{{ package }}-v{{ version }}` in `../templates/release-plz.toml`) created by tooling, not by hand-edited files.
- [ ] Artifacts built with `--locked`, checksums attached, notes generated.
- [ ] Post-release: perf baseline recorded (sismo) for the next regression comparison, if the app is instrumented.

## Anti-patterns

- Hand-editing versions in many `Cargo.toml` files.
- Releasing from a dirty or non-main branch (`allow-branch = ["main"]`).
- Changelog written from memory instead of commits.
- Breaking changes in a patch release; MSRV bumps hidden in patch releases.
- Publishing from a developer laptop with a long-lived token when CI could do it.
- Multi-line commit bodies replacing a proper changelog.

Related: `api-design.md`, `ci-cd.md`, `ci-hardening.md`, `nix.md`, `ecosystem.md`, `../templates/release.yml`, `../templates/release-plz.toml`.
