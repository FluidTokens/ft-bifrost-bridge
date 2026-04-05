/-
  BifrostProofs.Basic
  Core types for the Bifrost protocol formal model.
-/

namespace BifrostProofs

-- ByteArray lacks Repr in Lean 4 core; provide one
instance : Repr ByteArray where
  reprPrec ba _ := repr ba.toList

-- Lexicographic ordering on ByteArray
instance : Ord ByteArray where
  compare a b :=
    let minLen := min a.size b.size
    let rec go (i : Nat) : Ordering :=
      if i >= minLen then compare a.size b.size
      else
        match compare (a.get! i) (b.get! i) with
        | .eq => go (i + 1)
        | ord => ord
    go 0

instance : LT ByteArray where
  lt a b := Ord.compare a b == .lt

instance : DecidableEq ByteArray := inferInstance

/-- Public key (abstract) -/
structure PublicKey where
  bytes : ByteArray
  deriving BEq, Hashable, Repr, DecidableEq

/-- Signature (abstract) -/
structure Signature where
  bytes : ByteArray
  deriving BEq, Repr

/-- Ed25519 signature -/
structure Ed25519Sig where
  sig : Signature
  deriving BEq, Repr

/-- Schnorr/BIP340 signature -/
structure SchnorrSig where
  sig : Signature
  deriving BEq, Repr

-- Bitcoin types

/-- A Bitcoin transaction output -/
structure BitcoinTxOutput where
  value        : Nat
  scriptPubKey : ByteArray
  deriving BEq, Repr

/-- A Bitcoin UTxO reference -/
structure BitcoinOutPoint where
  txid : ByteArray
  vout : Nat
  deriving BEq, Hashable, Repr

/-- A Bitcoin UTxO with value -/
structure BitcoinUTxO where
  outpoint : BitcoinOutPoint
  value    : Nat
  deriving BEq, Repr

/-- A Bitcoin transaction (abstract) -/
structure BitcoinTx where
  txid    : ByteArray
  inputs  : List BitcoinOutPoint
  outputs : List BitcoinTxOutput
  deriving Repr

/-- A Bitcoin block header (abstract) -/
structure BlockHeader where
  hash       : ByteArray
  prevHash   : ByteArray
  merkleRoot : ByteArray
  height     : Nat
  chainwork  : Nat
  deriving Repr

-- Cardano types

/-- Cardano credential -/
inductive Credential where
  | vkey   : ByteArray → Credential
  | script : ByteArray → Credential
  deriving BEq, Hashable, Repr

/-- Cardano address -/
structure Address where
  paymentCred : Credential
  stakeCred   : Option Credential := none
  deriving BEq, Repr

/-- A unique deposit identifier (Bitcoin txid + vout) -/
structure DepositId where
  txid : ByteArray
  vout : Nat
  deriving BEq, Hashable, Repr, DecidableEq

-- Protocol-specific types

/-- An SPO in the Bifrost protocol -/
structure SPO where
  poolId         : ByteArray
  bifrostIdPk    : PublicKey
  bifrostUrl     : String
  delegatedStake : Nat
  deriving BEq, Repr, DecidableEq

/-- Epoch keys produced by DKG -/
structure EpochKeys where
  y67 : PublicKey
  y51 : PublicKey
  deriving BEq, Repr, DecidableEq

/-- A roster of SPOs for a given epoch -/
structure Roster where
  members           : List SPO
  threshold67       : Nat
  threshold51       : Nat
  groupKey67        : PublicKey
  groupKey51        : PublicKey
  deriving Repr

/-- DKG result -/
structure DKGResult where
  epochKeys : EpochKeys
  roster    : Roster
  deriving Repr

/-- Oracle inclusion proof (abstract) -/
structure OracleProof where
  blockHash   : ByteArray
  merkleProof : ByteArray
  deriving Repr

/-- Bitcoin treasury address (Taproot) -/
structure TreasuryAddress where
  scriptPubKey : ByteArray
  deriving BEq, Repr, DecidableEq

/-- Peg-in request UTxO on Cardano -/
structure PegInRequest where
  depositId          : DepositId
  rawPegInTx         : ByteArray
  depositorPk        : PublicKey
  amount             : Nat
  treasuryAtCreation : TreasuryAddress
  confirmationHeight : Nat
  deriving BEq, Repr

/-- Peg-out request UTxO on Cardano -/
structure PegOutRequest where
  id                 : Nat
  amount             : Nat
  destAddress        : ByteArray
  treasuryAtCreation : TreasuryAddress
  deriving BEq, Repr

/-- A deposit on Bitcoin (before PegInRequest creation) -/
structure Deposit where
  depositId          : DepositId
  depositorPk        : PublicKey
  amount             : Nat
  treasuryAddress    : TreasuryAddress
  confirmationHeight : Nat
  deriving BEq, Repr

/-- A peg-out payment in a Treasury Movement -/
structure PegOutPayment where
  pegOutId    : Nat
  destAddress : ByteArray
  amount      : Nat
  deriving Repr

/-- Treasury Movement transaction -/
structure TMTransaction where
  txid              : ByteArray
  inputs            : List BitcoinOutPoint
  pegOutPayments    : List PegOutPayment
  newTreasuryOutput : BitcoinTxOutput
  sweepedDeposits   : List DepositId
  fulfilledPegOuts  : List Nat
  deriving Repr

/-- Protocol configuration -/
structure BifrostConfig where
  federationKey   : PublicKey
  feeRateSatPerVb : Nat
  pegOutFee       : Nat
  minDeposit      : Nat
  leaderTimeout   : Nat
  deriving Repr

/-- Oracle state (abstract) -/
structure OracleState where
  confirmedHeight : Nat
  confirmedBlocks : List BlockHeader
  deriving Repr

/-- Quorum level used for signing -/
inductive QuorumLevel where
  | q67        : QuorumLevel
  | q51        : QuorumLevel
  | federation : QuorumLevel
  deriving BEq, Repr

-- Helper functions

def totalStake : List SPO → Nat
  | [] => 0
  | spo :: rest => spo.delegatedStake + totalStake rest

/-- Comparison for sorting SPOs by delegated stake ascending -/
def spoStakeLe (a b : SPO) : Bool := decide (a.delegatedStake ≤ b.delegatedStake)

/-- Stake of the bottom k SPOs by delegation -/
def bottomKStake (spos : List SPO) (k : Nat) : Nat :=
  totalStake ((spos.mergeSort spoStakeLe).take k)

end BifrostProofs
