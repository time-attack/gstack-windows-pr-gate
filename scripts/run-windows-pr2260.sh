#!/usr/bin/env bash
set -euo pipefail

root_input="${1:?isolated root required}"
harness_input="${2:?harness root required}"
root="$(cygpath -u "$root_input")"
harness="$(cygpath -u "$harness_input")"
export PATH="$harness/tools:$PATH"

case "$root" in
  /c/gstack-isolated/pr-2260/*) ;;
  *) echo "Refusing non-isolated root: $root" >&2; exit 90 ;;
esac

evidence="$root/evidence"
mkdir -p "$evidence"
command -v sha256sum >/dev/null
command -v shasum >/dev/null

git config --global user.email "windows-gate@gstack.test"
git config --global user.name "GStack Windows Gate"
git config --global init.defaultBranch main

fetch_checkout() {
  local label="$1"
  local expected="$2"
  local dest="$root/$label/source"
  local fetch_ref="$expected"
  if [ "$label" = candidate ]; then fetch_ref='refs/pull/2260/head'; fi

  mkdir -p "$dest"
  git -C "$dest" init --quiet
  git -C "$dest" remote add upstream https://github.com/garrytan/gstack.git
  git -C "$dest" fetch --quiet --no-tags --depth=1 upstream "$fetch_ref"
  local actual
  actual="$(git -C "$dest" rev-parse FETCH_HEAD)"
  if [ "$actual" != "$expected" ]; then
    echo "$label SHA mismatch: expected $expected, got $actual" >&2
    exit 93
  fi
  git -C "$dest" checkout --quiet --detach "$actual"
  printf '%s commit=%s tree=%s\n' \
    "$label" "$actual" "$(git -C "$dest" rev-parse HEAD^{tree})" | tee -a "$evidence/source-integrity.log"
}

install_dependencies() {
  local label="$1"
  local repo="$root/$label/source"
  local home="$root/$label/home"
  mkdir -p "$home"
  (
    export HOME="$home"
    export GSTACK_SKIP_COREUTILS=1
    export GSTACK_SKIP_FONTS=1
    export GSTACK_SKIP_GBRAIN_REGEN=1
    cd "$repo"
    bun install --frozen-lockfile
  ) 2>&1 | tee "$evidence/$label-install.log"
}

install_playwright_browser() {
  local repo="$root/candidate/source"
  local home="$root/candidate/home"
  mkdir -p "$root/playwright-browsers"
  (
    export HOME="$home"
    export PLAYWRIGHT_BROWSERS_PATH="$root/playwright-browsers"
    cd "$repo"
    bunx playwright install chromium
  ) 2>&1 | tee "$evidence/playwright-install.log"
}

run_probe() {
  local label="$1"
  local repo="$root/$label/source"
  local home="$root/$label/home"
  local output="$evidence/$label-primary.log"
  mkdir -p "$evidence/$label-runtime"

  set +e
  (
    export HOME="$home"
    export GSTACK_SKIP_COREUTILS=1
    export GSTACK_SKIP_FONTS=1
    export GSTACK_SKIP_GBRAIN_REGEN=1
    export PLAYWRIGHT_BROWSERS_PATH="$root/playwright-browsers"
    export GSTACK_UNDER_TEST="$repo"
    export PR2260_FIXTURE_ROOT="$harness/probes"
    export PR2260_EVIDENCE_DIR="$evidence/$label-runtime"
    bash "$harness/probes/windows-build-runtime.sh"
  ) 2>&1 | tee "$output"
  local rc="${PIPESTATUS[0]}"
  set -e
  printf '%s primary_rc=%s\n' "$label" "$rc" | tee -a "$evidence/verdict.log"
  return "$rc"
}

echo "RUNNER_OS=${RUNNER_OS:-unknown}"
echo "RUNNER_ARCH=${RUNNER_ARCH:-unknown}"
echo "ImageOS=${ImageOS:-unknown}"
echo "ImageVersion=${ImageVersion:-unknown}"
printf 'probe_sha256=' | tee "$evidence/probe-integrity.log"
shasum -a 256 "$harness/probes/windows-build-runtime.sh" | tee -a "$evidence/probe-integrity.log"

fetch_checkout baseline "$BASE_SHA"
fetch_checkout candidate "$CANDIDATE_SHA"
install_dependencies baseline
install_dependencies candidate
install_playwright_browser

baseline_rc=0
run_probe baseline || baseline_rc=$?
if [ "$baseline_rc" -eq 0 ]; then
  echo "INCONCLUSIVE: immutable main unexpectedly passed the defect probe" | tee -a "$evidence/verdict.log"
  exit 80
fi
if ! grep -q 'PRIMARY_PROBE_FAIL' "$evidence/baseline-primary.log"; then
  echo "INCONCLUSIVE: baseline failed outside the expected primary boundary" | tee -a "$evidence/verdict.log"
  exit 81
fi
echo "BASELINE_REPRODUCED" | tee -a "$evidence/verdict.log"

candidate_rc=0
run_probe candidate || candidate_rc=$?
if [ "$candidate_rc" -ne 0 ] || ! grep -q 'PRIMARY_PROBE_PASS' "$evidence/candidate-primary.log"; then
  echo "CANDIDATE_PRIMARY_FAILED rc=$candidate_rc" | tee -a "$evidence/verdict.log"
  exit 82
fi
echo "CANDIDATE_PRIMARY_PASSED" | tee -a "$evidence/verdict.log"

set +e
(
  export HOME="$root/candidate/home"
  export GSTACK_SKIP_COREUTILS=1
  export GSTACK_SKIP_FONTS=1
  export GSTACK_SKIP_GBRAIN_REGEN=1
  cd "$root/candidate/source"
  bun test browse/test/build.test.ts browse/test/config.test.ts
  bun run test:windows
) 2>&1 | tee "$evidence/candidate-secondary.log"
secondary_rc="${PIPESTATUS[0]}"
set -e
if [ "$secondary_rc" -ne 0 ]; then
  echo "CANDIDATE_SECONDARY_FAILED rc=$secondary_rc" | tee -a "$evidence/verdict.log"
  exit 83
fi
echo "CANDIDATE_SECONDARY_PASSED" | tee -a "$evidence/verdict.log"

RESULT_PATH="$evidence/result.json" node - <<'NODE'
const fs = require('fs');
const result = {
  schemaVersion: 1,
  pr: 2260,
  baseSha: process.env.BASE_SHA,
  headSha: process.env.CANDIDATE_SHA,
  runnerOS: process.env.RUNNER_OS,
  runnerArch: process.env.RUNNER_ARCH,
  imageOS: process.env.ImageOS,
  imageVersion: process.env.ImageVersion,
  baseline: 'reproduced',
  candidatePrimary: 'passed',
  candidateSecondary: 'passed',
  verdict: 'passed'
};
fs.writeFileSync(process.env.RESULT_PATH, JSON.stringify(result, null, 2) + '\n');
NODE

echo "FINAL_VERDICT=PASS" | tee -a "$evidence/verdict.log"
