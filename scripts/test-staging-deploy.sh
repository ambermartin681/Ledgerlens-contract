#!/usr/bin/env bash
# Hermetic tests for the staging continuous-deployment path (issue #1236).
#
# No network, no Soroban toolchain, no secrets required: the Soroban CLI is
# stubbed on PATH (same pattern as scripts/health_check.test.sh) and the
# upgrade script runs against a temp status file + temp evidence dir.
#
# Covers:
#   1. Workflow gate/concurrency/secret-scope/rollback/notify structure.
#   2. deploy/staging.json required keys + schema enum guards.
#   3. Script syntax (--help, bash -n) and --dry-run paths.
#   4. Broken-change simulation: STAGING_SMOKE_FAIL=1 must trigger the
#      rollback branch, re-verify health, record rolled-back, exit non-zero.
#
# Usage: ./scripts/test-staging-deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/staging-deploy.yml"
STAGING_JSON="$REPO_ROOT/deploy/staging.json"
STAGING_SCHEMA="$REPO_ROOT/deploy/staging.schema.json"
UPGRADE_SCRIPT="$SCRIPT_DIR/staging-upgrade.sh"
ROLLBACK_SCRIPT="$SCRIPT_DIR/rollback.sh"

TMP_DIR=$(mktemp -d)
STUB_DIR="$TMP_DIR/stubs"
EVIDENCE_DIR="$TMP_DIR/evidence"
STATUS_FILE="$TMP_DIR/staging.json"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$STUB_DIR" "$EVIDENCE_DIR"

pass=0
fail=0

ok() { pass=$((pass + 1)); }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1"; }

assert_contains() {
  local desc="$1" file="$2" needle="$3"
  if grep -F -q -- "$needle" "$file"; then ok; else not_ok "$desc (expected '$needle' in $file)"; fi
}

assert_not_contains() {
  local desc="$1" file="$2" needle="$3"
  if grep -F -q -- "$needle" "$file"; then not_ok "$desc (unexpected '$needle' in $file)"; else ok; fi
}

# ── Stub Soroban CLI (canned, deterministic) ───────────────────────────────
cat > "$STUB_DIR/soroban" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: `keys address` + `contract invoke -- <fn>` for the staging path.
if [ "${1:-}" = "keys" ]; then
  echo "GSTAGINGADMINXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  exit 0
fi
fn=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--" ]; then fn="$arg"; break; fi
  prev="$arg"
done
case "$fn" in
  get_admin) echo "GSTAGINGADMINXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ;;
  get_service) echo "GSTAGINGSERVICEXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ;;
  is_paused) echo "false" ;;
  get_version) echo "4" ;;
  is_service_alive) echo "true" ;;
  get_pending_upgrade) echo "error: HostError: Error(Contract, #13)" >&2; exit 1 ;;
  propose_upgrade) echo "upgrade proposed" ;;
  execute_upgrade) echo "upgrade executed" ;;
  *) echo "stub: unknown function '$fn'" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/soroban"
cat > "$STUB_DIR/stellar" <<'STUB'
#!/usr/bin/env bash
exec soroban "$@"
STUB
chmod +x "$STUB_DIR/stellar"

# Dummy WASM artifacts (content irrelevant; only hashed).
echo "new-wasm-bytes" > "$TMP_DIR/new.wasm"
echo "prev-wasm-bytes" > "$TMP_DIR/prev.wasm"

# ── 1. Workflow structure ──────────────────────────────────────────────────
assert_contains "workflow triggers on Contract CI completion" "$WORKFLOW" 'workflows: ["Contract CI"]'
assert_contains "workflow gates on CI success" "$WORKFLOW" "workflow_run.conclusion == 'success'"
assert_contains "workflow gates on main branch" "$WORKFLOW" "head_branch"
assert_contains "workflow serializes deployments" "$WORKFLOW" "group: staging-deploy"
assert_contains "workflow never cancels a running deploy" "$WORKFLOW" "cancel-in-progress: false"
assert_contains "workflow uses the staging environment" "$WORKFLOW" "environment: staging"
assert_contains "workflow uses a staging-only key" "$WORKFLOW" "STAGING_SOROBAN_SECRET_KEY"
assert_contains "workflow pins the staging contract" "$WORKFLOW" "STAGING_CONTRACT_ID"
assert_contains "workflow drives the proposal flow" "$WORKFLOW" "scripts/staging-upgrade.sh"
assert_contains "workflow runs health checks" "$WORKFLOW" "health_check"
assert_contains "workflow runs canary checks" "$WORKFLOW" "verify-deployment"
assert_contains "workflow fetches the rollback source" "$WORKFLOW" "rollback source"
assert_contains "workflow publishes the status file" "$WORKFLOW" "deploy/staging.json"
assert_contains "workflow notifies on failure" "$WORKFLOW" "Notify maintainers on failure"
assert_contains "failure notice links logs and evidence" "$WORKFLOW" "staging-deployment-evidence"
assert_not_contains "workflow never upgrades mainnet from CD" "$WORKFLOW" "STAGING_NETWORK: mainnet"

# ── 2. Status file schema ──────────────────────────────────────────────────
# Heredoc on a simple command (never on an `if` condition line — older
# msys bash rejects that shape); capture the exit code explicitly.
set +e
python3 - "$STAGING_JSON" "$STAGING_SCHEMA" <<'EOF' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
missing = [k for k in schema["required"] if k not in data]
assert not missing, f"missing keys: {missing}"
assert data["network"] in ("testnet", "futurenet")
assert data["status"] in schema["properties"]["status"]["enum"]
assert data["schema_version"] == 4
EOF
SCHEMA_CHECK_CODE=$?
set -e
if [ "$SCHEMA_CHECK_CODE" -ne 0 ]; then
  not_ok "staging.json validates against staging.schema.json"
fi
if [ "$fail" -eq 0 ]; then ok; fi

# ── 3. Syntax + help + dry runs ────────────────────────────────────────────
for script in "$UPGRADE_SCRIPT" "$ROLLBACK_SCRIPT" "$SCRIPT_DIR/health_check.sh" "$SCRIPT_DIR/verify-deployment.sh"; do
  if bash -n "$script"; then ok; else not_ok "bash -n $script"; fi
done

if "$UPGRADE_SCRIPT" --help >/dev/null 2>&1; then ok; else not_ok "staging-upgrade.sh --help"; fi

if PATH="$STUB_DIR:$PATH" "$UPGRADE_SCRIPT" --dry-run --non-interactive \
    --evidence-dir "$EVIDENCE_DIR" --staging-status "$STATUS_FILE" \
    testnet staging-deployer CSTAGINGXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
    "$TMP_DIR/new.wasm" >/dev/null 2>&1; then
  ok
else
  not_ok "staging-upgrade.sh --dry-run succeeds"
fi

if "$ROLLBACK_SCRIPT" --dry-run --non-interactive \
    testnet staging-deployer CSTAGINGXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
    "$TMP_DIR/prev.wasm" >/dev/null 2>&1; then
  ok
else
  not_ok "rollback.sh --dry-run --non-interactive succeeds without prompting"
fi

# Missing rollback source must fail closed (unless explicitly allowed).
if PATH="$STUB_DIR:$PATH" STAGING_ALLOW_SKIP_DELAY_WAIT=1 "$UPGRADE_SCRIPT" --non-interactive \
    --skip-delay-wait --evidence-dir "$EVIDENCE_DIR" --staging-status "$STATUS_FILE" \
    testnet staging-deployer CSTAGINGXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
    "$TMP_DIR/new.wasm" >/dev/null 2>&1; then
  not_ok "staging-upgrade without --previous-wasm should fail closed"
else
  ok
fi

# ── 4. Broken-change simulation: failure triggers rollback + notice data ──
BROKEN_LOG="$TMP_DIR/broken.log"
set +e
PATH="$STUB_DIR:$PATH" STAGING_ALLOW_SKIP_DELAY_WAIT=1 STAGING_SMOKE_FAIL=1 \
  "$UPGRADE_SCRIPT" --non-interactive --skip-delay-wait \
  --evidence-dir "$EVIDENCE_DIR" --staging-status "$STATUS_FILE" \
  --previous-wasm "$TMP_DIR/prev.wasm" \
  testnet staging-deployer CSTAGINGXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
  "$TMP_DIR/new.wasm" >"$BROKEN_LOG" 2>&1
CODE=$?
set -e

if [ "$CODE" -ne 0 ]; then ok; else not_ok "broken change exits non-zero (got $CODE)"; fi
if grep -F -q "ROLLBACK TRIGGERED" "$BROKEN_LOG"; then ok; else not_ok "broken change triggers rollback"; fi
if grep -F -q "Post-rollback health checks PASSED" "$BROKEN_LOG"; then ok; else not_ok "rollback restores health-verified state"; fi
if python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['status']=='rolled-back'" "$STATUS_FILE" 2>/dev/null; then
  ok
else
  not_ok "broken change records rolled-back in the status file"
fi

# ── 5. Failure-path guarantees: status is never left `pending` ────────────
# Terminal statuses are the only ones a failure may record; `pending` means
# the workflow died before recording an outcome (the #1236/#1493 symptom).
assert_terminal_status() {
  local desc="$1" file="$2"
  if python3 -c "import json,sys; s=json.load(open(sys.argv[1]))['status']; assert s in ('failed','rolled-back'), s" "$file" 2>/dev/null; then
    ok
  else
    not_ok "$desc (status must be failed or rolled-back, never pending)"
  fi
}

# 5a. Broken change (smoke failure) already ran above; re-assert terminality.
assert_terminal_status "broken change leaves a terminal status" "$STATUS_FILE"

# 5b. Baseline-health failure: the pre-upgrade health check fails, so the
# upgrade must abort and record a terminal status (not `pending`).
BASELINE_STUB_DIR="$TMP_DIR/stubs-baseline"
mkdir -p "$BASELINE_STUB_DIR"
cat > "$BASELINE_STUB_DIR/soroban" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "keys" ]; then
  echo "GSTAGINGADMINXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  exit 0
fi
fn=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--" ]; then fn="$arg"; break; fi
  prev="$arg"
done
case "$fn" in
  get_admin) echo "GSTAGINGADMINXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ;;
  get_service) echo "GSTAGINGSERVICEXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ;;
  is_paused) echo "false" ;;
  get_version) echo "4" ;;
  is_service_alive) echo "false" ;;
  get_pending_upgrade) echo "error: HostError: Error(Contract, #13)" >&2; exit 1 ;;
  propose_upgrade) echo "upgrade proposed" ;;
  execute_upgrade) echo "upgrade executed" ;;
  *) echo "stub: unknown function '$fn'" >&2; exit 1 ;;
esac
STUB
chmod +x "$BASELINE_STUB_DIR/soroban"
cat > "$BASELINE_STUB_DIR/stellar" <<'STUB'
#!/usr/bin/env bash
exec soroban "$@"
STUB
chmod +x "$BASELINE_STUB_DIR/stellar"

BASELINE_STATUS="$TMP_DIR/staging-baseline.json"
BASELINE_LOG="$TMP_DIR/baseline.log"
set +e
PATH="$BASELINE_STUB_DIR:$PATH" STAGING_ALLOW_SKIP_DELAY_WAIT=1 \
  "$UPGRADE_SCRIPT" --non-interactive --skip-delay-wait \
  --evidence-dir "$EVIDENCE_DIR" --staging-status "$BASELINE_STATUS" \
  --previous-wasm "$TMP_DIR/prev.wasm" \
  testnet staging-deployer CSTAGINGXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
  "$TMP_DIR/new.wasm" >"$BASELINE_LOG" 2>&1
BASELINE_CODE=$?
set -e

if [ "$BASELINE_CODE" -ne 0 ]; then ok; else not_ok "baseline-health failure exits non-zero (got $BASELINE_CODE)"; fi
assert_terminal_status "baseline-health failure leaves a terminal status" "$BASELINE_STATUS"

# 5c. The workflow's notify step must run on failure and see a non-pending
# status, so maintainers are never told "pending" after a failed promotion.
assert_contains "workflow notifies on failure" "$WORKFLOW" "if: failure()"
assert_contains "notify step reads the recorded status" "$WORKFLOW" "deploy/staging.json"
assert_not_contains "workflow never hardcodes a pending status" "$WORKFLOW" '"status": "pending"'

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
