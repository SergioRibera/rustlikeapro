#!/usr/bin/env bash
# rustlikeapro repo audit. Read-only: reports missing hygiene and the template that fixes it.
#
# Usage: scripts/audit.sh [path-to-repo]
# Exit code: 0 always (it is a report, not a gate). Findings are tagged OK / WARN / MISS.
set -euo pipefail

tpl="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" && pwd)"
root="${1:-.}"
cd "$root"

if [[ ! -f Cargo.toml ]]; then
  echo "no Cargo.toml in $(pwd)" >&2
  exit 2
fi

ok=0 warn=0 miss=0
ok()   { printf '  OK    %s\n' "$1"; ok=$((ok + 1)); }
warn() { printf '  WARN  %s\n        fix: %s\n' "$1" "$2"; warn=$((warn + 1)); }
miss() { printf '  MISS  %s\n        fix: %s\n' "$1" "$2"; miss=$((miss + 1)); }

# All Rust sources outside target/ and vendored dirs.
rs_files() { find . \( -path ./target -o -path ./vendor -o -path '*/node_modules' -o -path './.git' \) -prune -o -name '*.rs' -print; }
# NUL-separated variant for xargs -0 (paths with spaces); `rs_grep` runs grep over all sources.
rs_files0() { find . \( -path ./target -o -path ./vendor -o -path '*/node_modules' -o -path './.git' \) -prune -o -name '*.rs' -print0; }
rs_grep() { rs_files0 | xargs -0 grep "$@" /dev/null 2>/dev/null || true; }
manifests() { find . \( -path ./target -o -path ./vendor -o -path './.git' \) -prune -o -name Cargo.toml -print; }

echo "rustlikeapro audit — $(pwd)"
echo
echo "Toolchain & manifest"

if [[ -f rust-toolchain.toml ]]; then ok "rust-toolchain.toml present"
elif [[ -f rust-toolchain ]]; then warn "legacy rust-toolchain file" "$tpl/rust-toolchain.toml"
else miss "no rust-toolchain.toml" "$tpl/rust-toolchain.toml"; fi

if grep -Eq '^[[:space:]]*rust-version[[:space:]]*=' Cargo.toml; then ok "rust-version declared"
else miss "no rust-version (MSRV) in root Cargo.toml" "$tpl/Cargo.workspace.toml [workspace.package]"; fi

if grep -Eq '^[[:space:]]*edition[[:space:]]*=[[:space:]]*"2024"' Cargo.toml; then ok "edition 2024"
elif grep -Eq '^[[:space:]]*edition[[:space:]]*=' Cargo.toml; then warn "edition older than 2024 (upgrade deliberately: cargo fix --edition)" "$tpl/Cargo.workspace.toml"
else warn "no edition in root manifest (fine for virtual workspace if members set it)" "$tpl/Cargo.workspace.toml"; fi

if grep -q '^\[workspace\]' Cargo.toml; then
  if grep -Eq '^[[:space:]]*resolver[[:space:]]*=[[:space:]]*"3"' Cargo.toml; then ok "resolver = \"3\""
  else warn "workspace without resolver = \"3\" (MSRV-aware resolution)" "$tpl/Cargo.workspace.toml"; fi
fi

if grep -Eq '^\[(workspace\.)?lints' Cargo.toml; then ok "[lints] table in root manifest"
else miss "no [workspace.lints]/[lints] table — lints only enforced by CLI flags, if at all" "$tpl/Cargo.workspace.toml"; fi

if grep -Eq '^[[:space:]]*pedantic[[:space:]]*=' Cargo.toml; then ok "clippy::pedantic enabled"
else miss "clippy::pedantic not enabled in manifest" "$tpl/Cargo.workspace.toml [workspace.lints.clippy]"; fi

if grep -Eq '^[[:space:]]*unwrap_used[[:space:]]*=' Cargo.toml; then ok "clippy::unwrap_used configured"
else warn "clippy::unwrap_used not enabled (no-unwrap rule is not enforced)" "$tpl/Cargo.workspace.toml"; fi

if grep -Eq '^[[:space:]]*undocumented_unsafe_blocks[[:space:]]*=' Cargo.toml; then ok "undocumented_unsafe_blocks configured"
else warn "undocumented_unsafe_blocks not enabled" "$tpl/Cargo.workspace.toml"; fi

if grep -q '^\[workspace\]' Cargo.toml; then
  members=0 inheriting=0
  while IFS= read -r m; do
    [[ "$m" == "./Cargo.toml" ]] && continue
    grep -q '^\[package\]' "$m" || continue
    members=$((members + 1))
    # `workspace = true` must sit under the [lints] table (dependency entries use it too).
    if awk '
      /^\[/ { in_lints = ($0 ~ /^\[lints\][[:space:]]*(#.*)?$/) }
      in_lints && /^[[:space:]]*workspace[[:space:]]*=[[:space:]]*true/ { found = 1 }
      END { exit !found }
    ' "$m" || grep -Eq '^[[:space:]]*lints\.workspace[[:space:]]*=[[:space:]]*true' "$m"; then
      inheriting=$((inheriting + 1))
    fi
  done < <(manifests)
  if (( members > 0 )); then
    if (( inheriting == members )); then ok "all $members members inherit workspace lints"
    else warn "$inheriting/$members members have [lints] workspace = true" "add '[lints] workspace = true' to each member"; fi
  fi
fi

echo
echo "Config files"
if [[ -f clippy.toml || -f .clippy.toml ]]; then ok "clippy.toml present"
else warn "no clippy.toml (allow-unwrap-in-tests, disallowed-*)" "$tpl/clippy.toml"; fi
if [[ -f rustfmt.toml || -f .rustfmt.toml ]]; then
  if grep -Eq 'edition[[:space:]]*=[[:space:]]*"20(15|18|21)"' rustfmt.toml .rustfmt.toml 2>/dev/null; then warn "rustfmt.toml edition older than manifest?" "$tpl/rustfmt.toml"
  else ok "rustfmt.toml present"; fi
else warn "no rustfmt.toml" "$tpl/rustfmt.toml"; fi
if [[ -f deny.toml || -f .config/deny.toml ]]; then ok "deny.toml present"
else miss "no deny.toml (licenses, advisories, sources)" "$tpl/deny.toml"; fi
if [[ -f typos.toml || -f _typos.toml || -f .typos.toml ]]; then ok "typos config present"
else warn "no typos.toml" "$tpl/typos.toml"; fi
if [[ -f AGENTS.md ]]; then ok "AGENTS.md present"
elif [[ -f CLAUDE.md ]]; then warn "CLAUDE.md only — other agents won't read it (move to AGENTS.md, CLAUDE.md = '@AGENTS.md')" "$tpl/AGENTS.md"
else miss "no AGENTS.md / CLAUDE.md (rules + decision log)" "$tpl/AGENTS.md"; fi

# Policy: commit Cargo.lock in every project, libraries included (references/maintenance.md).
if [[ -f Cargo.lock ]]; then ok "Cargo.lock present"
else miss "no committed Cargo.lock" "commit Cargo.lock; use --locked in CI"; fi

# Dependency requirement style: major.minor ("1.4", "0.8"). Flags major-only ("1")
# and patch-pinned ("1.4.2") requirements inside *dependencies tables; 0.0.x is exempt.
req_report="$(manifests | while read -r m; do
  awk -v file="$m" '
    /^\[/ { in_deps = ($0 ~ /dependencies/) }
    in_deps && /^[A-Za-z0-9_-]+[[:space:]]*=/ {
      line = $0
      if (line ~ /path[[:space:]]*=/) next  # internal crates carry their exact version
      if (match(line, /version[[:space:]]*=[[:space:]]*"[^"]*"/)) req = substr(line, RSTART, RLENGTH)
      else if (match(line, /=[[:space:]]*"[^"]*"/)) req = substr(line, RSTART, RLENGTH)
      else next
      match(req, /"[^"]*"/); req = substr(req, RSTART + 1, RLENGTH - 2); sub(/^[~^]/, "", req)
      if (req ~ /^0\.0\./) next
      if (req ~ /^[0-9]+$/) print "major-only " file ": " line
      else if (req ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print "patch-pinned " file ": " line
    }
  ' "$m"
done)"
major_only="$(grep -c '^major-only' <<<"$req_report" || true)"
patch_pinned="$(grep -c '^patch-pinned' <<<"$req_report" || true)"
if [[ "$major_only" -eq 0 && "$patch_pinned" -eq 0 ]]; then
  ok "dependency requirements use major.minor"
else
  warn "dependency requirements: ${major_only} major-only, ${patch_pinned} patch-pinned (policy: major.minor)" \
    "scripts/add-dep.sh / references/maintenance.md#adding-dependencies"
  head -n 5 <<<"$req_report" | sed 's/^/        /'
fi

echo
echo "CI"
wf_dir=".github/workflows"
if [[ -d "$wf_dir" ]] && ls "$wf_dir"/*.y*ml >/dev/null 2>&1; then
  ok "GitHub workflows present"
  if grep -lq 'actions-rs/' "$wf_dir"/*.y*ml; then warn "deprecated actions-rs/* used: $(grep -l 'actions-rs/' "$wf_dir"/*.y*ml | xargs -n1 basename | tr '\n' ' ')" "$tpl/ci.yml (dtolnay/rust-toolchain)"; fi
  no_perms="$(grep -L '^permissions:' "$wf_dir"/*.y*ml || true)"
  if [[ -n "$no_perms" ]]; then
    warn "workflows without top-level permissions: $(echo "$no_perms" | xargs -n1 basename | tr '\n' ' ')" "$tpl/ci.yml (permissions: contents: read)"
  else ok "all workflows declare top-level permissions"; fi
  if grep -q -- '-D warnings' "$wf_dir"/*.y*ml; then ok "CI denies warnings"
  else warn "CI never uses -D warnings" "$tpl/ci.yml"; fi
  if grep -Eq 'cargo[- ]deny' "$wf_dir"/*.y*ml; then ok "cargo-deny in CI"; else warn "cargo-deny not in CI" "$tpl/ci.yml (deny job)"; fi
  if grep -Eq 'msrv|rust-version' "$wf_dir"/*.y*ml; then ok "MSRV job present"; else warn "no MSRV job" "$tpl/ci.yml (msrv job)"; fi
elif [[ -f .gitlab-ci.yml || -d .forgejo/workflows || -d .woodpecker ]]; then
  ok "non-GitHub CI present (not inspected)"
else
  miss "no CI workflows" "$tpl/ci.yml"
fi

echo
echo "Code"
total_rs=$(rs_files | wc -l)
mod_rs=$(rs_files | grep -c '/mod\.rs$' || true)
if (( mod_rs == 0 )); then ok "no mod.rs files ($total_rs .rs files)"
else warn "$mod_rs mod.rs files (prefer foo.rs + foo/)" "move foo/mod.rs to foo.rs"; fi

# "Bare" = #[allow(..)] without `reason = ".."` (single-line heuristic). A reasoned #[allow]
# is legitimate when the lint fires conditionally (cfg/target/feature/macro).
allow_lines="$(rs_grep -hE '#!?\[allow\(')"
allow_count=$(grep -c . <<<"$allow_lines" || true)
bare_allow=$(grep -vc 'reason' <<<"$allow_lines" || true)
[[ -z "$allow_lines" ]] && bare_allow=0
expect_count=$(rs_grep -hoE '#!?\[expect\(' | wc -l)
if (( bare_allow == 0 )); then ok "no bare #[allow(..)] ($allow_count with reason, $expect_count #[expect(..)])"
else warn "$bare_allow bare #[allow(..)] (no reason), $((allow_count - bare_allow)) with reason, $expect_count #[expect(..)] — use #[expect(lint, reason = \"..\")]; #[allow(.., reason)] only for conditional lints" "SKILL.md §1"; fi

# Rough count: unwrap() in files that are not tests/examples/benches/build scripts.
unwrap_count=$(find . \( -path ./target -o -path ./vendor -o -path './.git' -o -path '*/tests' -o -path '*/examples' -o -path '*/benches' \) -prune \
  -o -name '*.rs' ! -name build.rs ! -name '*_test.rs' ! -name tests.rs -print0 |
  xargs -0 grep -hE '\.unwrap\(\)' /dev/null 2>/dev/null | wc -l)
if (( unwrap_count == 0 )); then ok "no .unwrap() outside tests/examples (rough)"
else warn "~$unwrap_count .unwrap() lines outside tests/examples (includes #[cfg(test)] modules; rough)" "SKILL.md §3 Panics"; fi

unsafe_count=$(rs_grep -hE '(^|[^A-Za-z0-9_])unsafe[[:space:]]*\{' | wc -l)
safety_count=$(rs_grep -hE '//[[:space:]]*SAFETY:' | wc -l)
if (( unsafe_count > 0 )); then
  if (( safety_count >= unsafe_count )); then ok "$unsafe_count unsafe blocks, $safety_count SAFETY comments"
  else warn "$unsafe_count unsafe blocks but only $safety_count SAFETY comments" "references/unsafe-ffi.md"; fi
fi

echo
echo "Summary: $ok OK, $warn WARN, $miss MISS"
