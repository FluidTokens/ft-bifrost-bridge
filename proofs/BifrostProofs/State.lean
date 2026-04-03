/-
  BifrostProofs.State
  Protocol state definition and initial state.
-/
import BifrostProofs.Basic

namespace BifrostProofs

/-- The complete protocol state spanning both chains + oracle -/
structure ProtocolState where
  -- Cardano side
  pegInRequests   : List PegInRequest
  pendingPegOuts  : List PegOutRequest
  completedPegIns : List DepositId       -- models the Merkle Patricia Trie
  circulatingFBTC : Nat
  spoRegistry     : SPORegistry
  epochKeys       : EpochKeys
  currentEpoch    : Nat
  config          : BifrostConfig
  currentRoster   : Option Roster
  bans            : List BanRecord
  -- Bitcoin side
  treasuryUTxO    : BitcoinUTxO
  bitcoinHeight   : Nat
  pendingDeposits : List Deposit         -- deposits on Bitcoin not yet swept
  -- Oracle
  oracleState     : OracleState
  -- Treasury Movement tracking
  lastTMTxid      : Option ByteArray     -- previous TM txid (for leader election)
  postedTMs       : List TMTransaction   -- TMs posted to treasury_movement.ak
  confirmedTMs    : List TMTransaction   -- TMs confirmed on Bitcoin
  deriving Repr

/-- Current treasury balance (derived from treasuryUTxO) -/
def ProtocolState.treasuryBalance (s : ProtocolState) : Nat :=
  s.treasuryUTxO.value

/-- Current treasury address -/
def ProtocolState.currentTreasuryAddress (s : ProtocolState) : TreasuryAddress :=
  -- In the real protocol, this is derived from epochKeys.y51, y67, and federation key
  -- via Taproot address construction. Here we model it abstractly.
  { scriptPubKey := s.epochKeys.y51.bytes }

/-- Whether a deposit has been swept by a Treasury Movement -/
def depositSwept (s : ProtocolState) (d : Deposit) : Prop :=
  ∃ tm ∈ s.confirmedTMs, d.depositId ∈ tm.sweepedDeposits

/-- Whether a peg-out has been fulfilled -/
def pegoutFulfilled (s : ProtocolState) (po : PegOutRequest) : Prop :=
  ∃ tm ∈ s.confirmedTMs, po.id ∈ tm.fulfilledPegOuts

/-- Whether the treasury has rotated since a peg-out was created -/
def treasuryRotated (s : ProtocolState) (po : PegOutRequest) : Prop :=
  s.currentTreasuryAddress ≠ po.treasuryAtCreation

/-- The initial state of the protocol at bootstrap -/
def initialProtocolState (config : BifrostConfig) (bootstrapKeys : EpochKeys)
    (genesisUtxo : BitcoinUTxO) : ProtocolState :=
  { pegInRequests   := []
    pendingPegOuts  := []
    completedPegIns := []
    circulatingFBTC := 0
    spoRegistry     := { nodes := [] }
    epochKeys       := bootstrapKeys
    currentEpoch    := 0
    config          := config
    currentRoster   := none
    bans            := []
    treasuryUTxO    := genesisUtxo
    bitcoinHeight   := 0
    pendingDeposits := []
    oracleState     := { confirmedHeight := 0, confirmedBlocks := [] }
    lastTMTxid      := none
    postedTMs       := []
    confirmedTMs    := []
  }

/-- Predicate: state is an initial state -/
def isInitialState (s : ProtocolState) : Prop :=
  s.pegInRequests = []
  ∧ s.pendingPegOuts = []
  ∧ s.completedPegIns = []
  ∧ s.circulatingFBTC = 0
  ∧ s.pendingDeposits = []
  ∧ s.postedTMs = []
  ∧ s.confirmedTMs = []

end BifrostProofs
