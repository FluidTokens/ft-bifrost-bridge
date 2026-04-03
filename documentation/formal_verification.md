# Bifrost Protocol Formal Verification

## 1. Introduction

This document presents a feasibility assessment and research plan for formally verifying the Bifrost bridge protocol in Lean 4. The goal is to prove safety and liveness properties at the **protocol level**, axiomatizing lower-level components (on-chain validators, cryptographic primitives, the Binocular Oracle, and Bitcoin mechanics). Each axiom corresponds to an independently verifiable component — validator axioms can later be discharged via CardanoBlaster, FROST axioms follow from RFC 9591 security analysis, and oracle axioms from the Binocular whitepaper.

### 1.1 Why Lean 4?

- **CardanoBlaster** (an existing Lean 4 project at `lantr-io/CardanoBlaster`) already formalizes the complete UPLC execution layer with a CEK machine, `#import_uplc` for compiled Plutus scripts, and a `blaster` tactic for automated proofs. This provides a natural path from protocol-level axioms to validator-level discharge.
- Lean 4 is both a programming language and a theorem prover, allowing executable specifications alongside proofs.
- Strong community adoption in formal mathematics (Mathlib) and growing use in verified systems.

### 1.2 Approach: Abstract State Machine

Model Bifrost as a labeled transition system:

- **State**: Bitcoin UTxOs + Cardano UTxOs + Oracle state + SPO registry + epoch info + circulating fBTC supply
- **Actions**: `PegInDeposit`, `CreatePegInRequest`, `TreasuryMovement`, `MintFBTC`, `LockForPegOut`, `FulfillPegOut`, `CancelPegOut`, `DepositorRefund`, `SPORegister`, `SPODeregister`, `DKG`, `EpochBoundary`, `OracleUpdate`
- **Transition function**: `step : State → Action → Option State` (returns `none` for invalid actions)

Properties are stated as invariants over all valid traces from the initial state.

### 1.3 Axiom Strategy

Everything below the protocol level is axiomatized:

| Component | What we axiomatize | How to discharge later |
|-----------|-------------------|----------------------|
| **Cryptography** | FROST unforgeability (EUF-CMA), DKG consistency, Schnorr soundness | RFC 9591 security analysis |
| **On-chain validators** | NFT uniqueness, burn-on-prove, authorization checks, linked-list ordering | CardanoBlaster proofs on compiled UPLC |
| **Bitcoin** | Taproot address derivation, timelocks, UTXO model, transaction finality | Bitcoin protocol specification |
| **Oracle** | Binocular soundness under 1-honest-watchtower assumption | Binocular whitepaper proofs |

---

## 2. Feasibility Assessment

### 2.1 What CardanoBlaster Provides Today

CardanoBlaster formalizes the complete UPLC execution layer in Lean 4:

- **CEK machine**: `cekExecuteProgram` executes compiled Plutus scripts with a step budget
- **Script import**: `#import_uplc` loads compiled `.flat` files directly
- **Data type**: `Data.Constr | Map | List | I | B` — the Plutus on-chain data representation
- **Blaster tactic**: Automated theorem prover that discharges proofs about script execution
- **Predicates**: `isSuccessful`, `isErrorState` over CEK machine `State`

### 2.2 Current Limitations

| Limitation | Impact on Bifrost | Workaround |
|-----------|-------------------|------------|
| Crypto builtins are stubs (all return `none` → `State.Error`) | SPO registration validator (`verifyEd25519Signature`) always errors | Axiomatize crypto builtins with abstract signatures |
| No UTxO/ledger model | Cannot reason about multi-transaction sequences or global state | Build abstract UTxO transition model |
| No transaction context structure | ScriptContext is opaque `Data`; must manually construct encodings | Build Plutus V3 ScriptContext encoder |
| No cross-chain model | Cannot express conservation across Bitcoin + Cardano | Build minimal Bitcoin model |

### 2.3 Feasibility Summary

| Category | Feasibility | Notes |
|----------|------------|-------|
| Protocol-level properties (this document) | **HIGH** | Abstract state machine, axiomatized components — no dependency on CardanoBlaster |
| Validator-level properties (no crypto) | **HIGH** | Achievable now via CardanoBlaster; most validators don't call crypto builtins |
| Validator-level properties (with crypto) | **BLOCKED** | Requires implementing crypto builtins in `Evaluate.lean` |
| Cross-chain conservation | **MEDIUM** | Requires Bitcoin + Cardano models linked via oracle |

### 2.4 Tractable Validators (for future axiom discharge)

Most Bifrost validators do not call crypto builtins on their primary paths. The ZK verification functions are currently stubs returning `True`. Authorization mostly uses `extra_signatories` list membership.

| Validator | Tractable now? | Blocker |
|-----------|---------------|---------|
| `config.ak` (mint + spend) | Yes | — |
| `treasury-info.ak` (mint + spend) | Yes | ZK stub = True |
| `peg-in.ak` (mint + withdraw) | Yes | ZK stub = True |
| `btc-mint.ak` (mint) | Yes | — |
| `peg-out-private.ak` (mint + withdraw) | Yes | ZK stub = True |
| `general-spend.ak` | Yes | — |
| `registered-SPOs.ak` | Partial | `Register` path requires Ed25519 |

---

## 3. Top 5 Theorems

These are the highest-value theorems for the Bifrost protocol, ordered by criticality.

### 3.1 Conservation of Funds

Total fBTC on Cardano never exceeds BTC held in the treasury.

```lean
theorem conservation_of_funds :
    ∀ (s : State) (trace : List Action),
      initialState s →
      validTrace s trace →
      let s' := applyTrace s trace
      totalFBTC s' ≤ treasuryBTC s'
```

**Proof sketch**: By induction on the trace. Each action preserves the invariant:

- `MintFBTC`: increases fBTC by amount X, but requires a PegInRequest whose deposit (amount X) was swept into treasury by a prior `TreasuryMovement`
- `FulfillPegOut`: decreases fBTC and treasury by the same amount X
- `CancelPegOut`: returns fBTC to user, no treasury change
- `TreasuryMovement`: increases treasury (sweeps peg-ins) and decreases treasury (fulfills peg-outs) in lockstep with corresponding Cardano-side operations
- All other actions: neither fBTC nor treasury changes

### 3.2 No Double Minting

Each Bitcoin deposit produces fBTC at most once.

```lean
theorem no_double_mint :
    ∀ (s : State) (trace : List Action),
      initialState s →
      validTrace s trace →
      ∀ (depositId : DepositId),
        countMints depositId trace ≤ 1
```

**Proof sketch**: `MintFBTC` consumes (removes) the PegInRequest from state and inserts the deposit into the completed peg-ins trie. The PegInRequest is created once per deposit (NFT uniqueness axiom) and removed on mint. The trie non-inclusion check (axiom) prevents re-minting via a duplicate PegInRequest.

### 3.3 Fail-Safe Recovery

No permanent loss of funds — depositors can always recover BTC; withdrawers can always recover fBTC.

```lean
theorem failsafe_depositor_recovery :
    ∀ (s : State) (deposit : Deposit),
      deposit ∈ s.pendingDeposits →
      ¬ (depositSwept s deposit) →
      bitcoinHeight s ≥ deposit.confirmationHeight + 4320 →
      canApply s (DepositorRefund deposit)

theorem failsafe_withdrawer_recovery :
    ∀ (s : State) (pegout : PegOutRequest),
      pegout ∈ s.pendingPegOuts →
      treasuryRotated s pegout →
      ¬ (pegoutFulfilled s pegout) →
      canApply s (CancelPegOut pegout)
```

**Proof sketch**: Depositor recovery follows from the Taproot timeout script axiom (spendable after 4320 blocks). Withdrawer recovery follows from the validator axiom allowing cancel when the current treasury address differs from the datum's treasury address.

### 3.4 Threshold Security

Any subset of $t$ FROST signers controls more than the security threshold of total delegated stake.

```lean
theorem threshold_guarantees_stake :
    ∀ (roster : Roster) (subset : Finset SPO),
      subset.card = roster.threshold →
      subset ⊆ roster.members →
      totalStake subset > roster.securityThreshold * totalStake roster.members
```

**Proof sketch**: By construction of threshold $t$ as `min { k : bottomKStake roster k > securityThreshold }`. Any subset of size $t$ has at least as much total stake as the bottom $t$ SPOs by stake, which exceeds the security threshold by definition.

### 3.5 Peg-Out Liveness

Under honest SPO majority + 1 honest watchtower, every peg-out is eventually fulfilled or cancellable.

```lean
theorem pegout_liveness :
    ∀ (s : State) (pegout : PegOutRequest),
      pegout ∈ s.pendingPegOuts →
      honestSPOMajority s →
      honestWatchtowerExists s →
      eventually (fun s' =>
        pegoutFulfilled s' pegout ∨ canApply s' (CancelPegOut pegout))
```

**Proof sketch**: With honest SPO majority, the FROST signing cascade (67% → 51% → federation) eventually produces a signed Treasury Movement transaction (signing cascade liveness). With 1 honest watchtower, the TM is relayed to Bitcoin and the Bitcoin confirmation eventually reaches the oracle (oracle liveness). Once confirmed, anyone can complete the peg-out on Cardano. If the treasury rotates before fulfillment, the withdrawer can cancel.

---

## 4. Complete Property List

### 4.1 Conservation & Value Integrity

| ID | Property | Depends on |
|----|----------|-----------|
| C1 | `totalFBTC ≤ treasuryBTC` (global invariant) | C2, C3, C4, C5 |
| C2 | `MintFBTC` increases fBTC by exactly the peg-in deposit amount | Axiom: validator checks amount |
| C3 | `FulfillPegOut` decreases fBTC and treasury by exactly the same amount | Axiom: validator burns exact amount |
| C4 | `CancelPegOut` returns fBTC to user, no treasury change | Axiom: validator returns locked fBTC |
| C5 | `TreasuryMovement`: swept amount = sum of peg-in deposits consumed | Axiom: FROST signers construct correct TM |

### 4.2 No Double Processing

| ID | Property | Depends on |
|----|----------|-----------|
| D1 | Each deposit mints fBTC at most once | D2, D3, D5 |
| D2 | PegInRequest is removed from state on `MintFBTC` | Axiom: validator burns NFT |
| D3 | PegInRequest created at most once per deposit | Axiom: NFT name unique per UTxO ref |
| D4 | Each peg-out is fulfilled at most once | Axiom: PegOut NFT burned on fulfill |
| D5 | Completed peg-ins trie prevents re-minting across PegInRequests | Axiom: trie non-inclusion proof checked |

### 4.3 Fail-Safe Recovery

| ID | Property | Depends on |
|----|----------|-----------|
| F1 | Depositor can reclaim BTC after ~30 days if not swept | Axiom: Taproot timeout script spendable |
| F2 | Withdrawer can cancel peg-out if treasury rotated | Axiom: validator allows cancel when `treasury ≠ datum.treasury` |
| F3 | Federation can sign TM if both 67% and 51% quorum fail | Axiom: federation key in Taproot tree, timelock expires |
| F4 | PegInRequest closable if deposit already refunded by depositor | Axiom: validator checks refund script witness |
| F5 | PegInRequest closable if duplicate (trie inclusion proof) | Axiom: validator checks trie inclusion |

### 4.4 Authorization & Access Control

| ID | Property | Depends on |
|----|----------|-----------|
| A1 | Treasury spending requires FROST threshold signature or federation after timeout | Axiom: Taproot spending rules, FROST unforgeability |
| A2 | fBTC minting requires consuming a proven PegInRequest | Axiom: `btc-mint` validator checks peg-in withdraw |
| A3 | Peg-out cancel requires withdrawer's signature | Axiom: validator checks `extra_signatories` |
| A4 | Peg-in completion requires depositor's Bitcoin Schnorr signature | Axiom: `bridged_asset.ak` checks Schnorr sig |
| A5 | SPO registration requires cold key Ed25519 signature | Axiom: minting policy verifies signature |
| A6 | Config updates require admin credential | Axiom: config spend validator checks admin |

### 4.5 SPO Registry & DKG

| ID | Property | Depends on |
|----|----------|-----------|
| R1 | Registry is always a sorted linked-list (no duplicates) | Axiom: ordered linked-list validator |
| R2 | Threshold $t$ ensures any $t$ signers > `securityThreshold`% stake | Threshold computation correctness |
| R3 | DKG produces consistent group key (all honest SPOs agree) | Axiom: FROST DKG correctness |
| R4 | No single SPO learns the group private key | Axiom: DKG secrecy |
| R5 | Misbehaving SPOs are detectable and bannable | Axiom: ZK misbehavior proofs sound |
| R6 | Ban duration increases exponentially on repeat offenses | State machine rule |

### 4.6 FROST Signing & Treasury Movement

| ID | Property | Depends on |
|----|----------|-----------|
| S1 | FROST group signature is valid BIP340 Schnorr (verifiable by Bitcoin) | Axiom: FROST correctness |
| S2 | Cannot forge TM signature without threshold of signing shares | Axiom: FROST EUF-CMA |
| S3 | All honest SPOs construct identical TM transaction (deterministic) | Axiom: deterministic construction rules |
| S4 | Signing cascade: 67% tried first, then 51%, then federation | State machine rule |
| S5 | Leader election is deterministic from `prev_tm_txid` | Pure function, provable |
| S6 | Timeout cascade ensures some SPO submits within bounded time | R1, S5 |

### 4.7 Oracle Properties

| ID | Property | Depends on |
|----|----------|-----------|
| O1 | Confirmed blocks reflect true Bitcoin canonical chain (1-honest-watchtower) | Axiom: Binocular soundness |
| O2 | 100 confirmations + challenge period before block is usable | Axiom: oracle validator rules |
| O3 | Merkle inclusion proofs are sound | Axiom: Merkle tree properties |
| O4 | Challenge period prevents pre-computation attacks | O1, timing model |

### 4.8 Liveness & Censorship Resistance

| ID | Property | Depends on |
|----|----------|-----------|
| L1 | Peg-out eventually fulfilled or cancellable (honest majority + 1 watchtower) | S1–S4, O1, F2 |
| L2 | Peg-in eventually completable (honest majority + 1 watchtower) | S1–S4, O1, A4 |
| L3 | Any user can become a watchtower (permissionless) | Axiom: no on-chain gating |
| L4 | Depositor can self-serve entire peg-in (create own PegInRequest) | L3, A4 |
| L5 | Peg-out completion is permissionless | Axiom: anyone can submit Binocular proof |
| L6 | Bridge cannot permanently stall (federation fallback) | F3, S4 |

### 4.9 Epoch Transitions

| ID | Property | Depends on |
|----|----------|-----------|
| E1 | Treasury moves to new roster's address at epoch boundary | S1–S4, DKG success |
| E2 | Pending peg-ins roll over to next epoch if not swept | State machine rule |
| E3 | New roster can only control treasury after TM confirmed on Bitcoin | O1, Taproot derivation |
| E4 | Old roster loses treasury control after TM spends old address | Bitcoin UTXO model |

---

## 5. Axiom Catalog

### 5.1 Cryptographic Axioms

```lean
-- FROST threshold signatures
axiom frost_unforgeability :
    ∀ (groupKey : PublicKey) (msg : ByteArray) (sig : Signature),
      frostVerify groupKey msg sig →
      thresholdSignersParticipated groupKey sig

axiom frost_correctness :
    ∀ (shares : Finset SigningShare) (msg : ByteArray),
      shares.card ≥ threshold →
      ∃ sig, frostSign shares msg = some sig ∧ validSchnorr groupKey msg sig

-- DKG
axiom dkg_consistency :
    ∀ (epoch : Nat) (participants : Finset SPO),
      allHonestComplete participants →
      sameGroupKey participants

axiom dkg_secrecy :
    ∀ (epoch : Nat) (participants : Finset SPO) (adversary : SPO),
      adversary ∈ participants →
      ¬ canComputeGroupPrivateKey adversary

-- Ed25519 (SPO registration)
axiom ed25519_unforgeability :
    ∀ (pk msg sig : ByteArray),
      verifyEd25519Signature pk msg sig →
      existsSecretKey pk msg sig

-- Schnorr / BIP340 (depositor signature)
axiom schnorr_unforgeability :
    ∀ (pk msg sig : ByteArray),
      verifySchnorrSecp256k1Signature pk msg sig →
      signerKnowsSecretKey pk
```

**Discharge path**: FROST axioms follow from RFC 9591 security proofs under the discrete logarithm assumption. Ed25519/Schnorr axioms are standard assumptions.

### 5.2 On-Chain Validator Axioms

```lean
-- NFT uniqueness
axiom peg_in_nft_unique :
    ∀ (deposit : Deposit), atMostOnePegInRequest deposit

axiom peg_out_nft_unique :
    ∀ (pegout : PegOutRequest), atMostOnePegOutNFT pegout

-- Burn on prove/fulfill
axiom burn_on_mint_fbtc :
    ∀ (s s' : State) (req : PegInRequest),
      mintFBTC s req s' → req ∉ s'.pegInRequests

axiom burn_on_fulfill_pegout :
    ∀ (s s' : State) (po : PegOutRequest),
      fulfillPegOut s po s' → po ∉ s'.pendingPegOuts

-- Mint requires proven peg-in
axiom mint_requires_proven_pegin :
    ∀ (s : State) (mint : MintAction),
      validMint s mint → mint.pegInRequest ∈ s.provenPegIns

-- Completed peg-ins trie
axiom trie_non_inclusion_checked :
    ∀ (s : State) (mint : MintAction),
      validMint s mint → mint.depositId ∉ s.completedPegIns

axiom trie_insertion_on_mint :
    ∀ (s s' : State) (mint : MintAction),
      mintFBTC s mint s' → mint.depositId ∈ s'.completedPegIns

-- Peg-out cancel authorization
axiom pegout_cancel_requires_rotation :
    ∀ (s : State) (po : PegOutRequest),
      validCancel s po →
      s.currentTreasuryAddress ≠ po.treasuryAtCreation

-- Linked-list ordering
axiom registry_sorted :
    ∀ (s : State), isSorted s.spoRegistry.nodes
```

**Discharge path**: Each axiom corresponds to a specific validator check. These can be verified via CardanoBlaster proofs on the compiled UPLC (`.flat` files from `aiken build`).

### 5.3 Bitcoin Axioms

```lean
-- Taproot timeout
axiom taproot_timeout_spendable :
    ∀ (deposit : Deposit) (height : Nat),
      height ≥ deposit.height + 4320 →
      depositorCanSpend deposit height

-- UTXO spent once
axiom bitcoin_utxo_spent_once :
    ∀ (utxo : BitcoinUTxO) (tx1 tx2 : BitcoinTx),
      spends tx1 utxo → spends tx2 utxo → tx1 = tx2

-- Transaction finality
axiom bitcoin_tx_final :
    ∀ (tx : BitcoinTx) (block : Block),
      confirmedInBlock tx block →
      confirmations block ≥ 100 →
      ¬ canRevert tx
```

**Discharge path**: Bitcoin protocol specification and BIP341 (Taproot spending rules).

### 5.4 Oracle Axioms

```lean
-- Binocular soundness (1-honest-watchtower assumption)
axiom oracle_soundness :
    honestWatchtowerExists →
    ∀ (block : Block),
      oracleConfirmed block → onCanonicalChain block

-- Merkle proof soundness
axiom merkle_proof_sound :
    ∀ (tx : BitcoinTx) (block : Block) (proof : MerkleProof),
      verifyMerkleProof tx block proof →
      tx ∈ block.transactions

-- Confirmation depth
axiom oracle_confirmation_depth :
    ∀ (block : Block),
      oracleConfirmed block →
      confirmations block ≥ 100 ∧ challengePeriodExpired block
```

**Discharge path**: Binocular whitepaper proofs and standard Merkle tree properties.

---

## 6. Lean 4 Module Structure

```
BifrostProofs/
├── Basic.lean              -- Core types: SPO, Deposit, PegOut, Roster, EpochKeys
├── State.lean              -- ProtocolState, initial state
├── Action.lean             -- ProtocolAction enum
├── Axioms.lean             -- All axioms (crypto, validators, oracle, Bitcoin)
├── Transition.lean         -- step function: State → Action → Option State
├── Trace.lean              -- validTrace, applyTrace, induction principles
├── Conservation.lean       -- Theorem C1: conservation of funds
├── NoDoubleMint.lean       -- Theorem D1: no double minting
├── FailSafe.lean           -- Theorems F1–F5: depositor/withdrawer recovery
├── Threshold.lean          -- Theorem R2: threshold security
├── Liveness.lean           -- Theorems L1–L6: peg-out/peg-in liveness
├── Authorization.lean      -- Theorems A1–A6: authorization properties
└── EpochTransition.lean    -- Theorems E1–E4: epoch handoff
```

### 6.1 Implementation Order

1. **`Basic.lean` + `State.lean` + `Action.lean`** — Define all types and the state
2. **`Axioms.lean`** — State all axioms upfront (the "trusted base")
3. **`Transition.lean`** — Define the `step` function
4. **`Trace.lean`** — Trace infrastructure, induction principle over valid traces
5. **`Conservation.lean`** — Theorem 1 (highest-value, establishes the proof pattern)
6. **`NoDoubleMint.lean`** — Theorem 2
7. **`FailSafe.lean`** — Theorem 3
8. **`Threshold.lean`** — Theorem 4 (pure math, independent of protocol model)
9. **`Liveness.lean`** — Theorem 5 (most complex, depends on all other modules)

### 6.2 Core Type Definitions

```lean
/-- A Bitcoin UTxO -/
structure BitcoinUTxO where
  txid  : ByteArray
  vout  : Nat
  value : Nat  -- satoshis

/-- Protocol state -/
structure ProtocolState where
  -- Cardano side
  pegInRequests   : Finset PegInRequest
  pendingPegOuts  : Finset PegOutRequest
  completedPegIns : Finset DepositId       -- Merkle Patricia Trie
  circulatingFBTC : Nat
  spoRegistry     : SPORegistry
  epochKeys       : EpochKeys
  currentEpoch    : Nat
  config          : BifrostConfig
  -- Bitcoin side
  treasuryUTxO    : BitcoinUTxO
  treasuryBalance : Nat
  bitcoinHeight   : Nat
  -- Oracle
  oracleState     : OracleState

/-- Roster of SPOs for a given epoch -/
structure Roster where
  members           : Finset SPO
  threshold67       : Nat
  threshold51       : Nat
  securityThreshold : Nat  -- basis points (e.g. 5100 for 51%)
  groupKey67        : PublicKey
  groupKey51        : PublicKey

/-- Protocol actions (labels in the transition system) -/
inductive ProtocolAction
  | PegInDeposit       (deposit : Deposit)
  | CreatePegInRequest (deposit : Deposit) (proof : OracleProof)
  | TreasuryMovement   (tm : TMTransaction)
  | MintFBTC           (req : PegInRequest) (sig : SchnorrSig)
  | LockForPegOut      (amount : Nat) (destAddr : ByteArray)
  | FulfillPegOut      (po : PegOutRequest) (proof : OracleProof)
  | CancelPegOut       (po : PegOutRequest)
  | DepositorRefund    (deposit : Deposit)
  | SPORegister        (spo : SPO) (coldSig : Ed25519Sig)
  | SPODeregister      (spo : SPO) (coldSig : Ed25519Sig)
  | DKG                (epoch : Nat) (result : DKGResult)
  | EpochBoundary
  | OracleUpdate       (blocks : List BlockHeader)

/-- Transition function -/
def step (s : ProtocolState) (a : ProtocolAction) : Option ProtocolState :=
  match a with
  | .MintFBTC req sig =>
    if req ∈ s.pegInRequests
       ∧ req.depositId ∉ s.completedPegIns  -- trie non-inclusion
       ∧ validSchnorrSig req.depositorPk sig  -- depositor authorization
    then some { s with
      pegInRequests   := s.pegInRequests.erase req
      completedPegIns := s.completedPegIns ∪ {req.depositId}
      circulatingFBTC := s.circulatingFBTC + req.amount
    }
    else none
  | .FulfillPegOut po proof =>
    if po ∈ s.pendingPegOuts
       ∧ validOracleProof s.oracleState proof po
    then some { s with
      pendingPegOuts  := s.pendingPegOuts.erase po
      circulatingFBTC := s.circulatingFBTC - po.amount
      treasuryBalance := s.treasuryBalance - po.amount
    }
    else none
  | .CancelPegOut po =>
    if po ∈ s.pendingPegOuts
       ∧ s.currentTreasuryAddress ≠ po.treasuryAtCreation
    then some { s with
      pendingPegOuts  := s.pendingPegOuts.erase po
      -- fBTC returned to user, circulatingFBTC unchanged
    }
    else none
  -- ... remaining cases follow the same pattern
  | _ => sorry  -- to be filled in implementation
```

---

## 7. Future Work: Validator-Level Proofs via CardanoBlaster

While this document focuses on protocol-level properties with axiomatized validators, the axioms in Section 5.2 can be discharged by proving properties directly on compiled Aiken validators using CardanoBlaster.

### 7.1 Example: Config Admin Required (axiom A6)

```lean
#import_uplc configSpend single_cbor_hex "onchain/artifacts/config_spend.flat"

def appliedConfigSpend (datum redeemer ctx : Data) :=
  cekExecuteProgram configSpend
    [Term.Const (.Data datum), Term.Const (.Data redeemer),
     Term.Const (.Data ctx)] 50000

theorem config_spend_admin_required :
    ∀ (datum redeemer ctx : Data),
      isSuccessful (appliedConfigSpend datum redeemer ctx) →
      adminAuthorized datum ctx ∧ valuePreserved ctx := by
  blaster
```

### 7.2 Example: Btc-Mint Conservation (axiom C2)

```lean
#import_uplc btcMint single_cbor_hex "onchain/artifacts/btc_mint.flat"

def appliedBtcMint (redeemer ctx : Data) :=
  cekExecuteProgram btcMint
    [Term.Const (.Data redeemer), Term.Const (.Data ctx)] 100000

theorem btc_mint_conservation :
    ∀ (redeemer ctx : Data),
      isSuccessful (appliedBtcMint redeemer ctx) →
      btcMintTotalEqualsProvedSum redeemer ctx := by
  blaster
```

### 7.3 Prerequisites for Validator-Level Proofs

1. **ScriptContext encoder**: Lean 4 functions to build well-formed `Data`-encoded Plutus V3 `ScriptContext`
2. **Crypto builtin axioms**: Extend `Evaluate.lean` to axiomatize `VerifyEd25519Signature`, `Blake2b_224`, etc.
3. **`SerialiseData` implementation**: CBOR encoding of `Data` (used by `utils.hash_output_ref`)
