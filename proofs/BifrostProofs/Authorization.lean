/-
  BifrostProofs.Authorization
  Theorems A1–A6: Authorization and access control.

  A4 and A5 (signature verification) are enforced by on-chain validators,
  not by the state machine. They are axiomatized in Axioms.lean as
  `schnorr_unforgeability` and `ed25519_unforgeability`.
-/
import BifrostProofs.Trace
import BifrostProofs.Axioms

namespace BifrostProofs

/-- A1: Only TreasuryMovement can change the treasury UTxO.

    Provable by case analysis on all action types in `step`:
    only `.TreasuryMovement` modifies `treasuryUTxO`. -/
theorem treasury_requires_authorization (s s' : ProtocolState) (a : ProtocolAction)
    (h : step s a = some s')
    (hchanged : s'.treasuryUTxO ≠ s.treasuryUTxO) :
    ∃ (tm : TMTransaction) (q : QuorumLevel),
      a = .TreasuryMovement tm q := by
  sorry

/-- A2: fBTC supply increases only via MintFBTC or CancelPegOut.

    Provable by case analysis: only these two actions increase `circulatingFBTC`. -/
theorem mint_requires_pegin (s s' : ProtocolState) (a : ProtocolAction)
    (h : step s a = some s')
    (hmore : s'.circulatingFBTC > s.circulatingFBTC) :
    ∃ (idx : Nat) (sig : SchnorrSig) (proof : OracleProof),
      a = .MintFBTC idx sig proof
      ∨ (∃ (poIdx : Nat), a = .CancelPegOut poIdx) := by
  sorry

/-- A3: Peg-out cancel requires treasury rotation.

    Follows from the `decide (s.currentTreasuryAddress ≠ po.treasuryAtCreation)`
    guard in `step`. -/
theorem cancel_requires_rotation (s s' : ProtocolState) (poIdx : Nat)
    (h : step s (.CancelPegOut poIdx) = some s')
    (hidx : poIdx < s.pendingPegOuts.length) :
    let po := s.pendingPegOuts.get ⟨poIdx, hidx⟩
    s.currentTreasuryAddress ≠ po.treasuryAtCreation := by
  sorry

-- A4 (depositor Schnorr signature) and A5 (SPO cold key Ed25519 signature)
-- are enforced by on-chain validators, not by the state machine.
-- See Axioms.lean: `schnorr_unforgeability` and `ed25519_unforgeability`.

/-- A6: Only DKG can change epoch keys.

    Provable by case analysis: only `.DKG` modifies `epochKeys`. -/
theorem keys_require_authorization (s s' : ProtocolState) (a : ProtocolAction)
    (h : step s a = some s')
    (hchanged : s'.epochKeys ≠ s.epochKeys) :
    ∃ (epoch : Nat) (result : DKGResult), a = .DKG epoch result := by
  sorry

end BifrostProofs
