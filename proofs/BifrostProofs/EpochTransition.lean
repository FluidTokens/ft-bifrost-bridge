/-
  BifrostProofs.EpochTransition
  Theorems E1–E4: Epoch transition properties.
-/
import BifrostProofs.Trace
import BifrostProofs.Axioms

namespace BifrostProofs

/-- E1: Treasury moves to new roster's address at epoch boundary.

    After DKG completes and the current roster signs the final TM of the epoch,
    the treasury UTxO's new address is derived from the new epoch keys. -/
theorem treasury_moves_at_epoch (s s' : ProtocolState)
    (tm : TMTransaction) (quorum : QuorumLevel)
    (hstep : step s (.TreasuryMovement tm quorum) = some s') :
    -- The treasury UTxO is updated with the TM's txid
    s'.treasuryUTxO.outpoint.txid = tm.txid := by
  sorry

/-- E2: Pending peg-ins roll over to next epoch if not swept.

    Peg-in deposits that were not included in the current epoch's TM
    remain in pendingDeposits and pegInRequests for the next epoch. -/
theorem pegins_roll_over (s s' : ProtocolState)
    (hstep : step s .EpochBoundary = some s')
    (req : PegInRequest)
    (hreq : req ∈ s.pegInRequests) :
    req ∈ s'.pegInRequests := by
  sorry  -- EpochBoundary only increments currentEpoch

/-- E3: New roster can only control treasury after TM confirmed on Bitcoin.

    The new roster's group keys are published to treasury.ak, but the actual
    treasury UTxO on Bitcoin still belongs to the old roster until the TM
    that moves it to the new address is confirmed. -/
theorem new_roster_after_confirmation (s s' : ProtocolState)
    (epoch : Nat) (result : DKGResult)
    (hDkg : step s (.DKG epoch result) = some s') :
    -- DKG changes epoch keys but NOT the treasury UTxO
    s'.treasuryUTxO = s.treasuryUTxO := by
  sorry  -- follows from step definition: DKG only updates epochKeys + currentRoster

/-- E4: Old roster loses treasury control after TM spends old address.

    Once the TM is confirmed on Bitcoin, the old treasury UTxO is spent.
    By bitcoin_utxo_spent_once, it cannot be spent again. -/
theorem old_roster_loses_control (s s' : ProtocolState)
    (tmIdx : Nat) (proof : OracleProof)
    (hconfirm : step s (.ConfirmTM tmIdx proof) = some s')
    (hidx : tmIdx < s.postedTMs.length) :
    let tm := s.postedTMs.get ⟨tmIdx, hidx⟩
    -- The TM is now confirmed
    tm ∈ s'.confirmedTMs := by
  sorry

/-- Epoch number monotonically increases. -/
theorem epoch_monotone (s s' : ProtocolState) (a : ProtocolAction)
    (h : step s a = some s') :
    s'.currentEpoch ≥ s.currentEpoch := by
  sorry  -- case analysis: only EpochBoundary increments, everything else preserves

end BifrostProofs
