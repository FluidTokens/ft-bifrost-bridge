/-
  BifrostProofs.Action
  Protocol actions — labels in the transition system.
-/
import BifrostProofs.Basic

namespace BifrostProofs

/-- Protocol actions that can be applied to the state -/
inductive ProtocolAction where
  /-- A depositor sends BTC to a peg-in Taproot address on Bitcoin -/
  | PegInDeposit       (deposit : Deposit)
  /-- A watchtower creates a PegInRequest UTxO on Cardano with an oracle proof -/
  | CreatePegInRequest (deposit : Deposit) (proof : OracleProof)
  /-- SPOs construct, sign, and post a Treasury Movement transaction -/
  | TreasuryMovement   (tm : TMTransaction) (quorum : QuorumLevel)
  /-- A depositor mints fBTC by spending a PegInRequest with a Schnorr signature -/
  | MintFBTC           (reqIdx : Nat) (sig : SchnorrSig) (tmProof : OracleProof)
  /-- A withdrawer locks fBTC at peg_out.ak for a peg-out -/
  | LockForPegOut      (amount : Nat) (destAddress : ByteArray)
  /-- Anyone completes a peg-out with a Binocular inclusion proof -/
  | FulfillPegOut      (poIdx : Nat) (proof : OracleProof)
  /-- A withdrawer cancels a peg-out (treasury rotated, not fulfilled) -/
  | CancelPegOut       (poIdx : Nat)
  /-- A depositor reclaims BTC via the Taproot timeout script (~30 days) -/
  | DepositorRefund    (depositIdx : Nat)
  /-- DKG completes for a new epoch -/
  | DKG                (epoch : Nat) (result : DKGResult)
  /-- Epoch boundary event -/
  | EpochBoundary
  /-- Watchtower updates the oracle with new block headers -/
  | OracleUpdate       (blocks : List BlockHeader)
  /-- A Treasury Movement is confirmed on Bitcoin (oracle confirms it) -/
  | ConfirmTM          (tmIdx : Nat) (proof : OracleProof)
  /-- Close a PegInRequest (depositor refunded or duplicate) -/
  | ClosePegInRequest  (reqIdx : Nat)
  deriving Repr

end BifrostProofs
