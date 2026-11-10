# CI hardening (GitHub Actions)

> Read when: writing any workflow that runs on pull requests, uses secrets, publishes artifacts or crates, or after a supply-chain incident; reviewing third-party actions.

CI runners execute code from every pull request and every dependency's `build.rs` and proc-macros. 2026 incidents — the `arrayref` supply-chain attack (https://blog.rust-lang.org/2026/08/20/supply-chain-attack-on-arrayref/) and targeted attacks on crate maintainers (https://blog.rust-lang.org/2026/09/17/targeted-attacks/) — show that CI is the softest target of a Rust project. Defaults below are cheap; apply them to every repo.

## Least privilege

```yaml
permissions:
  contents: read          # workflow default — read-only token

jobs:
  release:
    permissions:
      contents: write     # widen only in the job that creates the release
      id-token: write     # only if using OIDC (e.g. attestations / trusted publishing)
```

- Top-level `permissions: contents: read` on **every** workflow (freya does this). Without it, the token may have write access depending on repo settings.
- Widen per job, never at the top level.
- Separate workflows for untrusted (PR) and privileged (release, deploy) work.

## Pin actions

```yaml
- uses: actions/checkout@<40-char-sha> # v7.0.1
- uses: Swatinem/rust-cache@<40-char-sha> # v2.9.3
```

- Pin third-party actions to a **full commit SHA** with a `# vX.Y.Z` comment (freya pins every action this way). Tags are mutable; a compromised tag runs in your CI with your secrets.
- Let Dependabot (`package-ecosystem: github-actions`) or Renovate bump the SHAs; the comment keeps reviews readable.
- `dtolnay/rust-toolchain` has no releases — its ref is the toolchain. To pin, use `uses: dtolnay/rust-toolchain@<sha>` with `with: { toolchain: stable }`.
- Avoid unmaintained actions (`actions-rs/*`, `rustsec/audit-check` is stale since 2024 — prefer `cargo-deny-action` or installing `cargo-audit`).

## Checkout and credentials

```yaml
- uses: actions/checkout@<sha> # v7
  with:
    persist-credentials: false
```

- `persist-credentials: false` stops the token from being written to `.git/config`, where any later step (or a malicious build script) could read it. Only a job that pushes needs it.

## Untrusted input

- **Never use `pull_request_target`** for jobs that check out and build PR code — it runs with secrets and a write token on attacker-controlled code. Use `pull_request`.
- **No `${{ }}` interpolation of attacker-controlled data inside `run:`** (PR titles, branch names, issue bodies, `github.head_ref`). It is shell injection. Pass through `env:`:

  ```yaml
  - env:
      PR_TITLE: ${{ github.event.pull_request.title }}
    run: echo "$PR_TITLE"
  ```

- `workflow_run` and `issue_comment` triggers inherit the same risks; gate on author association if used.

## Secrets

- Scope secrets to the **step** that needs them (`env:` on the step), never workflow-level `env`.
- Fork PRs do not receive secrets — design caches and pushes to degrade gracefully (example: sismo's `setup-nix` action logs in to the binary cache only when the token is non-empty; reads still work through the public key).
- Use environments with required reviewers for publishing secrets (`CARGO_REGISTRY_TOKEN`, signing keys, store credentials).
- Rotate on any suspected compromise; a build that compiled a malicious crate version could read every secret in its environment.

## Caches

- Caches are a trust boundary. PR builds should read but not write shared caches: `Swatinem/rust-cache` with `save-if: ${{ github.ref == 'refs/heads/main' }}`.
- **Never cache jobs that run untrusted code alongside secrets**, and never let such a job write a cache that privileged jobs restore. This includes Miri jobs: run them uncached and with no secrets in their environment.
- Release builds: build from a clean state or a cache written only by `main` — with `Swatinem/rust-cache`, set `save-if: false` in release jobs so they never write.

## Static analysis of workflows

Run [zizmor](https://github.com/zizmorcore/zizmor) (v1.32.0 as of 2026-11) on `.github/workflows`:

```yaml
zizmor:
  runs-on: ubuntu-latest
  permissions: { contents: read }
  steps:
    - uses: actions/checkout@<sha> # v7
      with: { persist-credentials: false }
    - uses: zizmorcore/zizmor-action@<sha> # v0.8.1
      with:
        # true uploads SARIF to code scanning and needs `security-events: write`.
        advanced-security: false
```

zizmor flags template injection, unpinned actions, excessive permissions, `persist-credentials`, dangerous triggers and cache poisoning. `zizmorcore/zizmor-action` is the official action; `pipx run zizmor .github/workflows` works locally.

## Build-time code

- `cargo deny` with `[bans.build]` allowlists (`allow-build-scripts`) restricts which dependencies may run build scripts (`supply-chain.md`).
- `--locked` everywhere so CI never resolves a new (possibly malicious) version on its own.
- Review new dependencies with build scripts or proc-macros with extra care.

## Publishing

- Publish from a dedicated, manually approved or tag-triggered job, with the token scoped to that job's environment.
- Prefer short-lived credentials (OIDC). **crates.io trusted publishing**: configure the trusted publisher (repo + workflow file) in the crate's crates.io settings (https://crates.io/docs/trusted-publishing), then exchange the job's OIDC token for a temporary crates.io token, which the action revokes when the job ends — no long-lived `CARGO_REGISTRY_TOKEN` secret:

  ```yaml
  publish:
    runs-on: ubuntu-latest
    environment: release
    permissions:
      contents: read
      id-token: write        # required for the OIDC exchange
    steps:
      - uses: actions/checkout@<sha> # v7
        with: { persist-credentials: false }
      - uses: dtolnay/rust-toolchain@stable
      - uses: rust-lang/crates-io-auth-action@<sha> # v1.0.6
        id: auth
      - run: cargo publish --locked
        env:
          CARGO_REGISTRY_TOKEN: ${{ steps.auth.outputs.token }}
  ```
- Attach checksums (`SHA256SUMS`) to release artifacts; nix-bundle-app's `release` and cargo-dist generate them (`release.md`).

## Anti-patterns

- Workflows with no `permissions` block.
- `@v2`/`@main` tags on third-party actions in privileged workflows.
- `pull_request_target` + `actions/checkout` of the PR head.
- `run: echo "${{ github.event.pull_request.title }}"`.
- Secrets in workflow-level `env`.
- One workflow doing PR checks and releases.
- Caches written by PR runs and read by release runs.

## Checklist

- [ ] `permissions: contents: read` at top level of every workflow.
- [ ] Third-party actions pinned to SHA with version comment; Dependabot/Renovate for `github-actions`.
- [ ] `persist-credentials: false` on checkout (except pushing jobs).
- [ ] No `pull_request_target`; no `${{ }}` of untrusted data in `run:`.
- [ ] Secrets step-scoped; publishing behind an environment.
- [ ] Cache writes only from `main`; release jobs `save-if: false`; Miri and other untrusted-code jobs uncached.
- [ ] zizmor in CI.

Related: `ci-cd.md`, `supply-chain.md`, `release.md`, `../templates/ci.yml`, `../templates/release.yml`.
