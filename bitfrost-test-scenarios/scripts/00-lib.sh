#!/usr/bin/env bash
# Shared helpers for the bitfrost-test-scenarios scripts. Source, don't run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
[ -f .env ] && set -a && . ./.env && set +a

: "${HEIMDALL_SRC:=../../lantr/heimdall}"
: "${BINOCULAR_SRC:=../../lantr/binocular}"
: "${BITCOIN_RPC_USER:=bifrost}"
: "${BITCOIN_RPC_PASS:=bifrost}"

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
    if [ "${head#"$ref"}" = "$head" ] && [ "${ref#"$head"}" = "$ref" ]; then
      log "WARNING: $name checkout at $head, pinned $ref (update .env or the checkout)"
    fi
  done
}

btc() {
  docker compose exec -T bitcoind bitcoin-cli -regtest \
    -rpcuser="$BITCOIN_RPC_USER" -rpcpassword="$BITCOIN_RPC_PASS" "$@"
}

# Mine N blocks to the bench wallet (creates it on first use).
btc_mine() {
  local n="$1"
  btc loadwallet bench >/dev/null 2>&1 || btc createwallet bench >/dev/null 2>&1 || true
  btc -rpcwallet=bench generatetoaddress "$n" "$(btc -rpcwallet=bench getnewaddress)" >/dev/null
  log "mined $n regtest block(s), height now $(btc getblockcount)"
}

wait_healthy() {
  local svc="$1" tries="${2:-60}"
  log "waiting for $svc to be healthy..."
  for _ in $(seq "$tries"); do
    state=$(docker compose ps --format '{{.Health}}' "$svc" 2>/dev/null || true)
    [ "$state" = "healthy" ] && return 0
    sleep 2
  done
  die "$svc did not become healthy"
}

# Extract `PublishKeys: group_key = <hex>` from an SPO's logs (DKG success
# marker; identical across SPOs by construction — the assertion the run-dkz
# playbook did by eye).
spo_group_key() {
  docker compose logs "heimdall-spo$1" 2>/dev/null |
    sed -n 's/.*PublishKeys: group_key = \([0-9a-f]*\).*/\1/p' | tail -1
}
