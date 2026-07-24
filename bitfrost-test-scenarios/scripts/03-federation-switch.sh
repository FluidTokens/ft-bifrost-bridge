#!/usr/bin/env bash
# Scenario 3 — federation fallback: when the FROST group can't sign (DKG never
# completes / all SPOs dark), the FEDERATION spends the treasury via its Taproot
# CSV-timelock script leaf (`<csv> OP_CSV OP_DROP <y_fed> OP_CHECKSIG`) instead of
# the Y_51 key path. This is the scenario that REQUIRES in-compose regtest: the
# leaf is gated by federation_csv_blocks (144 here) of RELATIVE timelock — mined
# in one RPC call on regtest, ~24h of wall clock anywhere else.
#
# Phase A (Bitcoin side — DONE, N23): build + broadcast the y_fed CSV-leaf
# script-path spend of the treasury and assert Bitcoin accepts it.
# Phase B/C (BLOCKED on N15 + N10b): binocular proves the leaf spend (N15) and
# treasury.ak rotates current_spos_frost_key -> y_federation (N10b). See the plan
# §Update 2026-07-23 (scenario 3).
#
# Requires: the heimdall image built from HEIMDALL_SRC INCLUDING N23
# (`federation-spend` subcommand) — scenario 1's step 0 rebuilds it. The bench
# heimdall config's bitcoin.fee_rate_sat_per_vb must be >= 2 (a 1 sat/vB
# federation spend lands just under the min relay fee for its ~113 vB size).
. "$(dirname "$0")/00-lib.sh"
check_pins

log "scenario 3: assumes scenario 1 completed (a funded treasury exists on regtest)"

log "step 1: the FROST group goes dark (stop all SPOs — no Y_51 signer)"
docker compose stop heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4 >/dev/null 2>&1 || true

log "step 2: locate the current treasury UTxO on Bitcoin"
# The treasury is a P2TR at Taproot(Y_51, y_fed-leaf, csv); at bootstrap Y_51 =
# y_fed, so `bootstrap-treasury` prints that same address. Scan the UTXO set for
# its single unspent output.
TREASURY_ADDR=$(hd bootstrap-treasury "${HD_CFG[@]}" 2>/dev/null | tr -d '\r' | tail -1)
case "$TREASURY_ADDR" in bcrt1p*) ;; *) die "unexpected treasury address '$TREASURY_ADDR'"; esac
SCAN=$(btc scantxoutset start "[\"addr($TREASURY_ADDR)\"]")
read -r TX VOUT AMT <<<"$(echo "$SCAN" | python3 -c '
import json,sys
u=json.load(sys.stdin).get("unspents",[])
if not u: raise SystemExit("no unspent treasury UTxO at the address — run scenario 1 first")
print(u[0]["txid"], u[0]["vout"], round(u[0]["amount"]*1e8))')"
[ -n "${TX:-}" ] || die "no treasury UTxO found at $TREASURY_ADDR"
log "  treasury UTxO: $TX:$VOUT ($AMT sat) at $TREASURY_ADDR"

log "step 3: mine past the federation CSV window (relative timelock)"
CSV=$(sed -n 's/^federation_csv_blocks *= *\([0-9]*\).*/\1/p' config/heimdall-spo1.toml | head -1)
CSV=${CSV:-144}
# The treasury UTxO must be > CSV blocks deep for OP_CSV to pass.
btc_mine $((CSV + 1))

log "step 4: federation script-path spend of the treasury (y_fed CSV leaf)"
sp_log="$LOGS/scenario3-fed-spend.log"
hd federation-spend "${HD_CFG[@]}" --outpoint "$TX:$VOUT" --amount-sat "$AMT" --broadcast 2>&1 |
  tee "$sp_log" >/dev/null
# Check acceptance first, so a rejection (e.g. min-relay-fee: bump
# bitcoin.fee_rate_sat_per_vb) surfaces the node's own words, not a bare
# extraction failure.
grep -q 'broadcast OK' "$sp_log" || { cat "$sp_log"; die "federation spend was not accepted by bitcoind — see $sp_log"; }
SPEND_TX=$(extract "$sp_log" 'federation-spend txid : [0-9a-f]{64}' | grep -oE '[0-9a-f]{64}$')
btc_mine 1

# Assert Bitcoin accepted the emergency path: the input spends the treasury via
# the 3-item script-path witness [sig, leaf, control block] with nSequence = CSV.
WITN=$(btc getrawtransaction "$SPEND_TX" true | python3 -c "
import json,sys
d=json.load(sys.stdin); vin=d['vin'][0]
assert vin['txid']=='$TX' and vin['vout']==$VOUT, 'spends the wrong outpoint'
w=vin.get('txinwitness',[])
print(len(w), vin['sequence'])")
log "  federation spend $SPEND_TX confirmed; [witness items, nSequence] = [$WITN] (want '3 $CSV')"
[ "$WITN" = "3 $CSV" ] || die "unexpected federation witness/sequence: $WITN"
log "  ✓ Bitcoin accepted the federation CSV-leaf spend of the treasury"

log "step 5 (BLOCKED on N15): binocular proves the federation-leaf spend"
# TODO(N15): revive binocular's witness walker (BitcoinHelpers.scala:459-554) to
# classify $SPEND_TX's input as a federation-LEAF (not key-path) spend, and emit
# the proof bundle. Assert the watchtower's ChainState advances over the spend
# block and the bundle for $SPEND_TX:0 verifies.

log "step 6 (BLOCKED on N10b): on-chain federation reset"
# TODO(N10b): submit the treasury.ak federation-reset spend on Cardano gated on
# N15's CSV-leaf proof (new key = y_federation, tag 'bifrost-update-y-reset'), and
# assert the datum's current_spos_frost_key rotated to y_federation.

log "OK (Phase A / Bitcoin side): treasury spent via the federation CSV leaf ($SPEND_TX)."
log "    On-chain reset (steps 5-6) blocked on N15 + N10b — see the plan."
