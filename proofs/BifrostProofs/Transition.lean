/-
  BifrostProofs.Transition
  State transition function: step : State → Action → Option State
-/
import BifrostProofs.Basic
import BifrostProofs.State
import BifrostProofs.Action
import BifrostProofs.Axioms

namespace BifrostProofs

-- Decidable membership for our types via BEq
instance : BEq DepositId := inferInstance

/-- Remove element at index from a list -/
def eraseIdx {α : Type} (l : List α) (idx : Nat) : List α :=
  let rec go (i : Nat) : List α → List α
    | [] => []
    | x :: xs => if i == idx then xs else x :: go (i + 1) xs
  go 0 l

/-- The transition function. Returns `none` for invalid actions. -/
def step (s : ProtocolState) (a : ProtocolAction) : Option ProtocolState :=
  match a with

  -- A depositor sends BTC to a peg-in address on Bitcoin
  | .PegInDeposit deposit =>
    some { s with
      pendingDeposits := s.pendingDeposits ++ [deposit]
    }

  -- A watchtower creates a PegInRequest on Cardano
  | .CreatePegInRequest deposit _proof =>
    if s.pendingDeposits.any (· == deposit)
       && (s.pegInRequests.filter (fun r => r.depositId == deposit.depositId)).length == 0
    then
      let req : PegInRequest := {
        depositId          := deposit.depositId
        rawPegInTx         := ByteArray.empty
        depositorPk        := deposit.depositorPk
        amount             := deposit.amount
        treasuryAtCreation := deposit.treasuryAddress
        confirmationHeight := deposit.confirmationHeight
      }
      some { s with
        pegInRequests := s.pegInRequests ++ [req]
      }
    else none

  -- SPOs sign and post a Treasury Movement transaction
  | .TreasuryMovement tm _quorum =>
    let allSweepsValid := tm.sweepedDeposits.all
      (fun did => s.pegInRequests.any (fun r => r.depositId == did))
    let allPayoutsValid := tm.fulfilledPegOuts.all
      (fun poId => s.pendingPegOuts.any (fun po => po.id == poId))
    if allSweepsValid && allPayoutsValid then
      let sweptAmount := s.pegInRequests
        |>.filter (fun r => tm.sweepedDeposits.any (· == r.depositId))
        |>.foldl (fun acc r => acc + r.amount) 0
      let paidAmount := tm.pegOutPayments.foldl (fun acc p => acc + p.amount) 0
      some { s with
        treasuryUTxO := {
          outpoint := { txid := tm.txid, vout := 0 }
          value    := s.treasuryUTxO.value + sweptAmount - paidAmount
        }
        postedTMs := s.postedTMs ++ [tm]
        lastTMTxid := some tm.txid
      }
    else none

  -- Depositor mints fBTC
  | .MintFBTC reqIdx _sig _tmProof =>
    if h : reqIdx < s.pegInRequests.length then
      let req := s.pegInRequests.get ⟨reqIdx, h⟩
      if !(s.completedPegIns.any (· == req.depositId)) then
        some { s with
          pegInRequests   := eraseIdx s.pegInRequests reqIdx
          completedPegIns := s.completedPegIns ++ [req.depositId]
          circulatingFBTC := s.circulatingFBTC + req.amount
        }
      else none
    else none

  -- Withdrawer locks fBTC for a peg-out
  | .LockForPegOut amount destAddress =>
    if amount > 0 && amount ≤ s.circulatingFBTC then
      let poId := s.pendingPegOuts.length
      let po : PegOutRequest := {
        id                 := poId
        amount             := amount
        destAddress        := destAddress
        treasuryAtCreation := s.currentTreasuryAddress
      }
      some { s with
        pendingPegOuts  := s.pendingPegOuts ++ [po]
        circulatingFBTC := s.circulatingFBTC - amount
      }
    else none

  -- Anyone completes a peg-out with an oracle proof
  -- (oracle proof validity is axiomatized; we accept it here)
  | .FulfillPegOut poIdx _proof =>
    if _h : poIdx < s.pendingPegOuts.length then
      some { s with
        pendingPegOuts := eraseIdx s.pendingPegOuts poIdx
      }
    else none

  -- Withdrawer cancels peg-out (treasury rotated)
  | .CancelPegOut poIdx =>
    if h : poIdx < s.pendingPegOuts.length then
      let po := s.pendingPegOuts.get ⟨poIdx, h⟩
      if decide (s.currentTreasuryAddress ≠ po.treasuryAtCreation) then
        some { s with
          pendingPegOuts  := eraseIdx s.pendingPegOuts poIdx
          circulatingFBTC := s.circulatingFBTC + po.amount
        }
      else none
    else none

  -- Depositor reclaims BTC after timeout
  | .DepositorRefund depositIdx =>
    if h : depositIdx < s.pendingDeposits.length then
      let deposit := s.pendingDeposits.get ⟨depositIdx, h⟩
      if s.bitcoinHeight ≥ deposit.confirmationHeight + 4320 then
        some { s with
          pendingDeposits := eraseIdx s.pendingDeposits depositIdx
        }
      else none
    else none

  -- DKG completion
  | .DKG epoch result =>
    if epoch == s.currentEpoch + 1 then
      some { s with
        epochKeys     := result.epochKeys
        currentRoster := some result.roster
      }
    else none

  -- Epoch boundary
  | .EpochBoundary =>
    some { s with
      currentEpoch := s.currentEpoch + 1
    }

  -- Oracle update with new block headers
  | .OracleUpdate blocks =>
    match blocks.getLast? with
    | some lastBlock =>
      if lastBlock.height > s.oracleState.confirmedHeight then
        some { s with
          oracleState := {
            confirmedHeight := lastBlock.height
            confirmedBlocks := s.oracleState.confirmedBlocks ++ blocks
          }
          bitcoinHeight := lastBlock.height
        }
      else none
    | none => none

  -- TM confirmed on Bitcoin
  | .ConfirmTM tmIdx _proof =>
    if h : tmIdx < s.postedTMs.length then
      let tm := s.postedTMs.get ⟨tmIdx, h⟩
      let newPendingDeposits := s.pendingDeposits.filter
        (fun d => !(tm.sweepedDeposits.any (· == d.depositId)))
      some { s with
        confirmedTMs    := s.confirmedTMs ++ [tm]
        pendingDeposits := newPendingDeposits
      }
    else none

  -- Close a PegInRequest (refunded or duplicate)
  | .ClosePegInRequest reqIdx =>
    if h : reqIdx < s.pegInRequests.length then
      let req := s.pegInRequests.get ⟨reqIdx, h⟩
      if !(s.pendingDeposits.any (fun d => d.depositId == req.depositId))
         || s.completedPegIns.any (· == req.depositId)
      then
        some { s with
          pegInRequests := eraseIdx s.pegInRequests reqIdx
        }
      else none
    else none

end BifrostProofs
