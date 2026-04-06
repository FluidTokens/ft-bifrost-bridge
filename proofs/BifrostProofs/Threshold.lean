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
-- Lemmas about totalStake and bottomKStake
-- ============================================================================

/-- totalStake is invariant under permutation. -/
theorem totalStake_perm {l₁ l₂ : List SPO} (h : l₁.Perm l₂) :
    totalStake l₁ = totalStake l₂ := by
  induction h with
  | nil => rfl
  | cons x _ ih => simp [totalStake]; omega
  | swap x y l => simp [totalStake]; omega
  | trans _ _ ih₁ ih₂ => omega

/-- Taking all elements after sorting preserves the total (mergeSort is a permutation). -/
theorem bottomKStake_all (spos : List SPO) :
    bottomKStake spos spos.length = totalStake spos := by
  unfold bottomKStake
  have hlen : (spos.mergeSort spoStakeLe).length = spos.length := by simp
  rw [← hlen, List.take_length]
  exact totalStake_perm (List.mergeSort_perm spos spoStakeLe)

-- ============================================================================
-- Helpers for the subset-sum proof
-- ============================================================================

theorem spoStakeLe_trans : ∀ (a b c : SPO),
    spoStakeLe a b → spoStakeLe b c → spoStakeLe a c := by
  intro a b c hab hbc
  simp only [spoStakeLe, decide_eq_true_eq] at *
  exact Nat.le_trans hab hbc

theorem spoStakeLe_total : ∀ (a b : SPO),
    (spoStakeLe a b || spoStakeLe b a) = true := by
  intro a b
  simp only [spoStakeLe, Bool.or_eq_true, decide_eq_true_eq]
  exact Nat.le_total a.delegatedStake b.delegatedStake

theorem totalStake_append (l₁ l₂ : List SPO) :
    totalStake (l₁ ++ l₂) = totalStake l₁ + totalStake l₂ := by
  induction l₁ with
  | nil => simp [totalStake]
  | cons x l₁ ih => simp [totalStake, ih]; omega

/-- A nodup list that is a subset of another nodup list has length ≤. -/
theorem nodup_subset_length_le {α : Type _} [DecidableEq α] {l₁ l₂ : List α}
    (hnd₁ : l₁.Nodup) (hnd₂ : l₂.Nodup) (hsub : ∀ x ∈ l₁, x ∈ l₂) :
    l₁.length ≤ l₂.length := by
  induction l₁ generalizing l₂ with
  | nil => exact Nat.zero_le _
  | cons a l₁ ih =>
    have ha_l₂ : a ∈ l₂ := hsub a List.mem_cons_self
    have ha_not_l₁ : a ∉ l₁ := (List.nodup_cons.mp hnd₁).1
    have hnd₁' : l₁.Nodup := (List.nodup_cons.mp hnd₁).2
    have hnd₂' : (l₂.erase a).Nodup := hnd₂.erase a
    have hsub' : ∀ x ∈ l₁, x ∈ l₂.erase a := by
      intro x hx
      have hne : x ≠ a := fun h => ha_not_l₁ (h ▸ hx)
      exact (List.mem_erase_of_ne hne).mpr (hsub x (List.mem_cons_of_mem a hx))
    have ih_result := ih hnd₁' hnd₂' hsub'
    have hlen_erase : (l₂.erase a).length = l₂.length - 1 := by
      simp [ha_l₂]
    rw [hlen_erase] at ih_result
    have hl₂_pos : 0 < l₂.length := by
      cases l₂ with
      | nil => exact absurd ha_l₂ List.not_mem_nil
      | cons _ _ => exact Nat.succ_pos _
    simp only [List.length_cons]
    omega

attribute [local instance] boolRelToRel

/-- For a sorted ascending Nodup list, any k-element Nodup subset has
    totalStake ≥ totalStake of the first k elements. -/
theorem sorted_subset_ge_take (l s : List SPO) (k : Nat)
    (hsorted : l.Pairwise spoStakeLe)
    (hnodup_l : l.Nodup)
    (hsub : ∀ x ∈ s, x ∈ l)
    (hnodup_s : s.Nodup)
    (hlen : s.length = k) :
    totalStake s ≥ totalStake (l.take k) := by
  induction l generalizing s k with
  | nil =>
    have : s = [] := by
      cases s with
      | nil => rfl
      | cons x _ => exact absurd (hsub x List.mem_cons_self) List.not_mem_nil
    subst this; subst hlen; simp [totalStake]
  | cons x l' ih =>
    by_cases hk : k = 0
    · subst hk; simp [totalStake]
    · obtain ⟨k', rfl⟩ : ∃ k', k = k' + 1 := ⟨k - 1, by omega⟩
      -- (x :: l').take (k'+1) = x :: l'.take k'
      rw [List.take_succ_cons]
      simp only [totalStake]
      -- Sorted/Nodup of tail
      have hsorted' := hsorted.tail
      have hnodup_l' : l'.Nodup := (List.nodup_cons.mp hnodup_l).2
      have hx_not_l' : x ∉ l' := (List.nodup_cons.mp hnodup_l).1
      by_cases hxs : x ∈ s
      · -- Case A: x ∈ s — peel x from both sides
        obtain ⟨s₁, s₂, rfl⟩ := List.append_of_mem hxs
        -- totalStake (s₁ ++ x :: s₂) = x.dS + totalStake (s₁ ++ s₂)
        have hts : totalStake (s₁ ++ x :: s₂) =
            x.delegatedStake + totalStake (s₁ ++ s₂) := by
          simp [totalStake_append, totalStake]; omega
        rw [hts]
        -- Suffices: totalStake (s₁ ++ s₂) ≥ totalStake (l'.take k')
        suffices h : totalStake (s₁ ++ s₂) ≥ totalStake (l'.take k') by omega
        apply ih
        · exact hsorted'
        · exact hnodup_l'
        · -- s₁ ++ s₂ ⊆ l'
          intro y hy
          have hy_in_s : y ∈ s₁ ++ x :: s₂ := by
            rcases List.mem_append.mp hy with h | h
            · exact List.mem_append_left _ h
            · exact List.mem_append_right _ (List.mem_cons_of_mem x h)
          have hy_in_xl : y ∈ x :: l' := hsub y hy_in_s
          rcases List.mem_cons.mp hy_in_xl with heq | h
          · -- heq : y = x, contradicts Nodup (s₁ ++ x :: s₂)
            exfalso
            rw [heq] at hy
            have ⟨_, hnd_xs, hdisj⟩ := List.nodup_append.mp hnodup_s
            have hx_not_s2 : x ∉ s₂ := (List.nodup_cons.mp hnd_xs).1
            rcases List.mem_append.mp hy with h1 | h2
            · exact absurd rfl (hdisj x h1 x List.mem_cons_self)
            · exact hx_not_s2 h2
          · exact h
        · -- Nodup (s₁ ++ s₂)
          have hsub_sl : List.Sublist (s₁ ++ s₂) (s₁ ++ x :: s₂) :=
            List.Sublist.append (List.Sublist.refl s₁)
              (List.Sublist.cons x (List.Sublist.refl s₂))
          exact List.Nodup.sublist hsub_sl hnodup_s
        · -- length
          have : (s₁ ++ x :: s₂).length = k' + 1 := hlen
          simp [List.length_append] at this ⊢; omega
      · -- Case B: x ∉ s — s ⊆ l', use IH then compare take k l' vs take k (x::l')
        have hsub' : ∀ y ∈ s, y ∈ l' := by
          intro y hy
          rcases List.mem_cons.mp (hsub y hy) with rfl | h
          · exact absurd hy hxs
          · exact h
        have ih_result := ih s (k' + 1) hsorted' hnodup_l' hsub' hnodup_s hlen
        -- ih_result : totalStake s ≥ totalStake (l'.take (k' + 1))
        -- Goal: totalStake s ≥ x.delegatedStake + totalStake (l'.take k')
        -- Suffices: totalStake (l'.take (k'+1)) ≥ x.dS + totalStake (l'.take k')
        suffices h : totalStake (l'.take (k' + 1)) ≥
            x.delegatedStake + totalStake (l'.take k') by omega
        -- k'+1 ≤ l'.length (since s ⊆ l', |s| = k'+1, both Nodup)
        have hk_le : k' + 1 ≤ l'.length := by
          have := nodup_subset_length_le hnodup_s hnodup_l' hsub'
          omega
        -- l'.take (k'+1) = l'.take k' ++ [l'[k']]
        have hk_lt : k' < l'.length := by omega
        have htake : l'.take (k' + 1) = l'.take k' ++ [l'[k']] := by
          rw [List.take_succ, List.getElem?_eq_getElem hk_lt, Option.toList_some]
        rw [htake, totalStake_append]
        have hts1 : totalStake [l'[k']] = l'[k'].delegatedStake := by
          simp [totalStake]
        rw [hts1]
        -- Need: l'[k'].dS ≥ x.dS, from Pairwise spoStakeLe (x :: l')
        have ⟨hforall, _⟩ := List.pairwise_cons.mp hsorted
        have hmem : l'[k'] ∈ l' := List.getElem_mem hk_lt
        have hle := hforall l'[k'] hmem
        simp [spoStakeLe, decide_eq_true_eq] at hle
        omega

/-- Any subset (drawing without replacement) has total stake ≥ bottom-k stake. -/
theorem any_subset_ge_bottom (spos : List SPO) (subset : List SPO) (t : Nat)
    (hsub : ∀ s ∈ subset, s ∈ spos)
    (hnodup_sub : subset.Nodup)
    (hnodup_spos : spos.Nodup)
    (hcard : subset.length = t) :
    totalStake subset ≥ bottomKStake spos t := by
  unfold bottomKStake
  apply sorted_subset_ge_take
  · exact List.sorted_mergeSort spoStakeLe_trans spoStakeLe_total spos
  · exact ((List.mergeSort_perm spos spoStakeLe).nodup_iff).mpr hnodup_spos
  · intro x hx; exact (List.mergeSort_perm spos spoStakeLe).mem_iff.mpr (hsub x hx)
  · exact hnodup_sub
  · exact hcard

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
