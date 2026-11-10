#!/usr/bin/env bash
# rustlikeapro quality gate. Mirrors the CI lint/test/doc/deny/typos jobs; never modifies source files.
#
# Usage: scripts/check.sh [--quick] [--no-doc] [--msrv] [--features <list>] [path-to-crate-or-workspace]
#   --quick            fmt + clippy only
#   --no-doc           skip doc tests and rustdoc build
#   --msrv             also `cargo +<rust-version> check` (SKIP if that toolchain is not installed)
#   --features <list>  use `--features <list>` instead of `--all-features` everywhere
#                      (required for projects with mutually exclusive features)
#
# Not run here (CI-only): cargo-hack feature matrix, extra targets, the OS matrix.
# Each step reports PASS / FAIL / SKIP(reason). Exit code is non-zero if any step FAILs.
set -euo pipefail

quick=0
no_doc=0
msrv=0
feature_args=(--all-features)
root="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) quick=1 ;;
    --no-doc) no_doc=1 ;;
    --msrv) msrv=1 ;;
    --features)
      [[ $# -ge 2 ]] || { echo "--features needs a value" >&2; exit 2; }
      feature_args=(--features "$2")
      shift
      ;;
    --features=*) feature_args=(--features "${1#--features=}") ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) root="$1" ;;
  esac
  shift
done

cd "$root"
if [[ ! -f Cargo.toml ]]; then
  echo "no Cargo.toml in $(pwd)" >&2
  exit 2
fi

# Workspace vs single crate: --workspace is valid for both, but report it for clarity.
if grep -q '^\[workspace\]' Cargo.toml; then
  layout="workspace"
else
  layout="single crate"
fi

# The lockfile lives at the workspace root, which may be above a member we were pointed at.
workspace_manifest="$(cargo locate-project --workspace --message-format plain 2>/dev/null || echo Cargo.toml)"
workspace_dir="$(dirname "$workspace_manifest")"

# --locked only when a lockfile exists (policy: commit it; see references/maintenance.md).
locked=()
[[ -f "${workspace_dir}/Cargo.lock" ]] && locked=(--locked)

names=()
results=()
failed=0

record() {
  names+=("$1")
  results+=("$2")
}

run_step() {
  local name="$1"
  shift
  echo
  echo "==> $name: $*"
  if "$@"; then
    record "$name" "PASS"
  else
    record "$name" "FAIL"
    failed=1
  fi
}

skip_step() {
  record "$1" "SKIP ($2)"
}

has() { command -v "$1" >/dev/null 2>&1; }
has_cargo_sub() { cargo "$1" --version >/dev/null 2>&1; }

echo "rustlikeapro check — $(pwd) [$layout] [${feature_args[*]}]"
[[ ${#locked[@]} -eq 0 ]] && echo "note: no Cargo.lock at ${workspace_dir}; running without --locked"

run_step "fmt" cargo fmt --all --check
run_step "clippy" cargo clippy --workspace --all-targets "${feature_args[@]}" ${locked[@]+"${locked[@]}"} -- -D warnings

if (( quick )); then
  skip_step "tests" "--quick"
  skip_step "doc tests" "--quick"
  skip_step "rustdoc" "--quick"
  skip_step "cargo-deny" "--quick"
  skip_step "typos" "--quick"
else
  if has_cargo_sub nextest; then
    run_step "tests" cargo nextest run --workspace "${feature_args[@]}" ${locked[@]+"${locked[@]}"} --no-tests=pass
  else
    run_step "tests (cargo test)" cargo test --workspace "${feature_args[@]}" ${locked[@]+"${locked[@]}"}
  fi

  if (( no_doc )); then
    skip_step "doc tests" "--no-doc"
    skip_step "rustdoc" "--no-doc"
  else
    # Doc tests only exist for library targets; cargo errors on bin-only packages.
    if find . -path ./target -prune -o -name lib.rs -print -quit | grep -q .; then
      run_step "doc tests" cargo test --workspace --doc "${feature_args[@]}" ${locked[@]+"${locked[@]}"}
    else
      skip_step "doc tests" "no library targets"
    fi
    run_step "rustdoc" env RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps "${feature_args[@]}" \
      --document-private-items ${locked[@]+"${locked[@]}"}
  fi

  if [[ ! -f "${workspace_dir}/deny.toml" && ! -f "${workspace_dir}/.config/deny.toml" ]]; then
    skip_step "cargo-deny" "no deny.toml (templates/deny.toml)"
  elif ! has_cargo_sub deny; then
    skip_step "cargo-deny" "cargo-deny not installed"
  else
    run_step "cargo-deny" cargo deny --manifest-path "$workspace_manifest" check
  fi

  if has typos; then
    run_step "typos" typos
  else
    skip_step "typos" "typos not installed"
  fi
fi

if (( msrv )); then
  # The package's own manifest first, then the workspace root ([workspace.package]).
  rust_version="$(grep -h -m1 -E '^[[:space:]]*rust-version[[:space:]]*=[[:space:]]*"' Cargo.toml "$workspace_manifest" 2>/dev/null |
    head -n1 | sed -E 's/.*"(.*)".*/\1/' || true)"
  if [[ -z "$rust_version" ]]; then
    skip_step "msrv" "no rust-version in Cargo.toml or ${workspace_manifest}"
  elif ! rustup toolchain list 2>/dev/null | grep -qE "^${rust_version//./\\.}([.-]|$)"; then
    skip_step "msrv" "toolchain ${rust_version} not installed (rustup toolchain install ${rust_version})"
  else
    # `+toolchain` overrides rust-toolchain.toml, so this really builds with the MSRV.
    run_step "msrv ${rust_version}" cargo "+${rust_version}" check --workspace --all-targets ${locked[@]+"${locked[@]}"}
  fi
else
  skip_step "msrv" "pass --msrv (CI runs it)"
fi

echo
echo "Summary"
echo "-------"
for i in "${!names[@]}"; do
  printf '  %-20s %s\n' "${names[$i]}" "${results[$i]}"
done

if (( failed )); then
  echo
  echo "RESULT: FAIL"
  exit 1
fi
echo
echo "RESULT: PASS (skipped steps above were NOT verified; cargo-hack and the OS/target matrix are CI-only)"
