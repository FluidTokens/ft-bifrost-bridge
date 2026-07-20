#!/usr/bin/env bash
# Scenario 1 — bootstrap the bridge and run a full 4-SPO DKG.
#
# End state asserted: all four heimdall instances derive the IDENTICAL
# group key (Y_51) and treasury address — the deterministic-reconstruction
# claim of the spec, previously checked by eye in the run-dkz playbook.
#
# Steps marked TODO(wire) are the ones to flesh out first; the skeleton
# runs the infra + assertions around them.
. "$(dirname "$0")/00-lib.sh"
check_pins

log "step 0: infra up"
docker compose up -d bitcoind yaci-devkit
wait_healthy bitcoind
wait_healthy yaci-devkit
btc_mine 101 # mature a coinbase for funding

log "step 1: bifrost identity keys for the 4 SPOs"
mkdir -p keys
for i in 1 2 3 4; do
  key="keys/spo$i-bifrost.skey"
  if [ ! -f "$key" ]; then
    (umask 177 && openssl rand -hex 32 >"$key")
    log "  generated $key"
  fi
done

log "step 2: genesis treasury outpoint on Bitcoin (funded pre-mint — spec §External inputs)"
# TODO(wire): create + fund the genesis treasury output under the interim
# federation key (y_fed from the SPO configs' seed), record its outpoint for
# the deploy step. On regtest this is a bench-wallet send + 1 block.

log "step 3: deploy the bridge on Cardano (binocular single-tx bootstrap)"
# TODO(wire): drive binocular's deploy-bridge command against yaci-devkit
# with /contracts/plutus.json (mounted from ../onchain — the CI-verified
# blueprint), update_auth = the bench owner key, then init + start the
# header oracle:
#   docker compose run --rm bitfrost <deploy-bridge ...>
#   docker compose run --rm bitfrost <init-oracle ...>

log "step 4: register the 4 SPOs (heimdall R2 registration)"
# TODO(wire): per SPO, run the heimdall registration command with its
# bifrost key, container URL http://heimdall-spoN:1850N, against yaci.
# yaci-devkit pools carry no stake — use heimdall's demo unstaked-pool
# escape hatch (cardano.demo_exclude_unstaked / min_stake=0 in the Config).

log "step 5: start the 4 SPOs and run the DKG"
# The N21 health gate + window grid make start order irrelevant here —
# that property has its own in-repo test (heimdall
# full_cycle_3_of_3_staggered_start_converges); this scenario just starts
# them all and lets the gate align them.
# TODO(wire): the exact heimdall run subcommand + flags:
# HEIMDALL_CMD="<run> --config /etc/heimdall/heimdall.toml --index $i --base-port 18500" \
#   docker compose up -d heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4

log "step 6: assert — identical group key on all 4 SPOs"
deadline=$((SECONDS + 600))
key1=""
while [ $SECONDS -lt $deadline ]; do
  key1=$(spo_group_key 1)
  [ -n "$key1" ] && break
  sleep 5
done
[ -n "$key1" ] || die "spo1 never published a group key (DKG did not complete)"
for i in 2 3 4; do
  k=$(spo_group_key "$i")
  [ "$k" = "$key1" ] || die "spo$i group key $k != spo1 $key1 — determinism broken"
done
log "OK: all 4 SPOs derived Y_51 = $key1"
