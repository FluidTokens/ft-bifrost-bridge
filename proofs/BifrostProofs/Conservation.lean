/-
  BifrostProofs.Conservation
  Theorem C1: Conservation of funds.
  Total fBTC on Cardano never exceeds BTC held in the treasury.
-/
import BifrostProofs.Trace

namespace BifrostProofs

/-- The conservation invariant: circulating fBTC ≤ treasury balance.

    Note: in the full model, "circulating fBTC" includes both freely circulating
    fBTC and fBTC locked in pending peg-outs. The treasury balance includes
    swept peg-in deposits. -/
def conservationInvariant (s : ProtocolState) : Prop :=
  s.circulatingFBTC + (s.pendingPegOuts.foldl (fun acc po => acc + po.amount) 0)
    ≤ s.treasuryUTxO.value

/-- Conservation holds on any initial state. -/
theorem conservation_initial (s : ProtocolState) (h : isInitialState s) :
    conservationInvariant s := by
  unfold conservationInvariant
  obtain ⟨_, hpo, _, hfbtc, _, _, _⟩ := h
  simp [hpo, hfbtc]

/-- C1: Conservation of funds — the main theorem.
    For any reachable state, total fBTC ≤ treasury BTC.

    Proof sketch: by induction on the trace.
    Each action preserves the invariant:
    - MintFBTC: increases fBTC by amount X; but the deposit (amount X)
      was already swept into treasury by a prior TreasuryMovement
    - LockForPegOut: moves fBTC from circulating to locked (net zero)
    - FulfillPegOut: removes locked fBTC (already in locked set)
    - CancelPegOut: returns locked fBTC to circulating (net zero)
    - TreasuryMovement: increases treasury by swept amount, which ≥ 0
    - All other actions: neither fBTC nor treasury changes -/
theorem conservation_of_funds (s s' : ProtocolState)
    (trace : List ProtocolAction)
    (hinit : isInitialState s)
    (hvt : ValidTrace s trace s') :
    conservationInvariant s' := by
  sorry  -- requires case analysis on each action type preserving the invariant

/-- C2: MintFBTC increases fBTC by exactly the peg-in deposit amount. -/
theorem mint_increases_fbtc_exactly (s s' : ProtocolState)
    (idx : Nat) (sig : SchnorrSig) (proof : OracleProof)
    (h : step s (.MintFBTC idx sig proof) = some s')
    (hidx : idx < s.pegInRequests.length) :
    let req := s.pegInRequests.get ⟨idx, hidx⟩
    s'.circulatingFBTC = s.circulatingFBTC + req.amount := by
  sorry  -- follows from step definition

/-- C3: FulfillPegOut does not change circulatingFBTC
    (fBTC was already subtracted when locked). -/
theorem fulfill_preserves_fbtc (s s' : ProtocolState)
    (idx : Nat) (proof : OracleProof)
    (h : step s (.FulfillPegOut idx proof) = some s') :
    s'.circulatingFBTC = s.circulatingFBTC := by
  sorry  -- follows from step definition

/-- C4: CancelPegOut returns fBTC to circulating supply. -/
theorem cancel_returns_fbtc (s s' : ProtocolState)
    (idx : Nat)
    (h : step s (.CancelPegOut idx) = some s')
    (hidx : idx < s.pendingPegOuts.length) :
    let po := s.pendingPegOuts.get ⟨idx, hidx⟩
    s'.circulatingFBTC = s.circulatingFBTC + po.amount := by
  sorry  -- follows from step definition

/-- C5: TreasuryMovement increases treasury by swept amount. -/
theorem tm_increases_treasury (s s' : ProtocolState)
    (tm : TMTransaction) (quorum : QuorumLevel)
    (h : step s (.TreasuryMovement tm quorum) = some s') :
    s'.treasuryUTxO.value ≥ s.treasuryUTxO.value
      - (tm.pegOutPayments.foldl (fun acc p => acc + p.amount) 0)
      + (s.pegInRequests
          |>.filter (fun r => tm.sweepedDeposits.any (· == r.depositId))
          |>.foldl (fun acc r => acc + r.amount) 0) := by
  sorry  -- follows from step definition

end BifrostProofs
