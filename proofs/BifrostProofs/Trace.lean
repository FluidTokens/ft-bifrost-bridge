/-
  BifrostProofs.Trace
  Valid traces, trace application, and induction principles.
-/
import BifrostProofs.State
import BifrostProofs.Action
import BifrostProofs.Transition

namespace BifrostProofs

/-- A valid trace: a sequence of actions that all succeed starting from state s. -/
inductive ValidTrace : ProtocolState → List ProtocolAction → ProtocolState → Prop where
  | nil  : ∀ (s : ProtocolState), ValidTrace s [] s
  | cons : ∀ (s s' s'' : ProtocolState) (a : ProtocolAction) (rest : List ProtocolAction),
           step s a = some s' →
           ValidTrace s' rest s'' →
           ValidTrace s (a :: rest) s''

/-- Apply a list of actions to a state, returning the final state if all succeed. -/
def applyTrace (s : ProtocolState) : List ProtocolAction → Option ProtocolState
  | [] => some s
  | a :: rest =>
    match step s a with
    | some s' => applyTrace s' rest
    | none => none

/-- applyTrace and ValidTrace are equivalent -/
theorem validTrace_iff_applyTrace (s s' : ProtocolState) (trace : List ProtocolAction) :
    ValidTrace s trace s' ↔ applyTrace s trace = some s' := by
  sorry

/-- Induction principle: if P holds on the initial state and is preserved
    by every valid step, then P holds on any reachable state. -/
theorem trace_induction (P : ProtocolState → Prop) (s s' : ProtocolState)
    (trace : List ProtocolAction)
    (hvt : ValidTrace s trace s')
    (hbase : P s)
    (hstep : ∀ (s₁ s₂ : ProtocolState) (a : ProtocolAction),
             step s₁ a = some s₂ → P s₁ → P s₂) :
    P s' := by
  induction hvt with
  | nil => exact hbase
  | cons s s_mid s' a rest hstep_eq _hvt ih =>
    exact ih (hstep s s_mid a hstep_eq hbase)

/-- A state is reachable if there exists a valid trace from some initial state. -/
def Reachable (s : ProtocolState) : Prop :=
  ∃ (s₀ : ProtocolState) (trace : List ProtocolAction),
    isInitialState s₀ ∧ ValidTrace s₀ trace s

/-- Count occurrences of MintFBTC for a given deposit in a trace -/
def countMints (depositId : DepositId) : List ProtocolAction → Nat
  | [] => 0
  | .MintFBTC _idx _sig _proof :: rest =>
    -- We count this as a mint for depositId if it targets the right request
    -- In practice, this is determined by the state; we track conservatively
    countMints depositId rest + 1
  | _ :: rest => countMints depositId rest

/-- Count mints more precisely using state tracking -/
def countMintsInTrace (depositId : DepositId) :
    ProtocolState → List ProtocolAction → Nat
  | _, [] => 0
  | s, a :: rest =>
    match step s a with
    | some s' =>
      let thisMint := match a with
        | .MintFBTC idx _ _ =>
          if h : idx < s.pegInRequests.length then
            let req := s.pegInRequests.get ⟨idx, h⟩
            if req.depositId == depositId then 1 else 0
          else 0
        | _ => 0
      thisMint + countMintsInTrace depositId s' rest
    | none => 0

end BifrostProofs
