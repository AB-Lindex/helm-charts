#!/usr/bin/env bash
# Scaffold and schema cases for the opsie chart. Run from anywhere; needs helm and tar.
# expect_fail <description> <expected-substring> <helm template args...>
# expect_ok   <description> <helm template args...>
set -u

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$CHART/ci/all-in-one-values.yaml"
KUBE_VERSION="1.32.0"
FAILURES=0
CASES=0

pass() { CASES=$((CASES + 1)); echo "ok   $1"; }
fail() { CASES=$((CASES + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL $1${2:+: $2}"; }

render() { helm template opsie "$CHART" --kube-version "$KUBE_VERSION" "$@"; }

expect_fail() {
  local desc="$1" substr="$2"; shift 2
  local err
  if err="$(render "$@" 2>&1 >/dev/null)"; then
    fail "$desc" "rendered without error"
  elif [[ "$err" == *"$substr"* ]]; then
    pass "$desc"
  else
    fail "$desc" "error does not contain '$substr': $err"
  fi
}

expect_ok() {
  local desc="$1"; shift
  local err
  if err="$(render "$@" 2>&1 >/dev/null)"; then pass "$desc"; else fail "$desc" "$err"; fi
}

# --- self-test: a case that is expected to fail but succeeds must be counted as a failure
before=$FAILURES
expect_fail "selftest-expect-fail-detects-success" "anything" -f "$FIXTURE" >/dev/null
if [[ $FAILURES -eq $((before + 1)) ]]; then
  FAILURES=$before
  CASES=$((CASES - 1))
  pass "scaffold-selftest-expect-fail-detects-success"
else
  fail "scaffold-selftest-expect-fail-detects-success" "expect_fail did not report a succeeding render"
fi

# --- scaffold
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

helm repo add valkey https://valkey.io/valkey-helm/ >/dev/null 2>&1

cp "$CHART/Chart.lock" "$TMP/Chart.lock.orig"
if helm dependency build "$CHART" >/dev/null 2>&1 && cmp -s "$CHART/Chart.lock" "$TMP/Chart.lock.orig"; then
  pass "scaffold-dependency-build-keeps-lock"
else
  fail "scaffold-dependency-build-keeps-lock"
fi

if helm lint "$CHART" --kube-version "$KUBE_VERSION" -f "$FIXTURE" >/dev/null 2>&1; then
  pass "scaffold-lint-all-in-one"
else
  fail "scaffold-lint-all-in-one"
fi

VERSION="$(sed -n 's/^version: *//p' "$CHART/Chart.yaml")"
if (cd "$TMP" && helm package "$CHART" >/dev/null 2>&1) && [[ -f "$TMP/opsie-$VERSION.tgz" ]]; then
  listing="$(tar tzf "$TMP/opsie-$VERSION.tgz")"
  # helm package unpacks the dependency: charts/valkey/ rather than the .tgz
  if grep -q '^opsie/charts/valkey/Chart.yaml$' <<<"$listing" \
     && ! grep -q '^opsie/tests/' <<<"$listing" && ! grep -q '^opsie/ci/' <<<"$listing"; then
    pass "scaffold-package-contents"
  else
    fail "scaffold-package-contents" "unexpected package listing"
  fi
else
  fail "scaffold-package-contents" "helm package failed"
fi

cp -r "$CHART" "$TMP/chart-copy"
sed -i 's/^    version: 0.12.0/    version: 0.11.0/' "$TMP/chart-copy/Chart.yaml"
if helm dependency build "$TMP/chart-copy" >/dev/null 2>&1; then
  fail "scaffold-lock-out-of-sync-fails" "dependency build succeeded with a stale Chart.lock"
else
  pass "scaffold-lock-out-of-sync-fails"
fi

REPO_ROOT="$(cd "$CHART/../.." && pwd)"
if command -v actionlint >/dev/null 2>&1; then
  if (cd "$REPO_ROOT" && actionlint .github/workflows/*.yml); then pass "scaffold-actionlint"; else fail "scaffold-actionlint"; fi
else
  echo "skip scaffold-actionlint (actionlint not installed; CI runs it)"
fi

# --- schema
expect_fail "schema-topology-bad" "topology" -f "$FIXTURE" --set topology=bad
expect_fail "schema-database-type-memory" "database/type" -f "$FIXTURE" --set database.type=memory
expect_fail "schema-tls-mode-bad" "tls/mode" -f "$FIXTURE" --set tls.mode=bad
expect_fail "schema-migrate-mode-bad" "database/migrate/mode" -f "$FIXTURE" --set database.migrate.mode=bad
expect_fail "schema-pdb-enabled-maybe" "podDisruptionBudget/enabled" -f "$FIXTURE" --set podDisruptionBudget.enabled=maybe
expect_fail "schema-replica-count-negative" "replicaCount" -f "$FIXTURE" --set parts.app.replicaCount=-1
expect_fail "schema-ingress-without-name" "name" -f "$FIXTURE" --set 'ingresses[0].hosts[0].host=a.example'
expect_fail "schema-httproute-without-parentrefs" "parentRefs" -f "$FIXTURE" --set 'httpRoutes[0].name=a'
expect_ok "schema-pdb-enabled-true" -f "$FIXTURE" --set podDisruptionBudget.enabled=true
expect_ok "schema-pdb-enabled-false" -f "$FIXTURE" --set podDisruptionBudget.enabled=false
expect_ok "schema-valkey-passthrough" -f "$FIXTURE" --set valkey.dataStorage.enabled=true

# --- collected validation messages as seen from the command line
expect_fail "validate-header-singular" "opsie: 1 configuration problem:" -f "$FIXTURE" --set database.existingSecret=
expect_fail "validate-header-plural" "opsie: 2 configuration problems:" -f "$FIXTURE" --set database.existingSecret= --set valkey.enabled=false

expect_fail "extraobjects-invalid-yaml-after-tpl" "yaml" -f "$FIXTURE" -f "$CHART/tests/values/invalid-extraobject.yaml"

# --- never rendered, in any topology
for t in all-in-one split-ingest split-all; do
  out="$(render -f "$CHART/ci/$t-values.yaml" --set tls.mode=proxy 2>&1)"
  if grep -Eq 'DEVMODE|ENABLE_MOCK_DATA|JWT_ISSUER|sqlserver://' <<<"$out"; then
    fail "env-no-dev-settings-$t" "development setting or literal connection string rendered"
  else
    pass "env-no-dev-settings-$t"
  fi
done

echo "$CASES cases, $FAILURES failed"
[[ $FAILURES -eq 0 ]]
