#!/usr/bin/env bash
# rustlikeapro quality gate. Mirrors CI; never modifies source files.
#
# Usage: scripts/check.sh [--quick] [--no-doc] [path-to-crate-or-workspace]
#   --quick   fmt + clippy only
#   --no-doc  skip doc tests and rustdoc build
#
# Each step reports PASS / FAIL / SKIP(reason). Exit code is non-zero if any step FAILs.
set -euo pipefail

quick=0
no_doc=0
root="."
for arg in "$@"; do
  case "$arg" in
    --quick) quick=1 ;;
    --no-doc) no_doc=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) root="$arg" ;;
  esac
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

# --locked only when a lockfile exists (libraries may not commit one).
locked=()
[[ -f Cargo.lock ]] && locked=(--locked)

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

echo "rustlikeapro check — $(pwd) [$layout]"

run_step "fmt" cargo fmt --all --check
run_step "clippy" cargo clippy --workspace --all-targets --all-features "${locked[@]}" -- -D warnings

if (( quick )); then
  skip_step "tests" "--quick"
  skip_step "doc tests" "--quick"
  skip_step "rustdoc" "--quick"
  skip_step "cargo-deny" "--quick"
  skip_step "typos" "--quick"
else
  if has_cargo_sub nextest; then
    run_step "tests" cargo nextest run --workspace --all-features "${locked[@]}" --no-tests=pass
  else
    run_step "tests (cargo test)" cargo test --workspace --all-features "${locked[@]}"
  fi

  if (( no_doc )); then
    skip_step "doc tests" "--no-doc"
    skip_step "rustdoc" "--no-doc"
  else
    # Doc tests only exist for library targets; cargo errors on bin-only packages.
    if find . -path ./target -prune -o -name lib.rs -print -quit | grep -q .; then
      run_step "doc tests" cargo test --workspace --doc --all-features "${locked[@]}"
    else
      skip_step "doc tests" "no library targets"
    fi
    run_step "rustdoc" env RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps --all-features "${locked[@]}"
  fi

  if [[ ! -f deny.toml && ! -f .config/deny.toml ]]; then
    skip_step "cargo-deny" "no deny.toml (templates/deny.toml)"
  elif ! has_cargo_sub deny; then
    skip_step "cargo-deny" "cargo-deny not installed"
  else
    run_step "cargo-deny" cargo deny check
  fi

  if has typos; then
    run_step "typos" typos
  else
    skip_step "typos" "typos not installed"
  fi
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
echo "RESULT: PASS (skipped steps above were NOT verified)"
