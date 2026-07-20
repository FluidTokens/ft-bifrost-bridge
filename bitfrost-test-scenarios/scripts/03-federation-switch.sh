#!/usr/bin/env bash
# Scenario 3 — federation fallback: spend the treasury via the CSV
# timelock leaf with the federation key after the FROST path goes dark.
#
# This is the scenario that REQUIRES in-compose regtest (README): the
# federation leaf is gated by federation_csv_blocks (144 here) of relative
# timelock — mined in one RPC call on regtest, ~24h of wall clock anywhere
# else.
#
# Testable now (Bitcoin side): build + broadcast the script-path spend
# under y_fed and watch the oracle prove the spend.
# BLOCKED (plan N10b + N15): the on-chain federation-reset — treasury.ak's
# key-rotation-to-y_federation gated on a Binocular-proved CSV-leaf spend —
# is unimplemented; the witness walker it needs exists in binocular but is
# dead code until N15 revives it.
. "$(dirname "$0")/00-lib.sh"
check_pins

log "scenario 3: assumes scenario 1 completed (treasury under a FROST Y_51 exists)"

log "step 1: simulate the FROST group going dark"
# docker compose stop heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4

log "step 2: mine past the federation CSV window"
btc_mine 145 # federation_csv_blocks = 144 in the SPO configs, +1 margin

log "step 3: federation script-path spend of the treasury"
# TODO(wire): derive y_fed from the configs' y_fed_seed_hex, build the
# Taproot script-path spend of the treasury outpoint (witness: 3-item
# federation-leaf shape — see binocular BitcoinHelpers' documented 3-vs-4
# witness discriminator), broadcast via btc, mine 1.

log "step 4: oracle observes + proves the spend"
# TODO(wire): assert binocular's ChainState advances over the spend block
# and the proof bundle for the treasury outpoint spend verifies.

log "step 5 (BLOCKED on N10b): on-chain federation reset"
# When N10b lands: submit the treasury.ak federation-reset spend on Cardano
# (new key = y_federation) with the CSV-leaf evidence, and assert the
# datum's current_spos_frost_key rotated.
die "scenario scaffold: wire steps 3-4, step 5 blocked on N10b/N15"
