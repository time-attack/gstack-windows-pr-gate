#!/usr/bin/env bash
set -euo pipefail

root="${1:?isolated root required}"
case "$root" in
  /tmp/gstack-isolated/pr-2260/*) ;;
  *) echo "Refusing non-isolated root: $root" >&2; exit 90 ;;
esac

evidence="$root/evidence"
mkdir -p "$evidence"
git config --global user.email "linux-control@gstack.test"
git config --global user.name "GStack Linux Control"
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
  test "$actual" = "$expected"
  git -C "$dest" checkout --quiet --detach "$actual"
  printf '%s commit=%s tree=%s\n' \
    "$label" "$actual" "$(git -C "$dest" rev-parse HEAD^{tree})" | tee -a "$evidence/source-integrity.log"
}

run_control() {
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
    mkdir -p browse/dist
    MSYS_NO_PATHCONV=1 bash browse/scripts/build-node-server.sh
    MSYS_NO_PATHCONV=1 bash browse/scripts/build-node-server.sh
    test -s browse/dist/server-node.mjs
    test "$(grep -Fxc '// ── Windows Node.js compatibility (auto-generated) ──' browse/dist/server-node.mjs || true)" = 1
    test ! -e browse/dist/server-node.raw.mjs
    test ! -e browse/dist/server-node.tmp.mjs
    node --check browse/dist/server-node.mjs
    bun run build
    node --check browse/dist/server-node.mjs
  ) 2>&1 | tee "$evidence/$label-control.log"
}

fetch_checkout baseline "$BASE_SHA"
fetch_checkout candidate "$CANDIDATE_SHA"
run_control baseline
run_control candidate

(
  export HOME="$root/candidate/home"
  cd "$root/candidate/source"
  bun test
) 2>&1 | tee "$evidence/candidate-free-suite.log"

RESULT_PATH="$evidence/result.json" node - <<'NODE'
const fs = require('fs');
const result = {
  schemaVersion: 1,
  pr: 2260,
  baseSha: process.env.BASE_SHA,
  headSha: process.env.CANDIDATE_SHA,
  runnerOS: process.env.RUNNER_OS,
  runnerArch: process.env.RUNNER_ARCH,
  baselineControl: 'passed',
  candidateControl: 'passed',
  candidateFreeSuite: 'passed',
  verdict: 'passed'
};
fs.writeFileSync(process.env.RESULT_PATH, JSON.stringify(result, null, 2) + '\n');
NODE

echo "FINAL_CONTROL_VERDICT=PASS" | tee "$evidence/verdict.log"

