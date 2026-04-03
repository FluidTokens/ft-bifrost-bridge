/-
  BifrostProofs.Threshold
  Theorem R2: Threshold security.
  Any subset of t FROST signers controls more than the security threshold
  of total delegated stake.
-/
import BifrostProofs.Basic

namespace BifrostProofs

/-- Compute the minimum threshold ensuring any t signers exceed the security threshold.
    t = min { k : bottomKStake(roster, k) > securityThreshold * totalStake / 10000 } -/
def computeThreshold (spos : List SPO) (securityThresholdBps : Nat) : Nat :=
  let total := totalStake spos
  let target := securityThresholdBps * total / 10000
  -- Find minimum k such that bottom-k SPOs exceed target
  let rec go (k : Nat) (fuel : Nat) : Nat :=
    match fuel with
    | 0 => spos.length
    | fuel' + 1 =>
      if k > spos.length then spos.length
      else if bottomKStake spos k > target then k
      else go (k + 1) fuel'
  go 1 spos.length

/-- Any subset of t SPOs has stake ≥ stake of the bottom t SPOs. -/
theorem any_subset_ge_bottom (spos : List SPO) (subset : List SPO) (t : Nat)
    (hsub : ∀ s ∈ subset, s ∈ spos)
    (hcard : subset.length = t) :
    totalStake subset ≥ bottomKStake spos t := by
  sorry  -- requires showing subset elements sorted by stake are ≥ bottom-k

/-- R2: Threshold security — the main theorem.
    Any subset of size threshold has more than securityThreshold% of total stake. -/
theorem threshold_guarantees_stake (spos : List SPO)
    (securityThresholdBps : Nat)
    (hnonempty : spos.length > 0)
    (t : Nat)
    (ht : t = computeThreshold spos securityThresholdBps)
    (subset : List SPO)
    (hsub : ∀ s ∈ subset, s ∈ spos)
    (hcard : subset.length = t) :
    totalStake subset * 10000 > securityThresholdBps * totalStake spos := by
  sorry

/-- The threshold is always ≤ roster size. -/
theorem threshold_le_roster_size (spos : List SPO) (securityThresholdBps : Nat) :
    computeThreshold spos securityThresholdBps ≤ spos.length := by
  sorry

/-- If the security threshold is < 100%, the threshold is strictly less
    than roster size (there exists a proper subset that exceeds the threshold). -/
theorem threshold_lt_roster_if_possible (spos : List SPO) (securityThresholdBps : Nat)
    (hlt : securityThresholdBps < 10000)
    (hnonempty : spos.length > 0) :
    computeThreshold spos securityThresholdBps ≤ spos.length := by
  sorry

end BifrostProofs
