#!/usr/bin/env bash
# Add a dependency at its latest stable version with a `major.minor` requirement.
#
# Policy (see references/maintenance.md#adding-dependencies):
#   - Never hand-write a version from memory: resolve the latest stable release.
#   - Declare `major.minor` (e.g. "1.4", "0.8"): Cargo's caret semantics keep the
#     compatible range open, so `cargo update` picks up new patches; the lockfile
#     pins the exact version.
#   - In a workspace, the version lives once in `[workspace.dependencies]` and the
#     member gets `dep = { workspace = true }` (cargo add does this automatically
#     once the workspace entry exists).
#
# Usage:
#   add-dep.sh <crate> [cargo add args...]      e.g. add-dep.sh tokio -p app-core --features rt,macros
#   add-dep.sh --dry-run <crate> [...]          print what would happen
#
# Extra args (`-p/--package`, `--features`, `--dev`, `--build`, `--optional`,
# `--no-default-features`, `--target`) are forwarded to `cargo add`.

set -euo pipefail

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
  shift
fi

if [[ $# -lt 1 || "$1" == -* ]]; then
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

crate="$1"
shift
forward=("$@")

run() {
  if $dry_run; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

latest_version() {
  local name="$1" version=""
  if command -v curl >/dev/null && command -v jq >/dev/null; then
    version="$(curl -fsS -A "${CRATES_IO_USER_AGENT:-rustlikeapro-add-dep}" \
      "https://crates.io/api/v1/crates/${name}" 2>/dev/null | jq -r '.crate.max_stable_version // empty')" || true
  fi
  if [[ -z "$version" ]]; then
    # `cargo info` (stable since Rust 1.82) prints "version: X.Y.Z"; inside a project that
    # already locks the crate it prints "version: X.Y.Z (latest A.B.C)", so prefer "latest".
    version="$(cargo info "$name" 2>/dev/null | awk '
      /^version:/ { v = $2; if ($3 == "(latest") { v = $4; sub(/\)$/, "", v) } print v; exit }
    ')" || true
  fi
  printf '%s' "$version"
}

# 1.4.2 -> 1.4 | 0.8.3 -> 0.8 | 0.0.7 -> 0.0.7 (every 0.0.x release is breaking)
requirement_for() {
  local major minor patch
  IFS=. read -r major minor patch <<<"${1%%[-+]*}"
  if [[ "$major" == "0" && "$minor" == "0" ]]; then
    printf '0.0.%s' "$patch"
  else
    printf '%s.%s' "$major" "$minor"
  fi
}

version="$(latest_version "$crate")"
if [[ -z "$version" ]]; then
  echo "error: could not resolve a stable version for '${crate}' (typo? offline? prerelease-only?)" >&2
  exit 1
fi
req="$(requirement_for "$version")"
echo "${crate}: latest stable ${version} -> requirement \"${req}\""

metadata="$(cargo metadata --no-deps --format-version 1 2>/dev/null)" || metadata=""

# Warn when the newest release needs a newer compiler than the project's MSRV:
# the requirement floor would then be unsatisfiable on the declared rust-version.
# Lowest declared rust-version across members; sort -V because "1.100" > "1.85" (a string min is wrong).
project_msrv="$(jq -r '.packages[].rust_version // empty' <<<"${metadata:-{\}}" 2>/dev/null | sort -V | head -n1)" || true
crate_msrv="$(cargo info "${crate}@${version}" 2>/dev/null | awk '/^rust-version:/ { print $2; exit }')" || true
if [[ -n "$project_msrv" && -n "$crate_msrv" ]] &&
  [[ "$(printf '%s\n%s\n' "$crate_msrv" "$project_msrv" | sort -V | tail -n1)" != "$project_msrv" ]]; then
  echo "warning: ${crate} ${version} requires rust ${crate_msrv}, project MSRV is ${project_msrv}." >&2
  echo "         pick an older line explicitly (cargo add ${crate}@<major.minor>) or raise rust-version deliberately." >&2
fi

workspace_root="$(jq -r '.workspace_root // empty' <<<"${metadata:-{\}}" 2>/dev/null)" || true
root_manifest="${workspace_root:+${workspace_root}/Cargo.toml}"

has_workspace_deps=false
if [[ -n "$root_manifest" && -f "$root_manifest" ]] && grep -q '^\[workspace\.dependencies\]' "$root_manifest"; then
  has_workspace_deps=true
fi

if ! $has_workspace_deps; then
  run cargo add "${crate}@${req}" ${forward[@]+"${forward[@]}"}
  exit 0
fi

# Workspace flow: ensure the workspace entry, then add the member reference.
in_workspace_table="$(awk -v name="$crate" '
  /^\[/ { in_table = ($0 ~ /^\[workspace\.dependencies\][[:space:]]*(#.*)?$/) }
  in_table && $0 ~ "^" name "[[:space:]]*=" { found = 1 }
  END { print found ? "yes" : "no" }
' "$root_manifest")"

if [[ "$in_workspace_table" == "yes" ]]; then
  echo "${crate} already in [workspace.dependencies]; keeping its requirement."
else
  echo "adding ${crate} = \"${req}\" to [workspace.dependencies] in ${root_manifest}"
  if ! $dry_run; then
    tmp="$(mktemp)"
    awk -v line="${crate} = \"${req}\"" '
      { print }
      $0 ~ /^\[workspace\.dependencies\][[:space:]]*(#.*)?$/ { print line }
    ' "$root_manifest" >"$tmp"
    mv "$tmp" "$root_manifest"
  fi
fi

package_given=false
for arg in ${forward[@]+"${forward[@]}"}; do
  [[ "$arg" == "-p" || "$arg" == "--package" || "$arg" == --package=* ]] && package_given=true
done

if $package_given; then
  # cargo add detects the workspace entry and writes `{ workspace = true }`.
  run cargo add "$crate" ${forward[@]+"${forward[@]}"}
else
  echo "no -p/--package given: entry added to the workspace only."
  echo "next: cargo add ${crate} -p <member> [--features ...]"
fi
