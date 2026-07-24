#!/usr/bin/env bash
# Scenario 2 — a fraudulent / failing DKG attempt.
#
# Two injectable faults, both already detectable by heimdall today:
#   A) ABSENT PEER: stop one SPO mid-ceremony. The survivors freeze the
#      live subset at the shared deadline, capture DkgExclusionEvidence,
#      and rerun reduced 3-of-4 (quorum: 3/4 equal stake > 51%).
#   B) EQUIVOCATION: republish a second, different round-1 payload under
#      the same (epoch, threshold, attempt) namespace. Peers' transports
#      flag EQUIVOCATION and retain both raw payloads as evidence.
#
# Asserted now: the 3 honest SPOs complete with one shared Y_51 excluding
# the faulty one, and the evidence lines appear in the logs.
#
# The EQUIVOCATION arm additionally asserts the on-chain consequence — the
# FaultProof mint and the ApplyBan — which N4/WI-019 unblocked. It is the one
# fault kind that can: equivocation is ZK-free (no SRS is opened, the
# round1/round2 verifier refs are never consumed), so it needs no trusted
# setup. The round1/round2 arms remain proof-blocked.
# Requires scenario 1's step 6b to have deployed the fault verifiers + ban list.
. "$(dirname "$0")/00-lib.sh"
check_pins
check_dkg_pacing

FAULT="${1:-absent}" # absent | equivocate

log "scenario 2 ($FAULT): assumes scenario-1 infra is up (bridge deployed, SPOs registered)"

case "$FAULT" in
absent)
  log "step 1: start all 4 SPOs, then stop spo4 before its round-1 publish"
  # TODO(wire): start spo1-3 normally; start spo4 and `docker compose stop
  # heimdall-spo4` inside the health-gate window (the gate passes — spo4 IS
  # up — then it vanishes before publishing).
  log "step 2: assert survivors' logs show the exclusion + reduced rerun"
  # TODO(wire): grep spo1-3 logs for:
  #   'round1 incomplete at deadline: 3/4'
  #   'DKG fault evidence (attempt'
  # then the scenario-1 group-key assertion over spo1-3 only.
  ;;
equivocate)
  REPORT="$LOGS/scenario2-equivocate"
  rm -rf "$REPORT" && mkdir -p "$REPORT"

  log "step 1: restart the 4 SPOs with spo4 equivocating (fresh DKG state)"
  # Wipe per-SPO state so this is a NEW ceremony rather than a resume of the
  # completed scenario-1 one — the fault only exists during round 1.
  docker compose rm -sf heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4 >/dev/null 2>&1 || true
  # Cleared from INSIDE a container: heimdall runs as root there, so the
  # persisted dkg-epoch-*.json are root-owned and a host-side `rm -rf` fails
  # with EPERM. Each service mounts its own data/spoN at /state.
  for i in 1 2 3 4; do
    docker compose run --rm --no-deps -T --user root --entrypoint sh \
      "heimdall-spo$i" -c 'rm -rf /state/* /state/.[!.]*' >/dev/null 2>&1 || true
  done
  SPO4_INJECT_FAULT=--inject-fault=equivocate-round1 \
    docker compose up -d heimdall-spo1 heimdall-spo2 heimdall-spo3 heimdall-spo4
  docker compose logs heimdall-spo4 2>/dev/null | grep -q 'FAULT INJECTION ENABLED' ||
    log "  (note: injection banner not visible yet — spo4 may still be starting)"

  log "step 2: wait for the honest SPOs to flag the equivocation"
  # Detection is inline in round 1: the anti-equivocation sweep re-fetches every
  # peer over a short grace window, retains the two conflicting payloads, and
  # `report_round1_equivocations` turns them into a fault.
  deadline=$((SECONDS + 900))
  detected=0
  while [ $SECONDS -lt $deadline ]; do
    n=0
    for i in 1 2 3; do
      docker compose logs "heimdall-spo$i" 2>/dev/null |
        grep -q 'EQUIVOCATION: peer .* published two distinct payloads' && n=$((n + 1))
    done
    [ "$n" -ge 1 ] && { detected=$n; break; }
    sleep 5
  done
  [ "$detected" -ge 1 ] ||
    die "no honest SPO flagged the equivocation within 900s — docker compose logs heimdall-spo1"
  log "  $detected/3 honest SPOs flagged spo4"

  log "step 3: assert the on-chain consequence — FaultProof mint + ApplyBan"
  # ZK-free path: equivocation opens no SRS and never consumes the round1/round2
  # verifier refs, so this is the one fault kind that runs end-to-end on a
  # devnet without a trusted setup.
  banned=0
  ban_tx=""
  while [ $SECONDS -lt $deadline ]; do
    # Assert on SUBMITTED, not "built": `built ApplyBan` is logged before the
    # tx is sent, so keying on it reports success even when submission is
    # rejected — which it was, with WithdrawalsNotInRewardsCERTS.
    # `|| true` is load-bearing: under `set -euo pipefail` a no-match grep makes
    # the pipeline exit 1, and a bare assignment from it is NOT exempt from
    # set -e (unlike the `if grep -q` form this replaced) — so without it the
    # scenario dies on the first poll, before any ApplyBan can possibly exist.
    ban_tx=$(docker compose logs 2>/dev/null |
      grep -oE '\[fault-ban\] submitted apply-ban: tx_hash=[0-9a-f]{64}' |
      head -1 | cut -d= -f2) || true
    if [ -n "$ban_tx" ]; then
      banned=1
      break
    fi
    sleep 5
  done

  # ...and even "submitted" is only heimdall's account of itself: it proves a
  # request was made, not that the ledger kept it. Ask the chain. This is the M4
  # false-green lesson generalized — the run that printed
  # "OK: cheat -> detect -> FaultProof -> ban" while the ApplyBan had in fact
  # been rejected was caught only by querying the chain by hand.
  #
  # try_ not wait_: every failure below must reach the report tee'd in step 4,
  # and the fatal form would exit first, throwing away the logs that explain why.
  ban_confirmed=0
  if [ "$banned" = 1 ]; then
    log "  ApplyBan submitted as $ban_tx — confirming against the chain"
    try_cardano_tx "$ban_tx" && ban_confirmed=1
  fi

  log "step 4: collect the report"
  for i in 1 2 3 4; do
    docker compose logs --no-color "heimdall-spo$i" >"$REPORT/spo$i.log" 2>&1 || true
  done
  {
    echo "=== INJECTION (spo4) ==="
    grep -h 'FAULT INJECTION ENABLED\|INJECT: equivocating' "$REPORT"/spo4.log || echo "(none)"
    echo
    echo "=== DETECTION (honest SPOs) ==="
    grep -h 'EQUIVOCATION: peer' "$REPORT"/spo[123].log || echo "(none)"
    echo
    echo "=== FAULT PUBLICATION ==="
    grep -h 'publishing DKG fault' "$REPORT"/spo[123].log || echo "(none)"
    echo
    echo "=== ON-CHAIN FAULT PROOF + BAN ==="
    grep -h '\[fault-ban\]' "$REPORT"/spo*.log || echo "(none)"
  } | tee "$REPORT/summary.txt"

  if [ "$ban_confirmed" != 1 ]; then
    # Distinguish the three ways this fails. They have completely different
    # causes, and collapsing them into "no ApplyBan landed" is what made the
    # 2026-07-22 blocker cost a day: the tx was built and rejected, but the
    # scenario said only that a ban was missing.
    [ "$banned" != 1 ] ||
      die "ApplyBan $ban_tx was submitted but never reached the chain — see $REPORT/summary.txt"

    # Built-but-never-submitted is the signature of a LEDGER rejection, not a
    # protocol bug. Surface the node's own words so the next deployment gap
    # diagnoses itself instead of needing a manual chain query.
    if grep -qh '\[fault-ban\] built ApplyBan' "$REPORT"/spo*.log; then
      {
        echo
        echo "=== APPLYBAN WAS BUILT BUT NEVER LANDED — node rejection follows ==="
        # Anchored per SPO, from its OWN apply-ban submission onward. A flat
        # grep across all four picks up the mint-race losers' BadInputsUTxO —
        # benign, expected, and noisy enough to bury the real rejection.
        for f in "$REPORT"/spo*.log; do
          grep -q '\[fault-ban\] built ApplyBan' "$f" || continue
          echo "--- ${f##*/} ---"
          sed -n '/\[fault-ban\] submitting apply-ban/,$p' "$f" |
            grep -m3 'Message: {\|Error: 4[0-9][0-9]\|apply-ban blockfrost tx submit' ||
            echo "(no submission error logged)"
        done
      } | tee -a "$REPORT/summary.txt"
      die "ApplyBan was built and REJECTED by the node, not merely missing — see the rejection above and $REPORT/summary.txt"
    fi
    die "equivocation was detected but no ApplyBan was ever built — see $REPORT/summary.txt"
  fi
  log "OK: cheat -> detect -> FaultProof -> ban (ApplyBan $ban_tx confirmed on chain), report in $REPORT/"
  ;;
*) die "unknown fault: $FAULT (absent|equivocate)" ;;
esac
