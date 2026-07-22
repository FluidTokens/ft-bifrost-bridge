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

# Epoch length in slots (= seconds at block-time 1). Short so stake activates in
# ~2 epochs of wall clock, but it MUST still contain a whole DKG ceremony —
# see check_dkg_pacing below for why 60 was too short.
DEVNET_EPOCH_SLOTS=${DEVNET_EPOCH_SLOTS:-180}

# Create + start the devnet detached (--start keeps the node running inside
# the exec session).
yaci_create_node() {
  log "creating yaci devnet (block-time 1s, epoch-length $DEVNET_EPOCH_SLOTS slots)..."
  docker compose exec -d yaci-devkit /app/yaci-cli.sh \
    create-node -o --block-time 1 --epoch-length "$DEVNET_EPOCH_SLOTS" --start
}

# The DKG schedule is epoch-scoped: the candidate set, the ban filter and the
# grid anchor (schedule_anchor_ms = epoch_start_ms) are all fixed at the epoch
# boundary. A ceremony that outlives its epoch is therefore anchored to a
# boundary the chain has already passed, and nodes re-entering after an abort
# capture DIFFERENT epochs — whose payload namespaces (epoch, threshold,
# attempt) then reject each other, wedging the cluster with
# "poseidon_commit mismatch". Observed 2026-07-22 with epoch 60s vs window 90s
# vs join wait 300s, i.e. a ceremony spanning five epochs.
check_dkg_pacing() {
  local cfg=config/heimdall-spo1.toml
  local -i window join_wait round2
  # sed, not `grep -oP`: -P is a GNU extension and this repo is also run on
  # macOS (see internal-docs references.md), where BSD grep rejects it — which
  # would kill every scenario at its first line.
  local key
  for key in dkg_window_secs dkg_join_wait_secs dkg_round2_offset_secs; do
    local v
    v=$(sed -n "s/^${key} *= *\([0-9][0-9]*\).*/\1/p" "$cfg" | head -1)
    [ -n "$v" ] || die "check_dkg_pacing: $key not found in $cfg"
    case "$key" in
    dkg_window_secs) window=$v ;;
    dkg_join_wait_secs) join_wait=$v ;;
    dkg_round2_offset_secs) round2=$v ;;
    esac
  done
  [ "$window" -le "$DEVNET_EPOCH_SLOTS" ] ||
    die "dkg_window_secs=$window exceeds the devnet epoch ($DEVNET_EPOCH_SLOTS s) — the ceremony grid would span epochs"
  [ $((join_wait + round2 + 20)) -le "$DEVNET_EPOCH_SLOTS" ] ||
    die "a ceremony (join_wait $join_wait + round2 $round2 + slack) does not fit in one $DEVNET_EPOCH_SLOTS s epoch"
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

# Prove a stake registration landed, using only what yaci-store actually serves.
#
# `/accounts/{addr}` CANNOT answer this on yaci-store: it returns byte-identical
# 200 payloads for a registered and an unregistered credential
# (stake_address/controlled_amount/withdrawable_amount/pool_id, all zeros, no
# Blockfrost `active` field), and `/txs/{hash}` carries no certificates. Verified
# 2026-07-22 against both a freshly-registered and a never-registered script
# credential.
#
# So assert the LEDGER EFFECT instead, which is stronger anyway: a deposit-bearing
# certificate is the only thing that removes value from a transaction beyond its
# fee, so `inputs - outputs - fee` must equal the deposit exactly. That single
# equality proves the certificate was accepted AND that the tx balanced to the
# lovelace — the part heimdall has to hand-correct, because whisky's change
# balancer drops the deposit for legacy StakeRegistration.
assert_tx_deposit() {
  local tx="$1" want="$2" got
  got=$(curl -sf "$STORE_API/txs/$tx" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ins = sum(int(a["quantity"])
          for i in d["inputs"] for a in i["amount"] if a["unit"] == "lovelace")
print(ins - int(d["total_output"]) - int(d["fees"]))
') || die "could not read tx $tx from $STORE_API"
  [ "$got" = "$want" ] ||
    die "tx $tx removed $got lovelace beyond its fee, expected exactly $want of deposits"
  log "  deposit verified on chain: $got lovelace (inputs − outputs − fee)"
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

# Wait for a regex to appear in a service's logs, or fail. `docker compose logs`
# is re-read each poll rather than followed, so a line emitted before this call
# still counts — the scenarios check for things that may already have happened.
wait_log() {
  local svc="$1" pattern="$2" secs="${3:-300}" deadline=$((SECONDS + ${3:-300}))
  while [ $SECONDS -lt $deadline ]; do
    docker compose logs "$svc" 2>/dev/null | grep -qE "$pattern" && return 0
    sleep 5
  done
  return 1
}

# `PublishKeys: group_key = <hex>` from an SPO's logs — the DKG success
# marker, identical across SPOs by construction.
spo_group_key() {
  docker compose logs "heimdall-spo$1" 2>/dev/null |
    sed -n 's/.*PublishKeys: group_key = \([0-9a-f]*\).*/\1/p' | tail -1
}
