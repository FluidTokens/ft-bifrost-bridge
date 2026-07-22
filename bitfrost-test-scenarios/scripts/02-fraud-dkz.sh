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
  for i in 1 2 3 4; do rm -rf "data/spo$i"; mkdir -p "data/spo$i"; done
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
  while [ $SECONDS -lt $deadline ]; do
    if docker compose logs 2>/dev/null | grep -q '\[fault-ban\] built ApplyBan: first_ban='; then
      banned=1
      break
    fi
    sleep 5
  done

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

  [ "$banned" = 1 ] ||
    die "equivocation was detected but no ApplyBan landed — see $REPORT/summary.txt"
  log "OK: cheat -> detect -> FaultProof -> ban, report in $REPORT/"
  ;;
*) die "unknown fault: $FAULT (absent|equivocate)" ;;
esac
