#!/usr/bin/env bash
set -euo pipefail

# Behavior-specific PR #2260 probe. The caller supplies only isolated paths.
# This exact file is used for immutable main and the exact PR head.

repo_input="${GSTACK_UNDER_TEST:?GSTACK_UNDER_TEST must name the isolated gstack checkout}"
fixture_input="${PR2260_FIXTURE_ROOT:?PR2260_FIXTURE_ROOT must name the isolated fixture directory}"
evidence_input="${PR2260_EVIDENCE_DIR:?PR2260_EVIDENCE_DIR must name the isolated evidence directory}"

if command -v cygpath >/dev/null 2>&1; then
  repo="$(cygpath -u "$repo_input")"
  fixture_root="$(cygpath -u "$fixture_input")"
  evidence_dir="$(cygpath -u "$evidence_input")"
else
  repo="$repo_input"
  fixture_root="$fixture_input"
  evidence_dir="$evidence_input"
fi

case "$repo" in
  /c/gstack-isolated/pr-2260/*) ;;
  *) echo "SAFETY_REFUSAL: checkout is outside C:/gstack-isolated/pr-2260: $repo" >&2; exit 90 ;;
esac
case "$evidence_dir" in
  /c/gstack-isolated/pr-2260/*) ;;
  *) echo "SAFETY_REFUSAL: evidence is outside C:/gstack-isolated/pr-2260: $evidence_dir" >&2; exit 91 ;;
esac

mkdir -p "$evidence_dir"
cd "$repo"

echo "PROBE_ID=pr-2260-windows-node-server-bundle-v1"
echo "REPO=$repo"
echo "HOME=$HOME"
echo "MSYS_NO_PATHCONV=1"
cmd.exe //d //c ver
uname -a
printf 'bun='; bun --version
printf 'bun_revision='; bun --revision
printf 'node='; node --version
printf 'git='; git --version
printf 'bash='; bash --version | head -n 1
printf 'cygpath='; cygpath --version | head -n 1
shasum -a 256 browse/scripts/build-node-server.sh

dist="$repo/browse/dist"
case "$dist" in
  /c/gstack-isolated/pr-2260/*/browse/dist) ;;
  *) echo "SAFETY_REFUSAL: dist path is not the isolated browse/dist: $dist" >&2; exit 92 ;;
esac

# Required clean start: remove only this isolated checkout's generated browse/dist.
rm -rf -- "$dist"

compat_header='// ── Windows Node.js compatibility (auto-generated) ──'

assert_bundle() {
  local label="$1"
  local final="$dist/server-node.mjs"
  local header_count
  test -s "$final" || {
    echo "REPORTED_FAILURE_SIGNATURE[$label]: nonempty browse/dist/server-node.mjs was not produced" >&2
    return 71
  }
  header_count="$(grep -Fxc "$compat_header" "$final" || true)"
  test "$header_count" = 1 || {
    echo "REPORTED_FAILURE_SIGNATURE[$label]: expected exactly one compatibility header, got $header_count" >&2
    return 72
  }
  test ! -e "$dist/server-node.raw.mjs" || {
    echo "ARTIFACT_FAILURE[$label]: raw bundle remains" >&2
    return 73
  }
  test ! -e "$dist/server-node.tmp.mjs" || {
    echo "ARTIFACT_FAILURE[$label]: temp bundle remains" >&2
    return 74
  }
  node --check "$final"
  echo "BUNDLE_ASSERTIONS_OK[$label] size=$(wc -c < "$final") header_count=$header_count"
}

run_bundle_build() {
  local label="$1"
  local rc
  if MSYS_NO_PATHCONV=1 bash browse/scripts/build-node-server.sh; then rc=0; else rc=$?; fi
  echo "BUILD_NODE_SERVER_EXIT[$label]=$rc"
  if [ "$rc" -ne 0 ]; then
    echo "REPORTED_FAILURE_SIGNATURE[$label]: build-node-server exited $rc under Windows Git Bash with MSYS_NO_PATHCONV=1" >&2
    return "$rc"
  fi
  if assert_bundle "$label"; then return 0; else rc=$?; return "$rc"; fi
}

primary_failed=0
for build_label in first second; do
  if run_bundle_build "$build_label"; then
    build_result=0
  else
    build_result=$?
  fi
  if [ "$build_result" -ne 0 ]; then
    echo "BUILD_NODE_SERVER_PROBE_RESULT[$build_label]=fail exit=$build_result" >&2
    primary_failed=1
  else
    echo "BUILD_NODE_SERVER_PROBE_RESULT[$build_label]=pass exit=0"
  fi
done
if [ "$primary_failed" -ne 0 ]; then
  echo "PRIMARY_PROBE_FAIL: one or both required build-node-server executions failed" >&2
  exit 79
fi

# Full production build must retain the same artifact invariants.
MSYS_NO_PATHCONV=1 bun run build
echo "FULL_BUILD_EXIT=0"
assert_bundle full-build

browse_bin=''
for candidate in "$dist/browse.exe" "$dist/browse"; do
  if [ -s "$candidate" ]; then browse_bin="$candidate"; break; fi
done
test -n "$browse_bin" || { echo "RUNTIME_FAILURE: compiled browse CLI missing" >&2; exit 75; }
echo "BROWSE_BIN=$browse_bin"

origin_log="$evidence_dir/local-origin.log"
socks_log="$evidence_dir/local-socks.log"
shot="$evidence_dir/fixture-screenshot.png"
status_log="$evidence_dir/browse-status.log"
goto_log="$evidence_dir/browse-goto.log"
screenshot_log="$evidence_dir/browse-screenshot.log"
health_log="$evidence_dir/browse-health.json"
runtime_log="$evidence_dir/node-runtime.txt"

node "$fixture_root/local-http.cjs" >"$origin_log" 2>&1 &
origin_pid=$!
node "$fixture_root/local-auth-socks.cjs" >"$socks_log" 2>&1 &
socks_pid=$!

cleanup() {
  set +e
  if [ -n "${browse_bin:-}" ] && [ -e "$repo/.gstack/browse.json" ]; then
    "$browse_bin" --proxy 'socks5://pr2260:local-only@127.0.0.1:39082' stop >/dev/null 2>&1
  fi
  powershell.exe -NoProfile -NonInteractive -Command \
    "Stop-Process -Id ${origin_pid:-0},${socks_pid:-0} -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  if grep -q '^READY ' "$origin_log" 2>/dev/null && grep -q '^READY ' "$socks_log" 2>/dev/null; then break; fi
  sleep 0.1
done
grep -q '^READY http 127.0.0.1:39081$' "$origin_log"
grep -q '^READY socks5-auth 127.0.0.1:39082$' "$socks_log"

proxy='socks5://pr2260:local-only@127.0.0.1:39082'
export BROWSE_PARENT_PID=0
export GSTACK_HOME="$HOME/.gstack-runtime"
export CHROMIUM_PROFILE="$HOME/.gstack-runtime/chromium-profile"

"$browse_bin" --proxy "$proxy" goto 'http://fixture.invalid/' | tee "$goto_log"
"$browse_bin" --proxy "$proxy" status | tee "$status_log"

state_file="$repo/.gstack/browse.json"
test -s "$state_file"
state_pid="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).pid)' "$state_file")"
state_port="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).port)' "$state_file")"

node -e 'fetch(`http://127.0.0.1:${process.argv[1]}/health`).then(async r=>{const t=await r.text(); console.log(t); if(!r.ok||JSON.parse(t).status!=="healthy") process.exit(1)}).catch(e=>{console.error(e);process.exit(1)})' "$state_port" | tee "$health_log"

powershell.exe -NoProfile -NonInteractive -Command \
  "\$p=Get-CimInstance Win32_Process -Filter 'ProcessId=$state_pid'; if(-not \$p){exit 1}; Write-Output \$p.ExecutablePath; Write-Output \$p.CommandLine" | tee "$runtime_log"
grep -Eqi 'node(\.exe)?' "$runtime_log"
grep -Fqi 'server-node.mjs' "$runtime_log"
echo "NODE_FALLBACK_ASSERTION_OK pid=$state_pid port=$state_port"

page_text="$("$browse_bin" --proxy "$proxy" text h1)"
printf '%s\n' "$page_text"
grep -Fq 'PR2260 SOCKS SHARP FIXTURE' <<<"$page_text"

if command -v cygpath >/dev/null 2>&1; then shot_arg="$(cygpath -w "$shot")"; else shot_arg="$shot"; fi
"$browse_bin" --proxy "$proxy" screenshot "$shot_arg" | tee "$screenshot_log"
test -s "$shot"

dims="$(node -e 'require("sharp")(process.argv[1]).metadata().then(m=>{console.log(`${m.width}x${m.height}`);if(!m.width||!m.height||m.width>2000||m.height>2000)process.exit(1)}).catch(e=>{console.error(e);process.exit(1)})' "$shot")"
echo "SHARP_SCREENSHOT_ASSERTION_OK dimensions=$dims bytes=$(wc -c < "$shot")"

grep -q 'AUTH user=pr2260 result=ok' "$socks_log"
grep -q 'CONNECT host=1.1.1.1 port=443 route=127.0.0.1:39081' "$socks_log"
grep -q 'CONNECT host=fixture.invalid port=80 route=127.0.0.1:39081' "$socks_log"
echo "SOCKS_ROUTE_ASSERTION_OK"

"$browse_bin" --proxy "$proxy" stop
for _ in $(seq 1 100); do
  if [ ! -e "$state_file" ]; then break; fi
  sleep 0.1
done
test ! -e "$state_file"
powershell.exe -NoProfile -NonInteractive -Command \
  "if(Get-Process -Id $state_pid -ErrorAction SilentlyContinue){exit 1}else{Write-Output 'stopped'}"
echo "CLEAN_STOP_ASSERTION_OK pid=$state_pid"

trap - EXIT
cleanup
echo "PRIMARY_PROBE_PASS"
