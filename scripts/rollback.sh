#!/usr/bin/env bash
set -euo pipefail

ROLLBACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROLLBACK_DIR/.." && pwd)"

DRY_RUN=false
NON_INTERACTIVE=false
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --non-interactive|--yes|-y) NON_INTERACTIVE=true ;;
    --help)
      sed -n '3,20p' "$0"
      exit 0
      ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

NETWORK="${1:?ERROR: network argument is required (testnet|futurenet|mainnet)}"
ADMIN_IDENTITY="${2:?ERROR: admin-identity argument is required}"
TARGET_CONTRACT_ID="${3:?ERROR: target-contract-id argument is required}"
PREVIOUS_WASM_PATH="${4:?ERROR: previous-wasm-path argument is required}"

run() {
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

log() { echo "==> $*"; }

# ── Safety check ──────────────────────────────────────────────
if [ "$NETWORK" = "mainnet" ]; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║  MAINNET ROLLBACK — this action cannot be undone    ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo ""
  if [ "$NON_INTERACTIVE" = true ]; then
    echo "ERROR: refusing mainnet rollback in --non-interactive mode without an operator confirmation." >&2
    echo "Rerun interactively and type 'rollback-mainnet' at the prompt." >&2
    exit 1
  fi
  read -rp "  Type 'rollback-mainnet' to confirm: " CONFIRM
  [ "$CONFIRM" = "rollback-mainnet" ] || { echo "Aborted."; exit 1; }
fi

# ── Validate previous WASM ────────────────────────────────────
if [ ! -f "$PREVIOUS_WASM_PATH" ]; then
  echo "ERROR: Previous WASM not found at $PREVIOUS_WASM_PATH" >&2
  exit 1
fi

PREVIOUS_WASM_HASH=$(sha256sum "$PREVIOUS_WASM_PATH" | awk '{print $1}')
log "Previous WASM SHA-256: $PREVIOUS_WASM_HASH"

# ── Step 1: Propose the previous WASM ─────────────────────────
log "Step 1: Proposing rollback upgrade (previous WASM hash)"
if [ "$DRY_RUN" = true ]; then
  ROLLBACK_PROPOSAL_ID="<PROPOSAL_ID_PLACEHOLDER>"
  echo "[dry-run] soroban contract invoke --id $TARGET_CONTRACT_ID --source $ADMIN_IDENTITY --network $NETWORK -- propose_upgrade --admin-signers '[$ADMIN_IDENTITY]' --new-wasm-hash $PREVIOUS_WASM_HASH"
else
  PROPOSAL_OUTPUT=$(soroban contract invoke \
    --id "$TARGET_CONTRACT_ID" \
    --source "$ADMIN_IDENTITY" \
    --network "$NETWORK" \
    -- \
    propose_upgrade \
    --admin-signers "$(soroban keys address "$ADMIN_IDENTITY" 2>/dev/null || echo '<ADMIN>')" \
    --new-wasm-hash "$PREVIOUS_WASM_HASH" 2>&1)
  log "Proposal output: $PROPOSAL_OUTPUT"
fi

# ── Step 2: Monitor the delay ─────────────────────────────────
log "Step 2: Waiting for upgrade delay to elapse"

# Bounded polling of get_pending_upgrade until executable_after has passed.
# Tunable via env vars so CI can shorten/lengthen the wait.
ROLLBACK_POLL_INTERVAL="${ROLLBACK_POLL_INTERVAL:-5}"
ROLLBACK_POLL_TIMEOUT="${ROLLBACK_POLL_TIMEOUT:-600}"

# Extract a numeric field (e.g. executable_after) from get_pending_upgrade output.
# The soroban CLI may render the result as JSON or as a plain scalar; handle both.
extract_pending_field() {
  local output="$1" field="$2"
  printf '%s' "$output" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]*" \
    | head -n1 | grep -o '[0-9]*$'
}

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] soroban contract invoke --id $TARGET_CONTRACT_ID --source $ADMIN_IDENTITY --network $NETWORK -- get_pending_upgrade"
  echo "[dry-run] poll get_pending_upgrade every ${ROLLBACK_POLL_INTERVAL}s until executable_after (timeout ${ROLLBACK_POLL_TIMEOUT}s)"
else
  log "   Polling get_pending_upgrade every ${ROLLBACK_POLL_INTERVAL}s (timeout ${ROLLBACK_POLL_TIMEOUT}s)"
  POLL_ELAPSED=0
  EXECUTABLE_AFTER=""
  while :; do
    PENDING_OUTPUT=$(soroban contract invoke \
      --id "$TARGET_CONTRACT_ID" \
      --source "$ADMIN_IDENTITY" \
      --network "$NETWORK" \
      -- \
      get_pending_upgrade 2>&1 || echo "PENDING_QUERY_FAILED")

    if [ "$PENDING_OUTPUT" = "PENDING_QUERY_FAILED" ]; then
      log "ERROR: get_pending_upgrade failed while waiting for rollback delay."
      log "   Output: $PENDING_OUTPUT"
      exit 1
    fi

    EXECUTABLE_AFTER=$(extract_pending_field "$PENDING_OUTPUT" "executable_after" || true)
    if [ -z "$EXECUTABLE_AFTER" ]; then
      log "ERROR: could not parse executable_after from get_pending_upgrade output."
      log "   Output: $PENDING_OUTPUT"
      exit 1
    fi

    NOW=$(date +%s)
    if [ "$NOW" -ge "$EXECUTABLE_AFTER" ]; then
      log "   Upgrade delay elapsed (executable_after=$EXECUTABLE_AFTER, now=$NOW)."
      break
    fi

    if [ "$POLL_ELAPSED" -ge "$ROLLBACK_POLL_TIMEOUT" ]; then
      log "ERROR: timed out after ${ROLLBACK_POLL_TIMEOUT}s waiting for executable_after=$EXECUTABLE_AFTER."
      exit 1
    fi

    log "   Not yet executable (executable_after=$EXECUTABLE_AFTER, now=$NOW); sleeping ${ROLLBACK_POLL_INTERVAL}s."
    sleep "$ROLLBACK_POLL_INTERVAL"
    POLL_ELAPSED=$((POLL_ELAPSED + ROLLBACK_POLL_INTERVAL))
  done
fi

# ── Step 3: Execute the rollback ──────────────────────────────
if [ "$NON_INTERACTIVE" = true ]; then
  log "Non-interactive mode: proceeding with rollback execution (no prompt)"
else
  read -rp "  Execute the rollback upgrade now? (yes/no): " EXECUTE_CONFIRM
  [ "$EXECUTE_CONFIRM" = "yes" ] || { log "Rollback aborted by operator."; exit 0; }
fi

log "Step 3: Executing rollback upgrade"
if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] soroban contract invoke --id $TARGET_CONTRACT_ID --source $ADMIN_IDENTITY --network $NETWORK -- execute_upgrade --admin-signers '[$ADMIN_IDENTITY]'"
else
  EXECUTE_OUTPUT=$(soroban contract invoke \
    --id "$TARGET_CONTRACT_ID" \
    --source "$ADMIN_IDENTITY" \
    --network "$NETWORK" \
    -- \
    execute_upgrade \
    --admin-signers "$(soroban keys address "$ADMIN_IDENTITY" 2>/dev/null || echo '<ADMIN>')" 2>&1)
  log "Execute output: $EXECUTE_OUTPUT"
fi

# ── Step 4: Verify rollback ───────────────────────────────────
log "Step 4: Verifying rollback"
if [ "$DRY_RUN" = false ]; then
  VERIFY_VERSION=$(soroban contract invoke \
    --id "$TARGET_CONTRACT_ID" \
    --source "$ADMIN_IDENTITY" \
    --network "$NETWORK" \
    -- \
    get_version 2>/dev/null || echo "VERIFY_FAILED")

  if [ "$VERIFY_VERSION" = "VERIFY_FAILED" ]; then
    log "ERROR: Rollback verification failed — get_version returned an error."
    exit 1
  fi

  log "Rollback contract version: $VERIFY_VERSION"

  VERIFY_ADMIN=$(soroban contract invoke \
    --id "$TARGET_CONTRACT_ID" \
    --source "$ADMIN_IDENTITY" \
    --network "$NETWORK" \
    -- \
    get_admin 2>/dev/null || echo "VERIFY_FAILED")

  if [ "$VERIFY_ADMIN" = "VERIFY_FAILED" ]; then
    log "ERROR: Rollback verification failed — get_admin returned an error."
    exit 1
  fi

  log "Rollback admin verified: $VERIFY_ADMIN"
fi

# ── Step 4b: Health check the restored instance ───────────────
log "Step 4b: Running health checks against rolled-back contract"
HEALTH_CHECK_SCRIPT="$PROJECT_ROOT/scripts/health_check.sh"
if [ ! -f "$HEALTH_CHECK_SCRIPT" ]; then
  log "ERROR: health_check.sh not found at $HEALTH_CHECK_SCRIPT — cannot verify rollback."
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] $HEALTH_CHECK_SCRIPT $NETWORK $TARGET_CONTRACT_ID"
else
  if ! "$HEALTH_CHECK_SCRIPT" "$NETWORK" "$TARGET_CONTRACT_ID"; then
    log "ERROR: health checks failed after rollback — restored instance is not healthy."
    exit 1
  fi
  log "Health checks passed against rolled-back contract."
fi

# ── Step 5: Replay verification ───────────────────────────────
log "Step 5: Replaying test data against rolled-back contract"
log "   Run: cargo test -p replay -- --nocapture"
log "   Run: cargo run -p replay --manifest-path tools/replay/Cargo.toml"

# ── Summary ────────────────────────────────────────────────────
echo ""
log "── Rollback complete ──"
log "Network:              $NETWORK"
log "Contract:             $TARGET_CONTRACT_ID"
log "Previous WASM hash:   $PREVIOUS_WASM_HASH"
log "────────────────────────────────────────"
echo ""
log "IMPORTANT: Re-run full verification suite against the rolled-back contract."
log "Notify all integrators that the contract has been rolled back."
echo ""