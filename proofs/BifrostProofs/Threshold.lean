/-
  BifrostProofs.Threshold
  Theorem R2: Threshold security.
  Any subset of t FROST signers controls more than 51% of total delegated stake.
-/
import BifrostProofs.Basic

namespace BifrostProofs

/-- Recursive search for the minimum k such that bottomKStake > target.
    Extracted as a top-level function for easier induction. -/
def thresholdGo (spos : List SPO) (target : Nat) (k : Nat) : Nat → Nat
  | 0 => spos.length
  | fuel + 1 =>
    if k > spos.length then spos.length
    else if bottomKStake spos k > target then k
    else thresholdGo spos target (k + 1) fuel

/-- thresholdGo always returns a value ≤ spos.length -/
theorem thresholdGo_le (spos : List SPO) (target k fuel : Nat) :
    thresholdGo spos target k fuel ≤ spos.length := by
  induction fuel generalizing k with
  | zero => simp [thresholdGo]
  | succ fuel ih =>
    unfold thresholdGo
    split
    · exact Nat.le_refl _
    · split
      · omega
      · exact ih (k + 1)

/-- When thresholdGo returns a value < spos.length,
    bottomKStake at that value exceeds the target. -/
theorem thresholdGo_found (spos : List SPO) (target k fuel : Nat)
    (hresult : thresholdGo spos target k fuel < spos.length) :
    bottomKStake spos (thresholdGo spos target k fuel) > target := by
  induction fuel generalizing k with
  | zero => simp [thresholdGo] at hresult
  | succ fuel ih =>
    unfold thresholdGo at hresult ⊢
    split
    · next h => simp [h] at hresult
    · next h1 =>
      split
      · next h2 => exact h2
      · next h2 =>
        apply ih
        simp [h1, h2] at hresult
        exact hresult

/-- Compute the minimum threshold ensuring any t signers exceed 51% of total stake.
    t = min { k : bottomKStake(roster, k) > 51 · totalStake / 100 } -/
def computeThreshold (spos : List SPO) : Nat :=
  let target := 51 * totalStake spos / 100
  thresholdGo spos target 1 spos.length

-- ============================================================================
-- Axioms about bottomKStake
-- Discharge path: Array.qsort produces a sorted permutation of its input.
--   (1) qsort_perm:   (a.qsort lt).toList.Perm a.toList
--   (2) qsort_sorted: (a.qsort lt).toList.Sorted lt
-- These are implementation properties of Array.qsort, not in Init today.
-- ============================================================================

/-- Any subset (drawing without replacement) has total stake ≥ bottom-k stake.
    This is the standard "sum of any k elements ≥ sum of k smallest" fact.
    Proof: sort both lists ascending; the i-th element of the subset is ≥ the
    i-th smallest overall, so the sums compare element-wise. -/
axiom any_subset_ge_bottom (spos : List SPO) (subset : List SPO) (t : Nat)
    (hsub : ∀ s ∈ subset, s ∈ spos)
    (hnodup_sub : subset.Nodup)
    (hnodup_spos : spos.Nodup)
    (hcard : subset.length = t) :
    totalStake subset ≥ bottomKStake spos t

/-- Taking all elements after sorting preserves the total (qsort is a permutation). -/
axiom bottomKStake_all (spos : List SPO) :
    bottomKStake spos spos.length = totalStake spos

-- ============================================================================
-- Theorems
-- ============================================================================

/-- The threshold is always ≤ roster size. -/
theorem threshold_le_roster_size (spos : List SPO) :
    computeThreshold spos ≤ spos.length := by
  unfold computeThreshold
  exact thresholdGo_le spos _ 1 spos.length

/-- R2: Threshold security — the main theorem.
    Any subset of size `computeThreshold` has more than 51% of total stake.

    Hypotheses:
    - `hstake`: roster has positive total stake (zero-stake roster is degenerate)
    - `hnodup*`: roster and subset have no duplicate SPOs -/
theorem threshold_guarantees_stake (spos : List SPO)
    (hstake : totalStake spos > 0)
    (hnodup : spos.Nodup)
    (t : Nat)
    (ht : t = computeThreshold spos)
    (subset : List SPO)
    (hsub : ∀ s ∈ subset, s ∈ spos)
    (hnodup_sub : subset.Nodup)
    (hcard : subset.length = t) :
    totalStake subset * 100 > 51 * totalStake spos := by
  have hge := any_subset_ge_bottom spos subset t hsub hnodup_sub hnodup hcard
  subst ht
  by_cases hlt : computeThreshold spos < spos.length
  · -- Case: thresholdGo found k < spos.length where bottomKStake k > target
    have hfound : bottomKStake spos (computeThreshold spos) >
        51 * totalStake spos / 100 := by
      unfold computeThreshold at hlt ⊢
      exact thresholdGo_found spos _ 1 spos.length hlt
    -- totalStake subset ≥ bottomKStake ... > target = 51 * total / 100
    have h1 : 51 * totalStake spos / 100 < totalStake subset := by omega
    -- From b/c < a, derive b < a*c (using Nat.div_lt_iff_lt_mul)
    rw [Nat.div_lt_iff_lt_mul (by omega : (0 : Nat) < 100)] at h1
    omega
  · -- Case: thresholdGo returned spos.length (no k found)
    have heq : computeThreshold spos = spos.length := by
      have := threshold_le_roster_size spos; omega
    rw [heq] at hge
    rw [bottomKStake_all] at hge
    -- totalStake subset ≥ totalStake spos, and 51 < 100, and totalStake spos > 0
    have h1 : totalStake subset * 100 ≥ totalStake spos * 100 := by omega
    have h2 : totalStake spos * 100 > 51 * totalStake spos := by
      rw [Nat.mul_comm (totalStake spos)]
      exact Nat.mul_lt_mul_of_pos_right (by omega : 51 < 100) hstake
    omega

/-- If the roster is non-empty, the threshold is ≤ roster size. -/
theorem threshold_lt_roster_if_possible (spos : List SPO)
    (_hnonempty : spos.length > 0) :
    computeThreshold spos ≤ spos.length :=
  threshold_le_roster_size spos

end BifrostProofs
