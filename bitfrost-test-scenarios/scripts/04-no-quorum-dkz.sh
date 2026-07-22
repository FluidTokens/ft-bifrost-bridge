#!/usr/bin/env bash
# Scenario 4 — the DKG cannot reach quorum. The bridge WAITS; it does not fail
# over, does not halt, and does not switch to the federation.
#
# This is the spec's degraded-epoch branch, §Flow of Bitcoin over epochs
# "Failure branches" (9):
#
#   DKG fails (qualified subset below t): no Update-Y is posted; the old key
#   stays in the Treasury state and the old roster simply carries over —
#   batches continue under it, and the next epoch boundary takes fresh
#   snapshots and retries the DKG. No halt, no special state.
#
# What it must NOT do is switch to federation mode. That is not a gap in
# heimdall — per §Threshold failover, "federation mode does not use the SPO HTTP
# endpoints… it is an on-chain and Bitcoin-level emergency fallback", and per
# §Signing namespaces it "has no signing namespace at all: it uses no SPO
# endpoints and no FROST rounds". The federation signs out of band with
# Y_federation via the CSV leaf; the SPO program has no part in it. So the
# absence of any federation transition here is the specified behaviour, and this
# scenario asserts that absence rather than treating it as missing.
#
# Threshold arithmetic for this bench: 4 pools of equal 20 ADA stake, so
# t = the smallest k whose k WEAKEST stakes exceed 51% — 2×20 = 50% (not >51%),
# 3×20 = 75%. Hence t = 3:
#   * 3 survivors  → still quorate → reduced 3-of-3 rerun succeeds  (scenario 2 `absent`)
#   * 2 survivors  → below quorum  → abort + retry forever          (THIS scenario)
. "$(dirname "$0")/00-lib.sh"
check_pins
check_dkg_pacing

REPORT="$LOGS/scenario4-no-quorum"
rm -rf "$REPORT" && mkdir -p "$REPORT"

log "scenario 4: assumes scenario-1 infra is up (4 SPOs registered on chain)"

# Take down TWO, leaving two survivors — one short of t=3.
DOWN=(heimdall-spo3 heimdall-spo4)
UP=(heimdall-spo1 heimdall-spo2)

log "step 1: fresh DKG state, then start only ${#UP[@]} of 4 SPOs"
docker compose rm -sf heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4 >/dev/null 2>&1 || true
# Cleared from INSIDE a container: heimdall runs as root there, so the persisted
# dkg-epoch-*.json are root-owned and a host-side rm fails with EPERM.
for i in 1 2 3 4; do
  docker compose run --rm --no-deps -T --user root --entrypoint sh \
    "heimdall-spo$i" -c 'rm -rf /state/* /state/.[!.]*' >/dev/null 2>&1 || true
done
docker compose up -d "${UP[@]}"
log "  up: ${UP[*]} — down: ${DOWN[*]} (2 of 4 → below t=3)"

log "step 2: the survivors WAIT at the health gate rather than charging ahead"
# dkg_join_wait_secs (45s) bounds this wait. It used to be 300s, which made a
# ceremony outlive its own 60s epoch five times over -- see check_dkg_pacing.
wait_log heimdall-spo1 'health gate: waiting for peer\(s\)' 180 ||
  die "spo1 never logged the health-gate wait — see $REPORT/"
log "  spo1 is waiting for the missing peers"

log "step 3: gate expires, ceremony runs anyway, quorum gate refuses (~5 min)"
# The gate is bounded: after dkg_join_wait it proceeds without the unreachable
# peers, round 1 closes with 2 of 4 published, and rerun_or_abort refuses because
# 2 < t. The refusal is the point — a reduced 2-of-2 ceremony would be a 50%
# bridge, which is exactly what the >51% stake arm exists to prevent.
wait_log heimdall-spo1 'round1 incomplete at deadline: 2/4' 600 ||
  die "spo1 never reached the round-1 deadline with 2/4 — see $REPORT/"
wait_log heimdall-spo1 'fails the threshold / >51%-stake quorum gate' 120 ||
  die "the ceremony did not abort on the quorum gate — see $REPORT/"
log "  quorum refused: 2/4 qualified, below t=3"

log "step 4: it BACKS OFF AND RETRIES — no halt, no fatal exit"
wait_log heimdall-spo1 'retriable error: DKG aborted.*backing off' 120 ||
  die "abort was not treated as retriable — see $REPORT/"
# Alive, not crashed: the spec's "no halt" is a claim about the process, so check
# the process, not just its logs.
[ "$(docker compose ps -q heimdall-spo1 | wc -l)" = 1 ] &&
  [ "$(docker inspect -f '{{.State.Running}}' "$(docker compose ps -q heimdall-spo1)")" = "true" ] ||
  die "spo1 is not running after the abort — 'no halt' violated"
# ...and it genuinely re-enters, rather than merely logging that it would: a
# SECOND abort after the first is what "retries" actually means.
#
# This must COUNT, not wait_log: wait_log re-reads `docker compose logs` from the
# start, so it matches the first, historical occurrence instantly and would
# report success without a second cycle ever happening. That is the same shape as
# the false green this bench has already been bitten by once, so the check
# compares the abort count against its own baseline.
aborts_before=$(docker compose logs heimdall-spo1 2>/dev/null | grep -c 'DKG aborted' || true)
retried=0
deadline=$((SECONDS + 420))
while [ $SECONDS -lt $deadline ]; do
  aborts_after=$(docker compose logs heimdall-spo1 2>/dev/null | grep -c 'DKG aborted' || true)
  if [ "$aborts_after" -gt "$aborts_before" ]; then
    retried=1
    break
  fi
  sleep 10
done
[ "$retried" = 1 ] ||
  die "only $aborts_before abort(s) ever seen — the node logged a retry but never ran a second ceremony"
log "  still alive and retrying: DKG abort cycles $aborts_before → $aborts_after"

log "step 5: assert NO federation transition and NO key publication"
# Per spec the SPO program must not fail over to the federation, so its absence
# is an assertion, not an omission. `CascadeLevel::Federation` no longer exists
# in heimdall precisely because the spec forbids it.
if docker compose logs "${UP[@]}" 2>/dev/null |
  grep -iE 'federation (mode|fallback|signing)|CascadeLevel::Federation|demoting to federation'; then
  die "a federation transition appeared — the spec says the SPO program has no federation role"
fi
# No Update-Y either: publish_group_key is only reached after a successful DKG.
if docker compose logs "${UP[@]}" 2>/dev/null | grep -q 'PublishKeys: group_key ='; then
  die "keys were published despite the DKG failing — no Update-Y may be posted"
fi
log "  no federation transition, no key publication — as specified"

log "step 6: recovery — bring the two back; the ceremony must converge again"
docker compose up -d "${DOWN[@]}"
deadline=$((SECONDS + 900))
Y=""
while [ $SECONDS -lt $deadline ]; do
  Y=$(spo_group_key 1)
  [ -n "$Y" ] && break
  sleep 5
done
[ -n "$Y" ] || die "no group key after the missing SPOs returned — recovery failed"
for i in 2 3 4; do
  y=$(spo_group_key "$i")
  [ "$y" = "$Y" ] ||
    die "spo$i derived $y, spo1 derived $Y — recovery produced divergent keys"
done
log "  recovered: all 4 SPOs derived Y_51 = $Y"

log "step 7: collect the report"
for i in 1 2 3 4; do
  docker compose logs --no-color "heimdall-spo$i" >"$REPORT/spo$i.log" 2>&1 || true
done
{
  echo "=== HEALTH-GATE WAIT (survivors) ==="
  grep -h 'health gate' "$REPORT"/spo[12].log | head -10 || echo "(none)"
  echo
  echo "=== QUORUM REFUSAL ==="
  grep -h 'incomplete at deadline\|quorum gate\|DKG aborted' "$REPORT"/spo[12].log | head -10 || echo "(none)"
  echo
  echo "=== RETRY, NOT HALT ==="
  grep -h 'retriable error' "$REPORT"/spo[12].log | head -5 || echo "(none)"
  echo
  echo "=== RECOVERY ==="
  grep -h 'PublishKeys: group_key' "$REPORT"/spo*.log | tail -4 || echo "(none)"
} | tee "$REPORT/summary.txt"

log "OK: no quorum -> wait -> refuse -> retry -> recover (no federation), report in $REPORT/"
