#!/usr/bin/env bash
# Documentation checks for the opsie chart.
# check_keys <values.yaml> <README>   every top-level value is documented
# check_links <README>                every relative link resolves
# check_secrets <values.yaml> <README> Secret names and keys of the extraObjects examples appear in the README
set -u

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$CHART/../.." && pwd)"
FAILURES=0

pass() { echo "ok   $1"; }
fail() { FAILURES=$((FAILURES + 1)); echo "FAIL $1${2:+: $2}"; }

check_keys() {
  local values="$1" readme="$2" key prev missing=""
  prev=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z][A-Za-z0-9]*): ]]; then
      key="${BASH_REMATCH[1]}"
      if ! grep -qF "\`$key\`" "$readme" && ! grep -qF "\`$key." "$readme" && [[ "$prev" != "# --"* ]]; then
        missing="$missing $key"
      fi
    fi
    prev="$line"
  done <"$values"
  [[ -z "$missing" ]] || { echo "undocumented top-level values:$missing"; return 1; }
}

check_links() {
  local readme="$1" dir target bad=0
  dir="$(dirname "$readme")"
  while IFS= read -r target; do
    case "$target" in http://*|https://*|mailto:*|\#*) continue ;; esac
    target="${target%%#*}"
    [[ -e "$dir/$target" ]] || { echo "broken link: $target"; bad=1; }
  done < <(grep -oE '\]\([^)]+\)' "$readme" | sed -E 's/^\]\((.*)\)$/\1/')
  return $bad
}

check_secrets() {
  local values="$1" readme="$2" bad=0 item
  while IFS= read -r item; do
    grep -qF "\`$item\`" "$readme" || { echo "not in README: $item"; bad=1; }
  done < <(awk '
    /^  #     name: / { s = $0; sub(/^  #     name: /, "", s); sub(/ .*/, "", s); print s; next }
    /^  #   stringData:/ { in_data = 1; next }
    /^  # - / { in_data = 0 }
    in_data && /^  #     [a-z-]+:/ { s = $0; sub(/^  #     /, "", s); sub(/:.*/, "", s); print s }
  ' "$values" | sort -u)
  return $bad
}

run() {
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then pass "$desc"; else fail "$desc" "$out"; fi
}

expect_failure() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc" "expected a failure"; else pass "$desc"; fi
}

VALUES="$CHART/values.yaml"
CHART_README="$CHART/README.md"
ROOT_README="$ROOT/README.md"

run "docs-values-documented" check_keys "$VALUES" "$CHART_README"
run "docs-links-chart-readme" check_links "$CHART_README"
run "docs-links-root-readme" check_links "$ROOT_README"
run "docs-secrets-match-values" check_secrets "$VALUES" "$CHART_README"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$VALUES" "$TMP/values.yaml"
printf '\nundocumentedKey: true\n' >>"$TMP/values.yaml"
expect_failure "docs-negative-undocumented-key" check_keys "$TMP/values.yaml" "$CHART_README"

printf 'See [missing](does-not-exist.md).\n' >"$TMP/README.md"
expect_failure "docs-negative-broken-link" check_links "$TMP/README.md"

printf 'nothing here\n' >"$TMP/README.md"
expect_failure "docs-negative-secret-not-documented" check_secrets "$VALUES" "$TMP/README.md"

[[ $FAILURES -eq 0 ]]
