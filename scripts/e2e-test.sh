#!/usr/bin/env bash
# Cross-program chained call (CPI) end-to-end test.
#
# Proves that `vault.deposit` mutates its own per-owner PDA AND drives
# `ledger.record` through a ChainedCall — by reading the ledger PDA back and
# asserting its total by value.
#
# The script owns its whole chain: it starts a sequencer with a fresh home and
# a fresh wallet on every run, so it is re-runnable with no manual cleanup.
#
# Usage: ./scripts/e2e-test.sh [WORK_DIR]
#
# Required:
#   LSSA_DIR  - logos-execution-zone checkout with sequencer_service + wallet
#               built. The sequencer MUST be built with --features standalone,
#               otherwise it blocks on a Bedrock node and never serves RPC.
#   spel      - on PATH
# Optional:
#   SKIP_BUILD=1     - reuse existing guest binaries (builds take 5-10 min each)
#   SEQUENCER_PORT   - default 3040
#   METRICS_PORT     - default 9000 (change it if 9000 is taken)
#   LEZ_REF          - LEZ git ref the configs are read from (default v0.2.4);
#                      must match the version the binaries were built from

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${1:-${WORK_DIR:-/tmp/spel-cpi-e2e}}"
SEQUENCER_PORT="${SEQUENCER_PORT:-3040}"
METRICS_PORT="${METRICS_PORT:-9000}"
SEQUENCER_URL="http://127.0.0.1:${SEQUENCER_PORT}"
WALLET_PASSWORD="${WALLET_PASSWORD:-test}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[CPI-E2E]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    if [ -f "$WORK_DIR/sequencer.log" ]; then
        echo -e "${RED}--- sequencer rejections ---${NC}"
        grep -A2 "failed execution check" "$WORK_DIR/sequencer.log" | tail -12 || echo "  (none)"
        # A startup crash leaves no rejections at all, and its cause is only in
        # the tail — printing it here saves digging a log out of CI artifacts.
        echo -e "${RED}--- last of sequencer.log ---${NC}"
        tail -8 "$WORK_DIR/sequencer.log"
    fi
    exit 1
}

# 0 when something is already listening on the port.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

cleanup() {
    if [ -n "${SEQ_PID:-}" ] && kill -0 "$SEQ_PID" 2>/dev/null; then
        kill "$SEQ_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$SEQ_PID" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$SEQ_PID" 2>/dev/null || true
        wait "$SEQ_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

export RISC0_DEV_MODE=1

# ─── Prerequisites ────────────────────────────────────────────────────────
[ -n "${LSSA_DIR:-}" ] || fail "LSSA_DIR is required (logos-execution-zone checkout)"
LSSA_DIR="$(cd "$LSSA_DIR" && pwd)"
SEQ_BIN="$LSSA_DIR/target/release/sequencer_service"
WALLET_BIN="$LSSA_DIR/target/release/wallet"
[ -x "$SEQ_BIN" ]    || fail "sequencer_service not found at $SEQ_BIN"
[ -x "$WALLET_BIN" ] || fail "wallet not found at $WALLET_BIN"
command -v spel >/dev/null 2>&1 || fail "spel not on PATH"

# The configs must match the LEZ version the binaries were built from, not
# whatever the checkout happens to be sitting on: v0.2.0-rc1's sequencer
# config has no `bedrock_config.funding_key`, and a v0.2.4 sequencer refuses
# to start without it. Read them out of the tagged tree instead of the
# working tree, and only fall back to on-disk paths if the ref is missing.
LEZ_REF="${LEZ_REF:-v0.2.4}"

# Copy a config out of the LEZ tree into <dst>. Candidate paths are tried in
# order at $LEZ_REF first, then in the working tree — the configs moved under
# `lez/` in v0.2.1, so a sweep across versions needs both layouts.
# Usage: lez_config <dst> <candidate-path>...
lez_config() {
    local dst="$1" p; shift
    for p in "$@"; do
        if git -C "$LSSA_DIR" cat-file -e "${LEZ_REF}:${p}" 2>/dev/null; then
            git -C "$LSSA_DIR" show "${LEZ_REF}:${p}" > "$dst" && return 0
        fi
    done
    warn "no config found at ${LEZ_REF}; falling back to the working tree"
    for p in "$@"; do
        [ -f "$LSSA_DIR/$p" ] && { cp "$LSSA_DIR/$p" "$dst"; return 0; }
    done
    return 1
}

log "Fresh work dir: $WORK_DIR"
rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR/seq-home" "$WORK_DIR/wallet"

# ─── Step 1: Build both guests ────────────────────────────────────────────
LEDGER_BIN="$REPO_ROOT/ledger/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/ledger.bin"
VAULT_BIN="$REPO_ROOT/vault/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/vault.bin"

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -f "$LEDGER_BIN" ] && [ -f "$VAULT_BIN" ]; then
    log "Step 1: SKIP_BUILD=1, reusing existing guest binaries"
else
    log "Step 1: Building both guests (5-10 min each, docker)..."
    (cd "$REPO_ROOT/ledger" && RISC0_SKIP_BUILD= make build) > "$WORK_DIR/build-ledger.log" 2>&1 \
        || { cat "$WORK_DIR/build-ledger.log"; fail "ledger build failed"; }
    (cd "$REPO_ROOT/vault" && RISC0_SKIP_BUILD= make build) > "$WORK_DIR/build-vault.log" 2>&1 \
        || { cat "$WORK_DIR/build-vault.log"; fail "vault build failed"; }
fi
[ -f "$LEDGER_BIN" ] || fail "ledger binary missing: $LEDGER_BIN"
[ -f "$VAULT_BIN" ]  || fail "vault binary missing: $VAULT_BIN"
log "  ✓ ledger.bin + vault.bin present"

# ─── Step 2: Generate IDLs ────────────────────────────────────────────────
log "Step 2: Generating IDLs..."
spel generate-idl "$REPO_ROOT/ledger/methods/guest/src/bin/ledger.rs" > "$WORK_DIR/ledger-idl.json" 2>/dev/null \
    || fail "ledger IDL generation failed"
spel generate-idl "$REPO_ROOT/vault/methods/guest/src/bin/vault.rs" > "$WORK_DIR/vault-idl.json" 2>/dev/null \
    || fail "vault IDL generation failed"
LEDGER_IDL="$WORK_DIR/ledger-idl.json"; VAULT_IDL="$WORK_DIR/vault-idl.json"
log "  ✓ IDLs written"

# ─── Step 3: Start a fresh sequencer ──────────────────────────────────────
# A fresh seq-home means a fresh RocksDB, so every run starts from genesis and
# re-deploying the same binaries never hits ProgramAlreadyExists.
log "Step 3: Starting sequencer on :${SEQUENCER_PORT} (metrics :${METRICS_PORT})..."
SEQ_SRC="$WORK_DIR/sequencer_config.src.json"
lez_config "$SEQ_SRC" \
    "lez/sequencer/service/configs/debug/sequencer_config.json" \
    "sequencer/service/configs/debug/sequencer_config.json" \
    || fail "sequencer config not found at ${LEZ_REF} or under $LSSA_DIR"
python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1])); cfg["home"] = sys.argv[2]
if "funding_key" not in cfg.get("bedrock_config", {}):
    sys.exit("sequencer config has no bedrock_config.funding_key — "
             "it is from an older LEZ than the binaries; set LEZ_REF")
json.dump(cfg, open(sys.argv[3], "w"))
' "$SEQ_SRC" "$WORK_DIR/seq-home" "$WORK_DIR/sequencer_config.json" || fail "could not patch sequencer config"

# A leftover sequencer from an earlier run would answer the health check below
# and silently serve a chain that already has these programs deployed, so the
# run would fail much later with a confusing error. Refuse to start instead.
if port_busy "$SEQUENCER_PORT"; then fail "port ${SEQUENCER_PORT} is already in use — a sequencer from an earlier run is still alive (\`pkill -f sequencer_service\`), or pick another SEQUENCER_PORT"; fi
if port_busy "$METRICS_PORT"; then fail "metrics port ${METRICS_PORT} is already in use — pick another METRICS_PORT"; fi

# `exec` matters: without it $! is the subshell, and killing the subshell leaves
# the sequencer orphaned, still holding the port for the next run.
( cd "$WORK_DIR/seq-home" && exec env RUST_LOG=info "$SEQ_BIN" --port "$SEQUENCER_PORT" \
    --metrics-address "0.0.0.0:${METRICS_PORT}" "$WORK_DIR/sequencer_config.json" \
    > "$WORK_DIR/sequencer.log" 2>&1 ) &
SEQ_PID=$!

for i in $(seq 1 60); do
    if curl -sf -X POST "$SEQUENCER_URL" -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' -m 3 >/dev/null 2>&1; then
        log "  ✓ sequencer producing blocks"; break
    fi
    kill -0 "$SEQ_PID" 2>/dev/null || fail "sequencer died on startup (see $WORK_DIR/sequencer.log)"
    [ "$i" = "60" ] && fail "sequencer did not serve RPC within 120s — was it built with --features standalone?"
    sleep 2
done

# ─── Step 4: Wallet + signer ──────────────────────────────────────────────
log "Step 4: Creating wallet and signer..."
WCFG_SRC="$WORK_DIR/wallet_config.src.json"
lez_config "$WCFG_SRC" \
    "lez/wallet/configs/debug/wallet_config.json" \
    "wallet/configs/debug/wallet_config.json" \
    || fail "wallet config not found at ${LEZ_REF} or under $LSSA_DIR"
# LEZ v0.2.1 moved the address into a `sequencers` array; writing the older flat
# `sequencer_addr` is silently ignored and the wallet talks to the default port.
python3 -c '
import json, sys
src, dst, url = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(src))
if isinstance(cfg.get("sequencers"), list):
    entry = cfg["sequencers"][0] if cfg["sequencers"] else {}
    entry["sequencer_addr"] = url
    cfg["sequencers"] = [entry]; cfg.pop("sequencer_addr", None)
else:
    cfg["sequencer_addr"] = url
json.dump(cfg, open(dst, "w"), indent=4)
' "$WCFG_SRC" "$WORK_DIR/wallet/wallet_config.json" "$SEQUENCER_URL" || fail "could not write wallet config"

export LEE_WALLET_HOME_DIR="$WORK_DIR/wallet" NSSA_WALLET_HOME_DIR="$WORK_DIR/wallet"
printf '%s\n' "$WALLET_PASSWORD" | "$WALLET_BIN" account new public > "$WORK_DIR/acct.log" 2>&1 \
    || { cat "$WORK_DIR/acct.log"; fail "account creation failed"; }
SIGNER=$(grep -oE "Public/[A-Za-z0-9]+" "$WORK_DIR/acct.log" | head -1)
[ -n "$SIGNER" ] || { cat "$WORK_DIR/acct.log"; fail "could not parse signer id"; }
SIGNER_BARE="${SIGNER#Public/}"
log "  ✓ signer ${SIGNER:0:24}..."

# ─── Step 5: Deploy both programs ─────────────────────────────────────────
log "Step 5: Deploying ledger and vault..."
printf '%s\n' "$WALLET_PASSWORD" | "$WALLET_BIN" deploy-program "$LEDGER_BIN" > "$WORK_DIR/deploy-ledger.log" 2>&1 \
    || { cat "$WORK_DIR/deploy-ledger.log"; fail "ledger deploy failed"; }
printf '%s\n' "$WALLET_PASSWORD" | "$WALLET_BIN" deploy-program "$VAULT_BIN" > "$WORK_DIR/deploy-vault.log" 2>&1 \
    || { cat "$WORK_DIR/deploy-vault.log"; fail "vault deploy failed"; }
# `--format hex` gives the bare 64-char ImageID, which is the form a
# `program_id` instruction arg accepts. Do NOT scrape the human-readable
# output's "ProgramId (hex)" line: those comma-separated bare hex words are
# read back as decimal and rejected. Requires spel >= 0.4 (`program-id` was
# folded out of `inspect`).
LEDGER_PID_HEX=$(spel program-id "$LEDGER_BIN" --format hex 2>/dev/null | tail -1)
[ -n "$LEDGER_PID_HEX" ] || fail "could not read ledger ProgramId (is spel new enough for \`program-id\`?)"
log "  ✓ both deployed (ledger ${LEDGER_PID_HEX:0:16}...)"

export SEQUENCER_URL

# ─── Step 6: Initialize the vault config ──────────────────────────────────
log "Step 6: vault initialize..."
spel --idl "$VAULT_IDL" -p "$VAULT_BIN" initialize --admin "$SIGNER" > "$WORK_DIR/init.log" 2>&1 \
    || { cat "$WORK_DIR/init.log"; fail "vault initialize did not confirm"; }
log "  ✓ vault config created"

# ─── Step 7: Ledger starts empty ──────────────────────────────────────────
LOG_PDA=$(spel --idl "$LEDGER_IDL" -p "$LEDGER_BIN" pda log 2>/dev/null | tail -1)
[ -n "$LOG_PDA" ] || fail "could not derive the ledger log PDA"
log "Step 7: ledger log PDA $LOG_PDA"
spel --idl "$LEDGER_IDL" -p "$LEDGER_BIN" inspect "$LOG_PDA" --type LedgerLog > "$WORK_DIR/ledger-before.log" 2>&1 || true
grep -q "empty" "$WORK_DIR/ledger-before.log" \
    || warn "ledger PDA is not empty at start — chain state may be dirty"

# ─── Step 8: deposit 500 -> chained call must write the ledger ────────────
log "Step 8: vault deposit 500 (fires the chained call)..."
spel --idl "$VAULT_IDL" -p "$VAULT_BIN" deposit \
    --owner "$SIGNER" --log "$LOG_PDA" --ledger-program-id "$LEDGER_PID_HEX" --amount 500 \
    > "$WORK_DIR/deposit1.log" 2>&1 || { cat "$WORK_DIR/deposit1.log"; fail "deposit 500 did not confirm"; }

assert_ledger_total() {
    local expected="$1" label="$2"
    local out; out=$(spel --idl "$LEDGER_IDL" -p "$LEDGER_BIN" inspect "$LOG_PDA" --type LedgerLog 2>&1)
    local got; got=$(echo "$out" | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{", raw.find("Hex:"))
print(json.loads(raw[start:]).get("total", "<missing>")) if start != -1 else print("<no json>")
' 2>/dev/null)
    [ "$got" = "$expected" ] || { echo "$out"; fail "$label: ledger total is '$got', expected '$expected'"; }
    log "  ✓ $label: ledger total = $got"
}
assert_ledger_total 500 "after first deposit"

# ─── Step 9: a second deposit must accumulate ─────────────────────────────
log "Step 9: vault deposit 250 (must accumulate)..."
spel --idl "$VAULT_IDL" -p "$VAULT_BIN" deposit \
    --owner "$SIGNER" --log "$LOG_PDA" --ledger-program-id "$LEDGER_PID_HEX" --amount 250 \
    > "$WORK_DIR/deposit2.log" 2>&1 || { cat "$WORK_DIR/deposit2.log"; fail "deposit 250 did not confirm"; }
assert_ledger_total 750 "after second deposit"

# ─── Step 10: the vault's own per-owner PDA ───────────────────────────────
log "Step 10: checking the vault's per-owner PDA..."
VAULT_PDA=$(spel --idl "$VAULT_IDL" -p "$VAULT_BIN" pda vault_account --owner "$SIGNER_BARE" 2>/dev/null | tail -1)
[ -n "$VAULT_PDA" ] || fail "could not derive the per-owner vault PDA"
VOUT=$(spel --idl "$VAULT_IDL" -p "$VAULT_BIN" inspect "$VAULT_PDA" --type VaultAccount 2>&1)
echo "$VOUT" | grep -q '"balance": "750"' || { echo "$VOUT"; fail "vault balance is not 750"; }
log "  ✓ vault balance = 750 (its own PDA, mutated directly)"

log ""
log "🎉 CPI E2E PASSED"
log "   ledger total 0 -> 500 -> 750, written by ledger.record via ChainedCall"
log "   vault balance 750, written by vault.deposit directly"
log "   two programs, three PDAs, one cross-program call"
