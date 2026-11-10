#!/usr/bin/env bash
# Keep the skill's own templates and version mentions current.
#
# Run from anywhere; it operates on the skill directory it lives in.
#
#   refresh.sh            report only (read-only)
#   refresh.sh --write    also fix what can be fixed mechanically: action major tags,
#                         stale version mentions (precision kept), verified-against
#                         (only when the clippy probe passes) and metadata.version patch
#
# Checks:
#   1. toolchain   installed rustc vs `metadata.verified-against` in SKILL.md
#   2. clippy      every lint in templates/Cargo.workspace.toml and clippy.toml is known
#                  to the installed clippy (unknown / renamed / removed lints are flagged)
#   3. cargo-deny  templates/deny.toml parses with the installed cargo-deny (schema drift)
#   4. actions     `uses: owner/repo@vN` in templates/*.yml vs latest GitHub release
#   5. versions    crate/tool versions mentioned in SKILL.md, references/, templates/
#                  vs latest stable on crates.io (compared at major.minor)
#
# Network: crates.io API and api.github.com (set GITHUB_TOKEN to avoid rate limits).
# Exit code: 0 = everything current, 1 = drift found, 2 = usage error.

set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "needs bash >= 4 (macOS: brew install bash)" >&2; exit 2; }

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
templates="${skill_dir}/templates"
write=false
[[ "${1:-}" == "--write" ]] && write=true
[[ -n "${1:-}" && "${1:-}" != "--write" ]] && { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

drift=0
changed=false   # --write touched a file
clippy_ok=false
deny_line=""
# crates.io asks API clients to identify themselves; set CRATES_IO_USER_AGENT to include contact info.
ua="${CRATES_IO_USER_AGENT:-rustlikeapro-refresh}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

section() { printf '\n== %s ==\n' "$1"; }
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  DRIFT %s\n' "$1"; drift=1; }
skip() { printf '  skip  %s\n' "$1"; }
indent() { while IFS= read -r l; do printf "        %s\n" "$l"; done; }

need() { command -v "$1" >/dev/null || { skip "$2 ($1 not installed)"; return 1; }; }

crate_latest() {
  curl -fsS -A "$ua" "https://crates.io/api/v1/crates/$1" 2>/dev/null |
    jq -r '.crate.max_stable_version // empty' 2>/dev/null || true
}

# Compatibility line: 1.4.2 -> 1.4 is too fine for 1.x, so compare major.minor;
# for 0.x the minor is the breaking boundary, so major.minor is right there too.
line_of() { awk -F. '{ print $1 "." $2 }' <<<"$1"; }

# ---------------------------------------------------------------- 1. toolchain
section "toolchain"
if need rustc "toolchain check"; then
  installed="$(rustc --version | awk '{ print $2 }')"
  declared="$(sed -n 's/.*verified-against: "rust \([0-9.]*\).*/\1/p' "${skill_dir}/SKILL.md")"
  if [[ "$(line_of "$installed")" == "$(line_of "${declared:-0.0}")" ]]; then
    ok "rustc ${installed} matches verified-against ${declared}"
  else
    printf '  info  rustc %s installed, SKILL.md verified against %s\n' "$installed" "${declared:-?}"
    latest="$(curl -fsS https://static.rust-lang.org/dist/channel-rust-stable.toml 2>/dev/null |
      awk '/^\[pkg.rustc\]/ { f = 1 } f && /^version/ { gsub(/"/, "", $3); print $3; exit }')" || true
    [[ -n "${latest:-}" ]] && printf '  info  latest stable rustc: %s\n' "$latest"
    if [[ -n "${latest:-}" && "$(line_of "$latest")" != "$(line_of "${declared:-0.0}")" ]]; then
      bad "SKILL.md verified-against is behind stable ${latest}: re-verify and bump metadata"
    fi
  fi
fi

# ---------------------------------------------------------------- 2. clippy lints
section "clippy lints"
if need cargo "clippy check" && [[ -f "${templates}/Cargo.workspace.toml" ]]; then
  probe="${scratch}/lint-probe"
  mkdir -p "${probe}/src"
  printf 'pub fn probe() {}\n' >"${probe}/src/lib.rs"
  {
    printf '[package]\nname = "lint-probe"\nversion = "0.0.0"\nedition = "2024"\npublish = false\n\n'
    # Re-home [workspace.lints.*] tables as package-level [lints.*] tables.
    awk '
      /^\[/ { keep = ($0 ~ /^\[workspace\.lints\./) }
      keep { sub(/^\[workspace\.lints\./, "[lints."); print }
    ' "${templates}/Cargo.workspace.toml"
  } >"${probe}/Cargo.toml"
  [[ -f "${templates}/clippy.toml" ]] && cp "${templates}/clippy.toml" "${probe}/clippy.toml"
  if out="$(cd "$probe" && cargo clippy --quiet 2>&1)"; then :; fi
  problems="$(grep -E "unknown lint|has been renamed|has been removed|unknown field|error: (failed|error reading)" <<<"$out" | sort -u || true)"
  if [[ -n "$problems" ]]; then
    while IFS= read -r line; do bad "$line"; done <<<"$problems"
  elif grep -q '^error' <<<"$out"; then
    bad "clippy probe failed:"
    head -20 <<<"$out" | indent
  else
    clippy_ok=true
    ok "all template lints known to $(cargo clippy --version 2>/dev/null || echo clippy)"
  fi
else
  skip "templates/Cargo.workspace.toml missing"
fi

# ---------------------------------------------------------------- 3. cargo-deny schema
section "cargo-deny schema"
if [[ -f "${templates}/deny.toml" ]] && cargo deny --version >/dev/null 2>&1; then
  probe="${scratch}/deny-probe"
  mkdir -p "${probe}/src"
  printf 'pub fn probe() {}\n' >"${probe}/src/lib.rs"
  printf '[package]\nname = "deny-probe"\nversion = "0.0.0"\nedition = "2024"\nlicense = "MIT"\npublish = false\n' >"${probe}/Cargo.toml"
  (cd "$probe" && cargo generate-lockfile --quiet 2>/dev/null) || true
  # `check bans` loads and validates the whole config without fetching the advisory DB.
  if out="$(cargo deny --manifest-path "${probe}/Cargo.toml" check --config "${templates}/deny.toml" bans 2>&1)"; then
    deny_line="$(line_of "$(cargo deny --version | awk '{ print $2 }')")"
    ok "deny.toml accepted by $(cargo deny --version)"
  else
    bad "deny.toml rejected by $(cargo deny --version):"
    head -20 <<<"$out" | indent
  fi
else
  skip "cargo-deny not installed (cargo install --locked cargo-deny) or deny.toml missing"
fi

# ---------------------------------------------------------------- 4. GitHub Actions
section "github actions"
if need curl "actions check" && need jq "actions check"; then
  auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  mapfile -t uses < <(grep -rhoE 'uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@v[0-9][0-9.]*' "${templates}"/*.yml 2>/dev/null |
    sed -E 's/uses: *//' | sort -u)
  for ref in "${uses[@]}"; do
    repo="${ref%@*}"
    current="${ref#*@}"
    latest="$(curl -fsS ${auth[@]+"${auth[@]}"} "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
      jq -r '.tag_name // empty')" || true
    if [[ -z "$latest" ]]; then
      skip "${repo}: no release info (rate limit? set GITHUB_TOKEN)"
      continue
    fi
    cur_major="${current%%.*}"
    new_major="${latest%%.*}"
    if [[ "$cur_major" == "$new_major" ]]; then
      ok "${repo}@${current} (latest ${latest})"
    else
      bad "${repo}@${current} -> latest ${latest}"
      if $write; then
        # Match the whole tag (`@v2` must not match inside `@v2.1`): next char is not [0-9.] or EOL.
        ref_re="$(sed 's/[][\.*^$#/]/\\&/g' <<<"${repo}@${current}")"
        while IFS= read -r yml; do
          sed -i "s#${ref_re}\\([^0-9.]\\|\$\\)#${repo}@${new_major}\\1#g" "$yml"
        done < <(grep -rlF "${repo}@${current}" "${templates}"/*.yml)
        changed=true
        printf '        rewritten to %s@%s (review the changelog for breaking inputs)\n' "$repo" "$new_major"
      fi
    fi
  done
  [[ ${#uses[@]} -eq 0 ]] && skip "no tag-pinned actions found in templates/*.yml"
fi

# ---------------------------------------------------------------- 5. version mentions
section "version mentions (crates & cargo tools)"
tracked=(
  thiserror anyhow miette color-eyre snafu
  tokio tokio-util futures flume crossbeam-channel rayon parking_lot
  tracing tracing-subscriber clap serde serde_json postcard
  proptest insta rstest criterion divan
  cargo-nextest cargo-deny cargo-audit cargo-vet cargo-semver-checks
  release-plz cargo-dist cargo-hack cargo-machete cargo-udeps cargo-llvm-cov cargo-mutants
  typos-cli
)
if need curl "version check" && need jq "version check"; then
  stale=0
  files=("${skill_dir}/SKILL.md" "${skill_dir}"/references/*.md "${skill_dir}"/references/*/*.md "${templates}"/*)
  for name in "${tracked[@]}"; do
    # Matches "thiserror 2", "thiserror 2.0.21", "thiserror = \"2.0\"", "thiserror@2.0".
    mapfile -t hits < <(grep -HnoE "(^|[^A-Za-z0-9_-])${name}( |@| = \"|=\")v?[0-9]+(\.[0-9]+){1,2}" "${files[@]}" 2>/dev/null || true)
    [[ ${#hits[@]} -eq 0 ]] && continue
    # crates.io asks API clients for at most one request per second.
    sleep 1
    latest="$(crate_latest "$name")"
    if [[ -z "$latest" ]]; then
      skip "${name}: crates.io lookup failed (rate limit? offline?)"
      continue
    fi
    for hit in "${hits[@]}"; do
      file="${hit%%:*}"
      rest="${hit#*:}"
      lineno="${rest%%:*}"
      match="${rest#*:}"
      mentioned="$(grep -oE '[0-9]+(\.[0-9]+){1,2}$' <<<"$match")"
      [[ "$mentioned" != *.* ]] && continue
      [[ "$(line_of "$mentioned")" == "$(line_of "$latest")" ]] && continue
      # Historical mentions ("removed in cargo-deny 0.16") opt out with `refresh:keep` on the line.
      sed -n "${lineno}p" "$file" | grep -q 'refresh:keep' && continue
      bad "${file#"${skill_dir}/"}:${lineno} ${name} ${mentioned} -> latest ${latest}"
      stale=1
      if $write; then
        # Keep the mention's precision: "2.0" stays major.minor, "2.0.21" stays full.
        if [[ "$mentioned" == *.*.* ]]; then new_version="$latest"; else new_version="$(line_of "$latest")"; fi
        old="${match#[^A-Za-z0-9]}"
        new="${old%"$mentioned"}${new_version}"
        old_re="$(sed 's/[][\.*^$|/]/\\&/g' <<<"$old")"
        sed -i "${lineno}s/${old_re}/${new//\//\\/}/" "$file"
        changed=true
        printf '        rewritten to %s\n' "$new"
      fi
    done
  done
  [[ $stale -eq 0 ]] && ok "no stale version mentions"
fi

# ---------------------------------------------------------------- 6. metadata (--write)
if $write; then
  section "metadata"
  skill_md="${skill_dir}/SKILL.md"
  declared_line="$(line_of "${declared:-0.0}")"
  installed_line="$(line_of "${installed:-0.0}")"
  if $clippy_ok && [[ -n "${installed:-}" && "$installed_line" != "$declared_line" ]] &&
    [[ "$(printf '%s\n%s\n' "$declared_line" "$installed_line" | sort -V | tail -n1)" == "$installed_line" ]]; then
    # Only move forward: an older local toolchain must never downgrade the stamp.
    current_deny="$(sed -n 's/.*verified-against: ".*cargo-deny \([0-9.]*\).*/\1/p' "$skill_md")"
    stamp="rust ${installed_line}, clippy ${installed_line}, cargo-deny ${deny_line:-${current_deny:-?}}, edition 2024 ($(date -u +%Y-%m))"
    sed -i "s|^\(  verified-against: \)\".*\"|\1\"${stamp}\"|" "$skill_md"
    changed=true
    printf '  bumped verified-against: %s\n' "$stamp"
  fi
  if $changed; then
    version="$(sed -n 's/^  version: "\([0-9.]*\)"/\1/p' "$skill_md")"
    IFS=. read -r v_major v_minor v_patch <<<"$version"
    next="${v_major}.${v_minor}.$((v_patch + 1))"
    sed -i "s|^  version: \"${version}\"|  version: \"${next}\"|" "$skill_md"
    printf '  bumped metadata.version: %s -> %s\n' "$version" "$next"
  else
    printf '  nothing rewritten\n'
  fi
fi

section "result"
if [[ $drift -eq 0 ]]; then
  echo "  everything current"
else
  echo "  drift found: update the flagged files, re-run, then bump metadata.verified-against in SKILL.md"
fi
exit "$drift"
