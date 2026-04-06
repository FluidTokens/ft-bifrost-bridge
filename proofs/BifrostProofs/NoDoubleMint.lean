/-
  BifrostProofs.NoDoubleMint
  Theorem D1: No double minting.
  Each Bitcoin deposit produces fBTC at most once.
-/
import BifrostProofs.Trace

namespace BifrostProofs

/-- D1: No double minting — each deposit mints fBTC at most once.

    Proof sketch:
    - MintFBTC for depositId d removes the PegInRequest for d from state
      and inserts d into completedPegIns.
    - By trie_non_inclusion_checked, minting requires d ∉ completedPegIns.
    - By trie_insertion_on_mint, after minting d ∈ completedPegIns.
    - Therefore a second MintFBTC for d would fail the non-inclusion check.
    - By peg_in_nft_unique, at most one PegInRequest exists per deposit,
      so there's no alternative PegInRequest to consume. -/
theorem no_double_mint (s s' : ProtocolState)
    (trace : List ProtocolAction)
    (hinit : isInitialState s)
    (hvt : ValidTrace s trace s')
    (depositId : DepositId) :
    countMintsInTrace depositId s trace ≤ 1 := by
  sorry

/-- D2: PegInRequest is removed from state on MintFBTC. -/
theorem pegin_removed_on_mint (s s' : ProtocolState)
    (idx : Nat) (sig : SchnorrSig) (proof : OracleProof)
    (h : step s (.MintFBTC idx sig proof) = some s')
    (hidx : idx < s.pegInRequests.length) :
    let req := s.pegInRequests.get ⟨idx, hidx⟩
    req ∉ s'.pegInRequests := by
  sorry  -- follows from List.removeAt removing the element

/-- D3: At most one PegInRequest per deposit in any reachable state. -/
theorem at_most_one_pegin_request (s : ProtocolState) (d : DepositId)
    (hreach : Reachable s) :
    (s.pegInRequests.filter (fun r => r.depositId == d)).length ≤ 1 := by
  sorry  -- follows from CreatePegInRequest checking no existing request

/-- D4: Each peg-out is fulfilled at most once (PegOut removed on fulfill). -/
theorem pegout_removed_on_fulfill (s s' : ProtocolState)
    (idx : Nat) (proof : OracleProof)
    (h : step s (.FulfillPegOut idx proof) = some s')
    (hidx : idx < s.pendingPegOuts.length) :
    let po := s.pendingPegOuts.get ⟨idx, hidx⟩
    po ∉ s'.pendingPegOuts := by
  sorry

/-- D5: After minting, the deposit is in the completed trie. -/
theorem deposit_in_completed_after_mint (s s' : ProtocolState)
    (idx : Nat) (sig : SchnorrSig) (proof : OracleProof)
    (h : step s (.MintFBTC idx sig proof) = some s')
    (hidx : idx < s.pegInRequests.length) :
    let req := s.pegInRequests.get ⟨idx, hidx⟩
    req.depositId ∈ s'.completedPegIns := by
  sorry  -- follows from step appending depositId to completedPegIns

/-- Minting requires deposit NOT in completed trie (precondition). -/
theorem mint_requires_not_completed (s s' : ProtocolState)
    (idx : Nat) (sig : SchnorrSig) (proof : OracleProof)
    (h : step s (.MintFBTC idx sig proof) = some s')
    (hidx : idx < s.pegInRequests.length) :
    let req := s.pegInRequests.get ⟨idx, hidx⟩
    req.depositId ∉ s.completedPegIns := by
  sorry  -- follows from the if-condition in step

end BifrostProofs
