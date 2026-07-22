#!/usr/bin/env bash
# Scenario 1 — bootstrap the bridge and run a full 4-SPO registry-driven DKG.
#
# This automates the "fully-coherent DKG on a local yaci devnet" path of
# heimdall's run-dkz playbook (WI-024): real stake pools on a short-epoch
# devnet, the on-chain SPO registry bootstrap, register-spo ×4, then the
# ceremony off the REAL stake-weighted roster. End state asserted: all four
# instances derive the IDENTICAL group key Y_51 — the spec's deterministic-
# reconstruction claim, previously checked by eye.
#
# Every one-shot's output is teed to data/logs/ — on an extraction failure,
# read the log and fix the pattern in one place.
. "$(dirname "$0")/00-lib.sh"
check_pins

HD_CFG=(--config /etc/heimdall/heimdall.toml)
BLUEPRINT=(--blueprint /contracts/plutus.json)
# x-only pubkey of bitcoin.y_fed_seed_hex (heimdall default fe×32) — a pure
# function of the seed; recorded in the 2026-06-11 register-spo run.
Y_FED_XONLY=0ce472ae5d8993e7609ee4ef33b344f6b8499a1259374bdf528f82240985bf03

log "step 0: infra up (bitcoind + yaci devnet)"
# Rebuild the heimdall image from HEIMDALL_SRC first. `docker compose up`
# reuses whatever image already exists, so without this a stale binary runs
# silently against a fresh checkout — check_pins only warns about the SOURCE
# ref, which says nothing about what is baked into the image. Subcommands
# added since the last build fail as clap usage errors (exit 2), which is a
# confusing way to discover the image is old. Cached when nothing changed.
log "  building heimdall image from $HEIMDALL_SRC (cached when unchanged)"
docker compose build heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4
docker compose up -d bitcoind yaci-devkit
for _ in $(seq 60); do
  [ "$(docker compose ps --format '{{.Health}}' bitcoind)" = "healthy" ] && break
  sleep 2
done
btc_mine 101 # mature a coinbase for funding
curl -sf "$STORE_API/blocks/latest" >/dev/null 2>&1 || yaci_create_node
wait_store_api

# Render the per-SPO configs. Must run BEFORE any `docker compose run
# heimdall-*` — the services mount data/generated/heimdall-spoN.toml, and a
# missing bind source becomes a root-owned DIRECTORY. Early renders keep the
# @...@ placeholders (wallet-level commands never read those keys); step 8
# re-renders with the minted registry ids.
# The ban-flow ids arrive in waves — policy hashes from a wallet-free dry run,
# ref UTxOs only once their deploy txs land — so each falls back to its own
# placeholder and a later re-render fills it in. Re-rendering is idempotent: it
# always starts from config/, never from the previously generated file.
render_configs() {
  local boot="${1:-@REGISTRY_BOOTSTRAP@}" k1="${2:-@TREASURY_INFO_ASSET_NAME@}"
  for i in 1 2 3 4; do
    sed -e "s|@REGISTRY_BOOTSTRAP@|$boot|" \
      -e "s|@TREASURY_INFO_ASSET_NAME@|$k1|" \
      -e "s|@BAN_BOOTSTRAP@|${BAN_BOOTSTRAP:-@BAN_BOOTSTRAP@}|" \
      -e "s|@FAULT_POLICY_ROUND1@|${FAULT_POLICY_ROUND1:-@FAULT_POLICY_ROUND1@}|" \
      -e "s|@FAULT_POLICY_ROUND2@|${FAULT_POLICY_ROUND2:-@FAULT_POLICY_ROUND2@}|" \
      -e "s|@FAULT_POLICY_EQUIVOCATION@|${FAULT_POLICY_EQUIVOCATION:-@FAULT_POLICY_EQUIVOCATION@}|" \
      -e "s|@SPO_BANS_REF@|${SPO_BANS_REF:-@SPO_BANS_REF@}|" \
      -e "s|@FAULT_REF_ROUND1@|${FAULT_REF_ROUND1:-@FAULT_REF_ROUND1@}|" \
      -e "s|@FAULT_REF_ROUND2@|${FAULT_REF_ROUND2:-@FAULT_REF_ROUND2@}|" \
      -e "s|@FAULT_REF_EQUIVOCATION@|${FAULT_REF_EQUIVOCATION:-@FAULT_REF_EQUIVOCATION@}|" \
      -e "s|@BAN_BASE_DURATION_MS@|$BAN_BASE_DURATION_MS|" \
      -e "s|@BAN_MAX_FAULTS_BEFORE_PERMANENT@|$BAN_MAX_FAULTS_BEFORE_PERMANENT|" \
      -e "s|@BAN_MAX_VALIDITY_WINDOW_MS@|$BAN_MAX_VALIDITY_WINDOW_MS|" \
      config/heimdall-spo$i.toml >data/generated/heimdall-spo$i.toml
  done
}

log "step 1: bifrost identity keys (fixture-compatible seeds 11..0N) + configs"
render_configs
mkdir -p keys
for i in 1 2 3 4; do
  key="keys/spo$i-bifrost.skey"
  # Same identity scheme as the run-dkz playbook: 11×31 ‖ 0N.
  [ -f "$key" ] || (umask 177 && printf '%s0%s' "$(printf '11%.0s' $(seq 31))" "$i" >"$key")
done

log "step 2: fund the heimdall fee wallet from the devnet faucet"
wallet_log="$LOGS/wallet-address.log"
hd wallet-address "${HD_CFG[@]}" 2>&1 | tee "$wallet_log" >/dev/null
WALLET_ADDR=$(extract "$wallet_log" 'addr_test1[a-z0-9]+')
# SEVERAL topups, not one: each is its own tx, so each adds a distinct UTxO.
# One-shot bootstraps consume an outref apiece (registry, then the ban list),
# and every builder needs at least one more UTxO left over to pay fees from —
# a single faucet UTxO gets claimed as the bootstrap outref and the next
# command dies with "no spendable UTxOs besides the registry bootstrap outref".
for _ in 1 2 3 4; do yaci_topup "$WALLET_ADDR" 5000; done
wait_utxo_count "$WALLET_ADDR" 4

log "step 3: genesis treasury outpoint on Bitcoin regtest (spec §External inputs)"
TREASURY_ADDR=$(hd bootstrap-treasury "${HD_CFG[@]}" 2>/dev/null | tr -d '\r' | tail -1)
case "$TREASURY_ADDR" in bcrt1p*) ;; *) die "unexpected treasury address '$TREASURY_ADDR' (want regtest P2TR bcrt1p…)" ;; esac
TREASURY_SPK=$(btc validateaddress "$TREASURY_ADDR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["scriptPubKey"])')
FUND_TX=$(btc -rpcwallet=bench sendtoaddress "$TREASURY_ADDR" 1.0)
btc_mine 1
TREASURY_VOUT=$(btc getrawtransaction "$FUND_TX" true | python3 -c "
import json,sys
tx=json.load(sys.stdin)
print(next(o['n'] for o in tx['vout'] if o['scriptPubKey'].get('address')=='$TREASURY_ADDR'))")
log "  genesis treasury: $FUND_TX:$TREASURY_VOUT ($TREASURY_ADDR)"

# Active stake of a pool at the CURRENT devnet epoch — yaci-store has no
# blockfrost /pools/{id}; the per-epoch route is what heimdall's
# stake_source = "yaci_store" reads too.
pool_active_stake() {
  local epoch
  epoch=$(curl -sf "$STORE_API/epochs/latest" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["epoch"])') || { echo 0; return; }
  curl -sf "$STORE_API/epochs/$epoch/pools/$1/stake" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("active_stake") or 0)' 2>/dev/null || echo 0
}

log "step 4: register 4 stake pools (equal 20 ADA self-delegation)"
declare -a POOL_IDS
for i in 1 2 3 4; do
  plog="$LOGS/register-pool-$i.log"
  # Idempotent re-runs: a prior registration whose pool already shows active
  # stake is not re-submitted.
  if [ -f "$plog" ]; then
    POOL_IDS[$i]=$(extract "$plog" 'pool1[a-z0-9]+')
    if [ "$(pool_active_stake "${POOL_IDS[$i]}")" != "0" ]; then
      log "  pool $i: ${POOL_IDS[$i]} (already registered + stake-active)"
      continue
    fi
  fi
  cold=$(printf "2$i%.0s" $(seq 32))
  hd_pool "${HD_CFG[@]}" --cold-skey "$cold" \
    --delegated-stake-lovelace 20000000 --submit 2>&1 | tee "$plog" >/dev/null
  POOL_IDS[$i]=$(extract "$plog" 'pool1[a-z0-9]+')
  wait_cardano_tx "$(extract "$plog" 'tx_hash=[0-9a-f]+' | cut -d= -f2)"
  log "  pool $i: ${POOL_IDS[$i]}"
done

log "step 5: wait for stake activation (~2 short devnet epochs)"
for i in 1 2 3 4; do
  for _ in $(seq 60); do
    [ "$(pool_active_stake "${POOL_IDS[$i]}")" != "0" ] && break
    sleep 10
  done
  [ "$(pool_active_stake "${POOL_IDS[$i]}")" != "0" ] ||
    die "pool ${POOL_IDS[$i]} never became stake-active — check $STORE_API/epochs/latest and .../pools/${POOL_IDS[$i]}/stake"
done
log "  all 4 pools stake-active"

log "step 6: bridge registry bootstrap on the devnet"
BOOT_REF=$(yaci_first_utxo "$WALLET_ADDR")
log "  one-shot outref: $BOOT_REF"
ti_log="$LOGS/bootstrap-treasury-info.log"
hd bootstrap-treasury-info "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
  --registry-bootstrap "$BOOT_REF" \
  --btc-treasury-spk "$TREASURY_SPK" \
  --btc-outpoint "$FUND_TX:$TREASURY_VOUT" \
  --frost-key "$Y_FED_XONLY" --submit 2>&1 | tee "$ti_log" >/dev/null
K1_NAME=$(extract "$ti_log" 'treasury NFT:\s+[0-9a-f]+\.[0-9a-f]+' | sed 's/.*\.//')
wait_cardano_tx "$(extract "$ti_log" 'tx_hash=[0-9a-f]+' | cut -d= -f2)"

reg_log="$LOGS/bootstrap-registry.log"
hd bootstrap-registry "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
  --registry-bootstrap "$BOOT_REF" --submit 2>&1 | tee "$reg_log" >/dev/null
wait_cardano_tx "$(extract "$reg_log" 'tx_hash=[0-9a-f]+' | cut -d= -f2)"

ref_log="$LOGS/deploy-registry-ref.log"
hd deploy-registry-ref "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
  --registry-bootstrap "$BOOT_REF" --submit 2>&1 | tee "$ref_log" >/dev/null
REGISTRY_REF=$(extract "$ref_log" 'registry ref UTxO:\s+[0-9a-f]+:[0-9]+' | grep -oE '[0-9a-f]+:[0-9]+$')
wait_cardano_tx "${REGISTRY_REF%%:*}"
log "  registry_bootstrap=$BOOT_REF K1=$K1_NAME registry_ref=$REGISTRY_REF"

log "step 6b: DKG fault verifiers + SPO ban list (scenario 2 needs these)"
# Order is forced by a dependency cycle: `bootstrap-ban-list` parameterizes
# spo_bans from the CONFIG (BanPolicyParams::from_config), so the three fault
# policy ids must already be rendered when it runs — but they are pure
# functions of the blueprint + registry bootstrap, so a WALLET-FREE dry run
# yields them without any tx. Hence: learn policies → render → mint the root →
# deploy the refs → re-render with the ref outrefs.
for kind in round1 round2 equivocation; do
  fp_log="$LOGS/fault-policy-$kind.log"
  hd deploy-fault-ref "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
    --kind "$kind" --registry-bootstrap "$BOOT_REF" 2>&1 | tee "$fp_log" >/dev/null
  policy=$(extract "$fp_log" "fault_verifier_$kind policy id:\s+[0-9a-f]{56}" | grep -oE '[0-9a-f]{56}$')
  case "$kind" in
  round1) FAULT_POLICY_ROUND1="$policy" ;;
  round2) FAULT_POLICY_ROUND2="$policy" ;;
  equivocation) FAULT_POLICY_EQUIVOCATION="$policy" ;;
  esac
  log "  fault_verifier_$kind policy = $policy"
done

# A one-shot outref of its own — the registry already burned BOOT_REF, and the
# ban-list minting policy is parameterized by the outref it consumes.
BAN_BOOTSTRAP=$(yaci_utxo_excluding "$WALLET_ADDR" "$BOOT_REF")
[ -n "$BAN_BOOTSTRAP" ] || die "no spare wallet UTxO for the ban-list one-shot — top up $WALLET_ADDR"
log "  ban one-shot outref: $BAN_BOOTSTRAP"
render_configs "$BOOT_REF" "$K1_NAME"

bl_log="$LOGS/bootstrap-ban-list.log"
hd bootstrap-ban-list "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
  --registry-bootstrap "$BOOT_REF" --ban-bootstrap "$BAN_BOOTSTRAP" \
  --submit 2>&1 | tee "$bl_log" >/dev/null
wait_cardano_tx "$(extract "$bl_log" 'tx_hash=[0-9a-f]+' | cut -d= -f2)"

for kind in round1 round2 equivocation; do
  fr_log="$LOGS/deploy-fault-ref-$kind.log"
  hd deploy-fault-ref "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
    --kind "$kind" --registry-bootstrap "$BOOT_REF" --submit 2>&1 | tee "$fr_log" >/dev/null
  ref=$(extract "$fr_log" 'fault-verifier ref UTxO:\s+[0-9a-f]+:[0-9]+' | grep -oE '[0-9a-f]+:[0-9]+$')
  wait_cardano_tx "${ref%%:*}"
  case "$kind" in
  round1) FAULT_REF_ROUND1="$ref" ;;
  round2) FAULT_REF_ROUND2="$ref" ;;
  equivocation) FAULT_REF_EQUIVOCATION="$ref" ;;
  esac
  log "  fault_verifier_${kind}_ref = $ref"
done

sb_log="$LOGS/deploy-spo-bans-ref.log"
hd deploy-spo-bans-ref "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
  --registry-bootstrap "$BOOT_REF" --ban-bootstrap "$BAN_BOOTSTRAP" \
  --base-ban-duration-ms "$BAN_BASE_DURATION_MS" \
  --max-faults-before-permanent "$BAN_MAX_FAULTS_BEFORE_PERMANENT" \
  --max-validity-window-ms "$BAN_MAX_VALIDITY_WINDOW_MS" \
  --submit 2>&1 | tee "$sb_log" >/dev/null
SPO_BANS_REF=$(extract "$sb_log" 'spo_bans ref UTxO:\s+[0-9a-f]+:[0-9]+' | grep -oE '[0-9a-f]+:[0-9]+$')
wait_cardano_tx "${SPO_BANS_REF%%:*}"
log "  spo_bans_ref = $SPO_BANS_REF (policy $(extract "$sb_log" 'ban-list policy\):\s+[0-9a-f]{56}' | grep -oE '[0-9a-f]{56}$'))"

log "step 6c: register the spo_bans withdraw credential (scenario 2's ApplyBan needs it)"
# ApplyBan authorizes via withdraw-zero, and Conway only admits a withdrawal
# whose reward account is REGISTERED. Nothing above registers one, which is what
# stopped the 2026-07-22 live run dead at ApplyBan with
#   ConwayCertsFailure (WithdrawalsNotInRewardsCERTS ... ScriptHashObj 9dbace5d)
# It cannot be folded into the ApplyBan tx: certificates validate against the
# PRE-transaction ledger state, so the withdrawal would still see an
# unregistered account.
#
# Placed at the END of 6b for a resource reason, not a dependency one: the
# certificate only needs the spo_bans HASH, final since the render at the top of
# this step. But by now bootstrap-ban-list has consumed BAN_BOOTSTRAP, so this
# tx can no longer be handed the one-shot outref that parameterizes the very
# script it registers. (init-scripts also filters both bootstrap outrefs out of
# its own coin selection — belt and braces, since ordering here is convention.)
IS_ARGS=(
  --registry-bootstrap "$BOOT_REF" --ban-bootstrap "$BAN_BOOTSTRAP"
  --base-ban-duration-ms "$BAN_BASE_DURATION_MS"
  --max-faults-before-permanent "$BAN_MAX_FAULTS_BEFORE_PERMANENT"
  --max-validity-window-ms "$BAN_MAX_VALIDITY_WINDOW_MS"
)
is_log="$LOGS/init-scripts.log"
hd init-scripts "${HD_CFG[@]}" "${BLUEPRINT[@]}" "${IS_ARGS[@]}" \
  --submit 2>&1 | tee "$is_log" >/dev/null
if grep -q 'submitted init-scripts: tx_hash=' "$is_log"; then
  wait_cardano_tx "$(extract "$is_log" 'submitted init-scripts: tx_hash=[0-9a-f]+' | cut -d= -f2)"
elif grep -q 'already registered' "$is_log"; then
  log "  credentials were already registered — re-run, nothing submitted"
else
  die "init-scripts neither submitted nor reported already-registered — see $is_log"
fi

# Assert the REGISTRATION, not the submission. The M4 post-mortem's fourth
# defect was a false green from asserting on a log line emitted before the tx
# was accepted; the same trap is open here, and a silently-skipped row would
# sail through a submission-only check. The dry run re-reads chain state, so
# this is the chain talking, not heimdall.
verify_log="$LOGS/init-scripts-verify.log"
hd init-scripts "${HD_CFG[@]}" "${BLUEPRINT[@]}" "${IS_ARGS[@]}" 2>&1 |
  tee "$verify_log" >/dev/null
grep -qE '\[registered\]' "$verify_log" ||
  die "spo_bans reward account is not registered after init-scripts — see $verify_log"
! grep -qE '\[(NOT registered|unknown)' "$verify_log" ||
  die "init-scripts left a credential unregistered or unverifiable — see $verify_log"
log "  spo_bans reward account registered: $(extract "$verify_log" 'reward=stake_test1[a-z0-9]+' | cut -d= -f2)"

log "step 7: register-spo ×4 (serialized — each spends the registry anchor)"
for i in 1 2 3 4; do
  cold=$(printf "2$i%.0s" $(seq 32))
  slog="$LOGS/register-spo-$i.log"
  hd register-spo "${HD_CFG[@]}" "${BLUEPRINT[@]}" \
    --registry-bootstrap "$BOOT_REF" \
    --treasury-nft-name "$K1_NAME" \
    --registry-ref "$REGISTRY_REF" \
    --cold-skey "$cold" \
    --bifrost-skey "$(cat keys/spo$i-bifrost.skey)" \
    --bifrost-url "http://heimdall-spo$i:1850$i" \
    --submit 2>&1 | tee "$slog" >/dev/null
  wait_cardano_tx "$(extract "$slog" 'tx_hash=[0-9a-f]+' | cut -d= -f2)"
  log "  spo$i registered"
done

log "step 8: on-chain roster check"
roster_log="$LOGS/show-roster.log"
# show-roster needs the registry ids — re-render with the real values.
render_configs "$BOOT_REF" "$K1_NAME"
hd show-roster "${HD_CFG[@]}" 2>&1 | tee "$roster_log" >/dev/null || true
n=$(grep -cE '^\s+pool [0-9a-f]+ \(pool1' "$roster_log" || true)
[ "$n" = "4" ] || die "roster shows $n participants (want 4) — see $roster_log"

log "step 9: start the 4 SPOs — health gate + window grid align them, then DKG"
docker compose up -d heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4

log "step 10: assert — identical group key on all 4 SPOs"
deadline=$((SECONDS + 900))
key1=""
while [ $SECONDS -lt $deadline ]; do
  key1=$(spo_group_key 1)
  [ -n "$key1" ] && break
  sleep 5
done
[ -n "$key1" ] || die "spo1 never published a group key (DKG did not complete) — docker compose logs heimdall-spo1"
for i in 2 3 4; do
  k=""
  while [ $SECONDS -lt $deadline ] && [ -z "$k" ]; do
    k=$(spo_group_key "$i")
    [ -n "$k" ] || sleep 5
  done
  [ "$k" = "$key1" ] || die "spo$i group key '$k' != spo1 '$key1' — determinism broken"
done
log "OK: all 4 SPOs derived Y_51 = $key1"
log "bridge-contract deploy (binocular deploy-bridge etc.) is the next slice — see README"
