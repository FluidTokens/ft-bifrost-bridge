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
# BLOCKED (plan N4/WI-019): turning retained evidence into an on-chain
# FaultProof + ban — the fault verifier is a spec-declared mock until N4;
# extend this scenario with the ban assertions when N4 lands.
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
  log "step 1: run a ceremony where spo4 double-publishes round 1"
  # TODO(wire): needs a fault-injection hook in heimdall (a demo-only flag
  # to republish a fresh round-1 package after the first). Until then this
  # arm documents the wire-level check: peers' fetch path logs
  # 'EQUIVOCATION: peer <pool> published two distinct payloads for (...)'
  # and retains both raw payloads (http/peer_network.rs::retain_evidence).
  die "equivocate arm not wired yet — needs a heimdall fault-injection flag"
  ;;
*) die "unknown fault: $FAULT (absent|equivocate)" ;;
esac
