#!/usr/bin/env bash
# Shared helpers for the bitfrost-test-scenarios scripts. Source, don't run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
[ -f .env ] && set -a && . ./.env && set +a

: "${HEIMDALL_SRC:=../../../lantr/heimdall}"
: "${BINOCULAR_SRC:=../../../lantr/binocular}"
: "${BITCOIN_RPC_USER:=bifrost}"
: "${BITCOIN_RPC_PASS:=bifrost}"
# Ban schedule. Rendered into BOTH the SPO configs and the
# deploy-spo-bans-ref args — spo_bans is parameterized by these, so any drift
# between the two changes the script hash and the deployed ref stops matching
# what heimdall recomputes at run time. Devnet-short on purpose.
: "${BAN_BASE_DURATION_MS:=600000}"        # 10 min first ban (doubles per fault)
: "${BAN_MAX_FAULTS_BEFORE_PERMANENT:=3}"
: "${BAN_MAX_VALIDITY_WINDOW_MS:=3600000}" # 1 h cap on an ApplyBan validity interval

STORE_API="http://localhost:8080/api/v1"
ADMIN_API="http://localhost:10000/local-cluster/api"
LOGS="$HERE/data/logs"
mkdir -p "$LOGS" data/generated

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# Version pinning (README §Version pinning): warn — never fail — when a
# source checkout drifts from its pinned ref, so ad-hoc runs stay possible
# but an assertion failure is never silently blamed on the wrong code.
check_pins() {
  for pair in "heimdall:$HEIMDALL_SRC:${HEIMDALL_REF:-}" "binocular:$BINOCULAR_SRC:${BINOCULAR_REF:-}"; do
    IFS=: read -r name src ref <<<"$pair"
    [ -n "$ref" ] || continue
    local head
    head=$(git -C "$src" rev-parse --short HEAD 2>/dev/null) || continue
    case "$head" in "$ref"*) ;; *) log "WARNING: $name checkout at $head, pinned $ref (update .env or the checkout)" ;; esac
  done
}

# ── bitcoind ─────────────────────────────────────────────────────────────
btc() {
  docker compose exec -T bitcoind bitcoin-cli -regtest \
    -rpcuser="$BITCOIN_RPC_USER" -rpcpassword="$BITCOIN_RPC_PASS" "$@"
}

btc_mine() {
  local n="$1"
  btc loadwallet bench >/dev/null 2>&1 || btc createwallet bench >/dev/null 2>&1 || true
  btc -rpcwallet=bench generatetoaddress "$n" "$(btc -rpcwallet=bench getnewaddress)" >/dev/null
  log "mined $n regtest block(s), height now $(btc getblockcount)"
}

# ── yaci-devkit ──────────────────────────────────────────────────────────
# One-shot CLI command inside the devkit container (Spring Shell runs args
# non-interactively) — same invocation as yaci-devkit's own scripts.
yaci_cli() { docker compose exec -T yaci-devkit /app/yaci-cli.sh "$@"; }

# Create + start the devnet detached (--start keeps the node running inside
# the exec session). Short epochs: stake activates in ~2 min.
yaci_create_node() {
  log "creating yaci devnet (block-time 1s, epoch-length 60 slots)..."
  docker compose exec -d yaci-devkit /app/yaci-cli.sh \
    create-node -o --block-time 1 --epoch-length 60 --start
}

wait_store_api() {
  log "waiting for yaci-store API..."
  for _ in $(seq 120); do
    curl -sf "$STORE_API/blocks/latest" >/dev/null 2>&1 && { log "yaci-store is up"; return 0; }
    sleep 2
  done
  die "yaci-store API did not come up on $STORE_API"
}

# Faucet: POST /local-cluster/api/addresses/topup {address, adaAmount}
# (AddressController in yaci-devkit).
yaci_topup() {
  local addr="$1" ada="$2"
  curl -sf -X POST "$ADMIN_API/addresses/topup" \
    -H 'Content-Type: application/json' \
    -d "{\"address\": \"$addr\", \"adaAmount\": $ada}" >/dev/null ||
    die "topup of $addr failed (admin API $ADMIN_API)"
  log "topped up $addr with $ada tADA"
}

# First UTxO of an address as TX:IDX (store API, blockfrost field names).
yaci_first_utxo() {
  curl -sf "$STORE_API/addresses/$1/utxos" |
    python3 -c 'import json,sys; u=json.load(sys.stdin)[0]; print(u["tx_hash"], u["output_index"], sep=":")'
}

# Block until an address shows at least N UTxOs (faucet topups are separate
# txs and land asynchronously).
wait_utxo_count() {
  local addr="$1" want="$2" n
  for _ in $(seq 60); do
    n=$(curl -sf "$STORE_API/addresses/$addr/utxos" |
      python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
    [ "$n" -ge "$want" ] && {
      log "  wallet has $n UTxOs"
      return 0
    }
    sleep 2
  done
  die "address $addr never reached $want UTxOs (saw ${n:-0})"
}

# First UTxO of an address that is NOT one of the given refs. One-shot
# bootstraps each burn a distinct outref (the minting policy is parameterized
# by it), so the ban-list root cannot reuse the registry's.
yaci_utxo_excluding() {
  local addr="$1"
  shift
  curl -sf "$STORE_API/addresses/$addr/utxos" |
    python3 -c '
import json, sys
excluded = set(sys.argv[1:])
for u in json.load(sys.stdin):
    ref = "%s:%s" % (u["tx_hash"], u["output_index"])
    if ref not in excluded:
        print(ref)
        break
' "$@"
}

# Poll for a tx WITHOUT dying — returns 1 if it never appears. Callers that must
# collect diagnostics before failing (a scenario that tees a report on its way
# out) need the non-fatal form: dying here would destroy the very evidence the
# failure is about.
try_cardano_tx() {
  local tx="$1" tries="${2:-60}"
  for _ in $(seq "$tries"); do
    curl -sf "$STORE_API/txs/$tx" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Fatal wrapper — the common case, for bootstrap steps with nothing to collect.
wait_cardano_tx() {
  try_cardano_tx "$1" || die "cardano tx $1 not confirmed"
}

# ── heimdall (dockerized one-shots) ──────────────────────────────────────
# Run a heimdall subcommand in a throwaway spo1-shaped container (any config
# works for wallet-level commands; per-SPO state only matters for `demo`).
hd() { docker compose run --rm --no-deps -T heimdall-spo1 "$@"; }
hd_pool() { docker compose run --rm --no-deps -T --entrypoint register_pool heimdall-spo1 "$@"; }

# Extract the first regex capture from a teed log, or die pointing at it.
extract() {
  local file="$1" pattern="$2" out
  out=$(grep -oE "$pattern" "$file" | head -1) || true
  [ -n "$out" ] || die "pattern '$pattern' not found in $file — inspect it and fix the extraction"
  printf '%s\n' "$out"
}

# `PublishKeys: group_key = <hex>` from an SPO's logs — the DKG success
# marker, identical across SPOs by construction.
spo_group_key() {
  docker compose logs "heimdall-spo$1" 2>/dev/null |
    sed -n 's/.*PublishKeys: group_key = \([0-9a-f]*\).*/\1/p' | tail -1
}
