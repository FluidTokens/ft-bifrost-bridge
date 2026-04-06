/-
  BifrostProofs.Liveness
  Liveness and censorship resistance properties.

  L1 and L2 are axioms — they depend on honest participant behavior
  outside the state machine (SPOs signing, watchtowers relaying to Bitcoin).

  L3–L6 are theorems provable from the `step` function.
-/
import BifrostProofs.Trace
import BifrostProofs.Axioms

namespace BifrostProofs

/-- Honest SPO majority assumption -/
def honestSPOMajority (s : ProtocolState) : Prop :=
  match s.currentRoster with
  | some roster =>
    let honestStake := totalStake (roster.members.filter (fun _spo => True))  -- abstract
    honestStake * 100 > 51 * totalStake roster.members
  | none => False

/-- Eventually predicate: there exists a future trace reaching a state satisfying P -/
def eventually (s : ProtocolState) (P : ProtocolState → Prop) : Prop :=
  ∃ (trace : List ProtocolAction) (s' : ProtocolState),
    ValidTrace s trace s' ∧ P s'

-- ============================================================================
-- Axioms: liveness depends on honest actor behavior outside the state machine
-- ============================================================================

/-- L1: Peg-out liveness — every peg-out is eventually fulfilled or cancellable.

    Depends on: honest SPOs signing TMs (FROST), honest watchtower relaying
    the signed TM to Bitcoin, oracle confirming the TM, and Bitcoin including it.
    These are external system guarantees that cannot be derived from `step` alone.

    Discharge path: composition of frost_correctness, oracle_soundness,
    and honest-behavior assumptions. -/
axiom pegout_liveness :
    ∀ (s : ProtocolState) (po : PegOutRequest),
      po ∈ s.pendingPegOuts →
      honestSPOMajority s →
      honestWatchtowerExists →
      eventually s (fun s' =>
        pegoutFulfilled s' po ∨ treasuryRotated s' po)

/-- L2a: Peg-in sweep — deposit is eventually swept into the treasury.

    Requires honest SPO majority (to sign the TM) and an honest watchtower
    (to detect the deposit, create a PegInRequest, and relay the signed TM
    to Bitcoin). These are external system guarantees.

    Discharge path: composition of frost_correctness, oracle_soundness,
    and honest-behavior assumptions. -/
axiom pegin_is_swept :
    ∀ (s : ProtocolState) (d : Deposit),
      d ∈ s.pendingDeposits →
      honestSPOMajority s →
      honestWatchtowerExists →
      eventually s (fun s' => depositSwept s' d)

/-- L2b: Peg-in refundable — depositor can always reclaim BTC after ~30 days.

    Requires NO trust in SPOs or watchtowers — only that Bitcoin's
    OP_CHECKSEQUENCEVERIFY enforces the 4320-block timelock on the
    depositor refund script leaf in the peg-in Taproot address.

    This is the unconditional safety net: even if the bridge is completely
    offline, no SPOs are honest, and no watchtowers exist, the depositor
    can still recover their BTC after the timeout.

    Discharge path: BIP341 Taproot spending rules + Bitcoin consensus. -/
axiom pegin_refundable :
    ∀ (s : ProtocolState) (d : Deposit),
      d ∈ s.pendingDeposits →
      eventually s (fun s' =>
        depositorCanSpend d s'.bitcoinHeight)

-- ============================================================================
-- Theorems: provable from the `step` function
-- ============================================================================

/-- L3: Permissionless watchtower participation.
    The `step` function imposes no registry or whitelist check on OracleUpdate.
    Anyone can submit block headers if they advance the confirmed height. -/
theorem watchtower_permissionless (s : ProtocolState) (blocks : List BlockHeader)
    (hblocks : blocks.length > 0)
    (hlast : ∀ b ∈ blocks, b.height > s.oracleState.confirmedHeight) :
    ∃ s', step s (.OracleUpdate blocks) = some s' := by
  sorry

/-- L4: Depositor self-service — a depositor can create their own PegInRequest.

    Combined with L3 (permissionless watchtower) and Schnorr signature for minting,
    a depositor can complete the entire peg-in flow without relying on third parties. -/
theorem depositor_self_service (s : ProtocolState) (d : Deposit) (proof : OracleProof)
    (hd : d ∈ s.pendingDeposits)
    (hnone : ¬ s.pegInRequests.any (fun r => r.depositId == d.depositId)) :
    ∃ s', step s (.CreatePegInRequest d proof) = some s' := by
  sorry

/-- L5: Peg-out completion is permissionless.
    Anyone with a valid Binocular proof can complete a peg-out.
    No registration, staking, or special role is required. -/
theorem pegout_completion_permissionless (s : ProtocolState) (poIdx : Nat)
    (proof : OracleProof)
    (hidx : poIdx < s.pendingPegOuts.length) :
    ∃ s', step s (.FulfillPegOut poIdx proof) = some s' := by
  sorry

/-- L6: Bridge cannot permanently stall — federation fallback guarantees progress.

    If the TM is well-formed (sweeps exist, payouts match), the `step` function
    accepts `.TreasuryMovement tm .federation` unconditionally. -/
theorem bridge_cannot_stall (s : ProtocolState) (tm : TMTransaction) :
    (tm.sweepedDeposits.all
      (fun did => s.pegInRequests.any (fun r => r.depositId == did))) →
    (tm.fulfilledPegOuts.all
      (fun poId => s.pendingPegOuts.any (fun po => po.id == poId))) →
    ∃ s', step s (.TreasuryMovement tm .federation) = some s' := by
  sorry

end BifrostProofs
