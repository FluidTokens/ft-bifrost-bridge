# Delegated fBTC Minting Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the fBTC minting policy an immutable presence-only delegator to a swappable "mint checker" withdraw script named in ConfigDatum field 19, per `docs/superpowers/specs/2026-07-16-fbtc-mint-delegation-design.md`.

**Architecture:** The `bridged_token` mint policy keeps only the config-NFT lookup plus `pairs.has_key(withdrawals, Script(checker))`. A new single-purpose `fbtc_mint_checker` withdraw validator carries all V1 rules (single asset entry, configured name, mint→CompletePegIn / burn→CompletePegOut dispatch). Off-chain (binocular, Scala/Scalus) mirrors the datum, adds the checker to both completion tx builders as an extra 0-ADA withdrawal, and wires deploy/registration.

**Tech Stack:** Aiken v1.1.23 (Plutus V3), Scala 3 + Scalus (binocular sbt project).

## Global Constraints

- On-chain work runs from `onchain/`: `aiken check` (tests) and `aiken build` (regenerates the tracked `plutus.json`).
- Off-chain work runs from `offchain/bitcoin-watchtower/binocular/`: `sbt compile`, `sbt test`, and `sbt scalafmtAll` before every commit (binocular CLAUDE.md rule).
- ConfigDatum evolution is APPEND-ONLY; existing field indexes 0–18 are frozen. The new field is index 19.
- Never use em dashes in docs/commits; use en dashes. NEVER add a `Co-Authored-By: Claude` trailer.
- Commit messages follow repo style: `feat(onchain): …`, `feat(offchain): …`, `docs: …`.
- Aiken naming: file `fbtc-mint-checker.ak` → module `bitcoin/fbtc_mint_checker`; blueprint titles are `<module>.<validator>.<handler>`.

---

### Task 1: ConfigDatum field 19 + getter

**Files:**
- Modify: `onchain/lib/bifrost/types/config.ak`
- Modify: `onchain/validators/bitcoin/config.ak` (test fixture `t_datum` only)

**Interfaces:**
- Produces: `ConfigDatum.bridged_token_mint_checker_script_hash: ByteArray` (last record field) and `config.get_bridged_token_mint_checker_script_hash(config_fields: List<Data>) -> ByteArray` (index 19). Tasks 2–3 call the getter.

- [ ] **Step 1: Add the field to the ConfigDatum record**

In `onchain/lib/bifrost/types/config.ak`, after the `update_auth` field, append:

```aiken
  //Withdraw script carrying ALL fBTC mint/burn rules; the immutable
  //bridged_token policy only requires this script to run in the tx. Swapped
  //via an authorized config Update (see the delegated-mint design spec).
  bridged_token_mint_checker_script_hash: ByteArray,
```

- [ ] **Step 2: Add the positional getter (index 19), after `get_update_auth`**

```aiken
pub fn get_bridged_token_mint_checker_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 19))
}
```

- [ ] **Step 3: Extend the pin test**

In `config_getters_match_datum_fields`, add to the `ConfigDatum` literal (after `update_auth: …`):

```aiken
      bridged_token_mint_checker_script_hash: #"aa19",
```

and to the final `and { … }` block:

```aiken
    get_bridged_token_mint_checker_script_hash(fields) == datum.bridged_token_mint_checker_script_hash,
```

- [ ] **Step 4: Update the `t_datum` fixture in `onchain/validators/bitcoin/config.ak`**

After `update_auth,` in the `t_datum` constructor add:

```aiken
    bridged_token_mint_checker_script_hash: #"aadddddddddddddddddddddddddddddddddddddddddddddddddddddd",
```

- [ ] **Step 5: Run tests**

Run: `cd onchain && aiken check`
Expected: all tests pass (the pin test now covers index 19; config.ak tests still pass because the Update path allows any datum).

- [ ] **Step 6: Commit**

```bash
git add onchain/lib/bifrost/types/config.ak onchain/validators/bitcoin/config.ak
git commit -m "feat(onchain): ConfigDatum field 19 - fBTC mint-checker script hash"
```

---

### Task 2: Rewrite `bridged-token.ak` as the immutable delegator

**Files:**
- Rewrite: `onchain/validators/bitcoin/bridged-token.ak`

**Interfaces:**
- Consumes: `config.get_bridged_token_mint_checker_script_hash` (Task 1).
- Produces: validator `bridged_token(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray)` with `mint(MintRedeemer, PolicyId, Transaction)`; `pub type MintRedeemer { config_ref_input_index: Int }`. Blueprint title becomes `bitcoin/bridged_token.bridged_token.mint` (Task 6 depends on this name).

- [ ] **Step 1: Replace the whole file with**

```aiken
use aiken/collection/pairs
use bifrost/types/config.{ConfigDatum}
use bifrost/types/general.{CardanoSignature}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction, placeholder}

pub type MintRedeemer {
  config_ref_input_index: Int,
}

//The fBTC minting policy: a minimal, immutable delegator. Its script hash is
//the stable fBTC policy id (ConfigDatum index 0). ALL minting rules live in
//the swappable mint-checker withdraw script named by ConfigDatum index 19;
//this policy only requires that checker to run in the same tx. The core
//never inspects self.mint - delegation is total by design, so the checker
//must constrain the full fBTC mint value on EVERY code path (see
//docs/superpowers/specs/2026-07-16-fbtc-mint-delegation-design.md).
validator bridged_token(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  mint(redeemer: MintRedeemer, _policy_id: PolicyId, self: Transaction) {
    let config_fields =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let checker_hash =
      config.get_bridged_token_mint_checker_script_hash(config_fields)
    pairs.has_key(self.withdrawals, Script(checker_hash))
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_config_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_config_asset: ByteArray = "BifrostConfig"

const t_checker_hash: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const t_own_policy: ByteArray =
  #"aa111111111111111111111111111111111111111111111111111111"

fn t_config_datum() -> ConfigDatum {
  ConfigDatum {
    bridged_token_policy_id: t_own_policy,
    bridged_token_asset_name: "fBTC",
    source_chain_merkle_tree_policy_id: #"aa22",
    source_chain_merkle_tree_asset_name: "sourceChain",
    block_header_merkle_tree_policy_id: #"aa33",
    block_header_merkle_tree_asset_name: "blockHeaders",
    completed_peg_ins_merkle_tree_policy_id: #"aa44",
    completed_peg_ins_merkle_tree_asset_name: "completedPegIns",
    completed_peg_outs_merkle_tree_policy_id: #"aa55",
    completed_peg_outs_merkle_tree_asset_name: "completedPegOuts",
    peg_in_withdraw_script_hash: #"aa66",
    peg_out_withdraw_script_hash: #"aa77",
    peg_in_close_verifier_script_hash: #"aa88",
    legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa99",
    legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aaaa",
    treasury_nft_policy_id: #"aabb",
    treasury_nft_asset_name: "treasuryNFT",
    min_stake: 0,
    update_auth: Some(CardanoSignature { hash: #"aadd" }),
    bridged_token_mint_checker_script_hash: t_checker_hash,
  }
}

fn t_config_ref_input() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_config_policy),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_config_policy, t_config_asset, 1),
      datum: InlineDatum(t_config_datum()),
      reference_script: None,
    },
  }
}

fn t_mint(tx: Transaction) {
  bridged_token.mint(
    t_config_policy,
    t_config_asset,
    MintRedeemer { config_ref_input_index: 0 },
    t_own_policy,
    tx,
  )
}

test mint_accepts_when_checker_runs() {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_checker_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fBTC", 100),
    }
  t_mint(tx)
}

test burn_accepts_when_checker_runs() {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_checker_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fBTC", -100),
    }
  t_mint(tx)
}

//Delegation is total: the core accepts ANY mint shape (multiple asset names,
//mixed signs) as long as the checker runs. The checker carries every rule.
test mint_delegation_is_total() {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_checker_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fBTC", 100)
        |> assets.add(t_own_policy, "junk", -3),
    }
  t_mint(tx)
}

test mint_rejects_missing_checker_withdrawal() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [],
      mint: assets.from_asset(t_own_policy, "fBTC", 100),
    }
  expect t_mint(tx)
}

test mint_rejects_unrelated_withdrawal_only() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [
        Pair(
          Script(#"ff11111111111111111111111111111111111111111111111111111111"),
          0,
        ),
      ],
      mint: assets.from_asset(t_own_policy, "fBTC", 100),
    }
  expect t_mint(tx)
}

test mint_rejects_ref_input_without_config_nft() fail {
  let no_nft_input =
    Input {
      ..t_config_ref_input(),
      output: Output {
        ..t_config_ref_input().output,
        value: assets.from_lovelace(2_000_000),
      },
    }
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [no_nft_input],
      withdrawals: [Pair(Script(t_checker_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fBTC", 100),
    }
  expect t_mint(tx)
}
```

Note: `use bifrost/types/config.{ConfigDatum}` still binds the module as `config`, so `config.get_bridged_token_mint_checker_script_hash` resolves. If `aiken check` reports an unused import for `assets`, add `use cardano/assets` explicitly (the `assets.from_asset` calls require it).

- [ ] **Step 2: Run tests**

Run: `cd onchain && aiken check -m bridged_token`
Expected: 6 tests pass.

- [ ] **Step 3: Commit**

```bash
git add onchain/validators/bitcoin/bridged-token.ak
git commit -m "feat(onchain): bridged_token becomes a pure delegator to the config-named mint checker"
```

---

### Task 3: New `fbtc-mint-checker.ak` (V1 rules)

**Files:**
- Create: `onchain/validators/bitcoin/fbtc-mint-checker.ak`

**Interfaces:**
- Consumes: config getters (Task 1), `PegInWithdrawRedeemer`/`ActionType.CompletePegIn` from `bifrost/types/peg_in`, `PegOutWithdrawRedeemer`/`PegOutActionType.CompletePegOut` from `bifrost/types/peg_out`.
- Produces: validator `fbtc_mint_checker(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray)` with `withdraw(CheckerRedeemer, Credential, Transaction)`; `pub type CheckerRedeemer { config_ref_input_index: Int, peg_withdraw_redeemer_index: Int }`. Blueprint title `bitcoin/fbtc_mint_checker.fbtc_mint_checker.withdraw` (Task 6).

- [ ] **Step 1: Create the file**

```aiken
use aiken/collection/dict
use bifrost/types/config
use bifrost/types/peg_in.{CompletePegIn, PegInWithdrawRedeemer}
use bifrost/types/peg_out.{CompletePegOut, PegOutWithdrawRedeemer}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{Transaction, Withdraw}

pub type CheckerRedeemer {
  config_ref_input_index: Int,
  //Index into self.redeemers of the peg-in (mint) or peg-out (burn)
  //withdraw redeemer this fBTC supply change rides on
  peg_withdraw_redeemer_index: Int,
}

//The swappable fBTC mint checker (ConfigDatum index 19). The immutable
//bridged_token policy delegates ALL mint/burn rules here, so EVERY code path
//of this validator must fully constrain the fBTC mint value - an action that
//ignores self.mint would let any tx invoking it mint freely. V1 is a
//behavior-preserving port of the pre-delegation bridged-token rules.
validator fbtc_mint_checker(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: CheckerRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config_fields =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let bridged_token_policy_id =
      config.get_bridged_token_policy_id(config_fields)
    let bridged_token_asset_name =
      config.get_bridged_token_asset_name(config_fields)
    //Exactly one asset entry under the fBTC policy, with the configured name
    expect [Pair(minted_asset_name, minted_quantity)] =
      dict.to_pairs(tokens(self.mint, bridged_token_policy_id))
    expect minted_asset_name == bridged_token_asset_name

    //A Withdraw(Script(h))-keyed entry in self.redeemers exists iff that
    //withdrawal executes in this tx, so no separate withdrawals scan needed
    let peg_withdraw_redeemer =
      utils.safe_list_at(self.redeemers, redeemer.peg_withdraw_redeemer_index)
    if minted_quantity > 0 {
      let peg_in_withdraw_script_hash =
        config.get_peg_in_withdraw_script_hash(config_fields)
      expect
        peg_withdraw_redeemer.1st == Withdraw(
          Script(peg_in_withdraw_script_hash),
        )
      expect peg_in_redeemer: PegInWithdrawRedeemer = peg_withdraw_redeemer.2nd
      when peg_in_redeemer.action_type is {
        CompletePegIn { .. } -> True
        _ -> False
      }
    } else {
      let peg_out_withdraw_script_hash =
        config.get_peg_out_withdraw_script_hash(config_fields)
      expect
        peg_withdraw_redeemer.1st == Withdraw(
          Script(peg_out_withdraw_script_hash),
        )
      expect peg_out_redeemer: PegOutWithdrawRedeemer =
        peg_withdraw_redeemer.2nd
      when peg_out_redeemer.action_type is {
        CompletePegOut { .. } -> True
        _ -> False
      }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}
```

- [ ] **Step 2: Add tests to the same file**

```aiken
//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

use bifrost/types/config.{ConfigDatum} as config_types
use bifrost/types/general.{CardanoSignature}
use bifrost/types/peg_in.{Cancel} as peg_in_types
use bifrost/types/peg_out.{InputCompletePegOut}
use cardano/address.{Address, VerificationKey}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, placeholder}
```

NOTE: Aiken forbids duplicate `use` lines; merge these into the header imports instead of adding a second block, i.e. the final import list is:

```aiken
use aiken/collection/dict
use bifrost/types/config.{ConfigDatum}
use bifrost/types/general.{CardanoSignature}
use bifrost/types/peg_in.{Cancel, CompletePegIn, PegInWithdrawRedeemer}
use bifrost/types/peg_out.{
  CompletePegOut, InputCompletePegOut, PegOutWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, Withdraw,
  placeholder,
}
```

Then the test fixtures + tests:

```aiken
const t_config_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_config_asset: ByteArray = "BifrostConfig"

const t_checker_hash: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const t_fbtc_policy: ByteArray =
  #"aa111111111111111111111111111111111111111111111111111111"

const t_peg_in_hash: ByteArray =
  #"aa666666666666666666666666666666666666666666666666666666"

const t_peg_out_hash: ByteArray =
  #"aa777777777777777777777777777777777777777777777777777777"

fn t_config_datum() -> ConfigDatum {
  ConfigDatum {
    bridged_token_policy_id: t_fbtc_policy,
    bridged_token_asset_name: "fBTC",
    source_chain_merkle_tree_policy_id: #"aa22",
    source_chain_merkle_tree_asset_name: "sourceChain",
    block_header_merkle_tree_policy_id: #"aa33",
    block_header_merkle_tree_asset_name: "blockHeaders",
    completed_peg_ins_merkle_tree_policy_id: #"aa44",
    completed_peg_ins_merkle_tree_asset_name: "completedPegIns",
    completed_peg_outs_merkle_tree_policy_id: #"aa55",
    completed_peg_outs_merkle_tree_asset_name: "completedPegOuts",
    peg_in_withdraw_script_hash: t_peg_in_hash,
    peg_out_withdraw_script_hash: t_peg_out_hash,
    peg_in_close_verifier_script_hash: #"aa88",
    legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa99",
    legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aaaa",
    treasury_nft_policy_id: #"aabb",
    treasury_nft_asset_name: "treasuryNFT",
    min_stake: 0,
    update_auth: Some(CardanoSignature { hash: #"aadd" }),
    bridged_token_mint_checker_script_hash: t_checker_hash,
  }
}

fn t_config_ref_input() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_config_policy),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_config_policy, t_config_asset, 1),
      datum: InlineDatum(t_config_datum()),
      reference_script: None,
    },
  }
}

fn t_complete_peg_in_redeemer() -> Data {
  let r =
    PegInWithdrawRedeemer {
      config_ref_input_index: 0,
      action_type: CompletePegIn {
        recipient: Address {
          payment_credential: VerificationKey(#"aaee"),
          stake_credential: None,
        },
        fbtc_output_index: 0,
        depositor_signature: #"",
        completed_peg_in_utxos_input_index: 0,
        completed_peg_in_utxos_output_index: 0,
        added_peg_in_to_completed_peg_ins_inclusion_proof: [],
        peg_in_in_completed_peg_ins_exclusion_proof: [],
      },
    }
  let d: Data = r
  d
}

fn t_cancel_peg_in_redeemer() -> Data {
  let r =
    PegInWithdrawRedeemer {
      config_ref_input_index: 0,
      action_type: Cancel { burnt_peg_in_nft_asset_name: "x" },
    }
  let d: Data = r
  d
}

fn t_complete_peg_out_redeemer() -> Data {
  let r =
    PegOutWithdrawRedeemer {
      config_ref_input_index: 0,
      action_type: CompletePegOut {
        peg_out_info: InputCompletePegOut {
          block_header: #"",
          block_header_in_source_chain_inclusion_proof: [],
          treasury_movement_raw_tx: #"",
          treasury_movement_tx_index: 0,
          treasury_movement_tx_inclusion_proof: [],
          peg_out_utxo_id: #"",
          peg_out_in_completed_peg_outs_exclusion_proof: [],
        },
        completed_peg_outs_input_index: 0,
        completed_peg_outs_output_index: 0,
        added_peg_out_to_completed_peg_outs_inclusion_proof: [],
        tmtilaspopvsh_withdraw_redeemer_index: 0,
      },
    }
  let d: Data = r
  d
}

fn t_withdraw(tx: Transaction) {
  fbtc_mint_checker.withdraw(
    t_config_policy,
    t_config_asset,
    CheckerRedeemer { config_ref_input_index: 0, peg_withdraw_redeemer_index: 0 },
    Script(t_checker_hash),
    tx,
  )
}

test checker_accepts_mint_with_complete_peg_in() {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      mint: assets.from_asset(t_fbtc_policy, "fBTC", 100),
      redeemers: [
        Pair(Withdraw(Script(t_peg_in_hash)), t_complete_peg_in_redeemer()),
      ],
    }
  t_withdraw(tx)
}

test checker_accepts_burn_with_complete_peg_out() {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      mint: assets.from_asset(t_fbtc_policy, "fBTC", -100),
      redeemers: [
        Pair(Withdraw(Script(t_peg_out_hash)), t_complete_peg_out_redeemer()),
      ],
    }
  t_withdraw(tx)
}

test checker_rejects_wrong_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      mint: assets.from_asset(t_fbtc_policy, "notFBTC", 100),
      redeemers: [
        Pair(Withdraw(Script(t_peg_in_hash)), t_complete_peg_in_redeemer()),
      ],
    }
  expect t_withdraw(tx)
}

test checker_rejects_multiple_asset_names() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      mint: assets.from_asset(t_fbtc_policy, "fBTC", 100)
        |> assets.add(t_fbtc_policy, "junk", 1),
      redeemers: [
        Pair(Withdraw(Script(t_peg_in_hash)), t_complete_peg_in_redeemer()),
      ],
    }
  expect t_withdraw(tx)
}

test checker_rejects_mint_gated_by_peg_out_script() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      mint: assets.from_asset(t_fbtc_policy, "fBTC", 100),
      redeemers: [
        Pair(Withdraw(Script(t_peg_out_hash)), t_complete_peg_out_redeemer()),
      ],
    }
  expect t_withdraw(tx)
}

test checker_rejects_cancel_action_for_mint() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      mint: assets.from_asset(t_fbtc_policy, "fBTC", 100),
      redeemers: [
        Pair(Withdraw(Script(t_peg_in_hash)), t_cancel_peg_in_redeemer()),
      ],
    }
  expect t_withdraw(tx)
}

test checker_rejects_redeemer_index_at_unrelated_entry() fail {
  let unrelated: Data = 42
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      mint: assets.from_asset(t_fbtc_policy, "fBTC", 100),
      redeemers: [
        Pair(
          Withdraw(
            Script(#"ff11111111111111111111111111111111111111111111111111111111"),
          ),
          unrelated,
        ),
      ],
    }
  expect t_withdraw(tx)
}
```

If the compiler complains about `mpf.Proof` vs `[]`: `Proof` is `List<ProofStep>`, so the empty-list literal is valid; if inference fails, annotate via a `let proof: mpf.Proof = []` binding and `use aiken/merkle_patricia_forestry as mpf`.

- [ ] **Step 3: Run tests**

Run: `cd onchain && aiken check -m fbtc_mint_checker`
Expected: 7 tests pass.

- [ ] **Step 4: Full test suite + build**

Run: `cd onchain && aiken check && aiken build`
Expected: all project tests pass; `plutus.json` regenerated with titles `bitcoin/bridged_token.bridged_token.mint` and `bitcoin/fbtc_mint_checker.fbtc_mint_checker.withdraw`. Verify: `grep -o '"title": "bitcoin/[^"]*"' onchain/plutus.json | sort -u`.

- [ ] **Step 5: Commit**

```bash
git add onchain/validators/bitcoin/fbtc-mint-checker.ak onchain/plutus.json
git commit -m "feat(onchain): fbtc_mint_checker withdraw validator - swappable V1 mint rules"
```

---

### Task 4: Technical documentation update

**Files:**
- Modify: `documentation/technical_documentation.md` (config section, ~lines 140–192)

- [ ] **Step 1: Update the config-section intro**

The paragraph ending "…so existing fBTC remains in circulation across upgrades." (around line 140) gains one sentence:

> The fBTC minting policy itself is a pure delegator: it only requires the mint-checker withdraw script named by `bridged_token_mint_checker_script_hash` (field 19) to run in the transaction, so ALL mint/burn rules are swappable via a config update while the policy id stays fixed.

- [ ] **Step 2: Document the new field and the checker invariant**

After the `update_auth` bullet list (around line 182, after the `None` bullet), add:

> `bridged_token_mint_checker_script_hash` (field 19) names the withdraw
> script carrying all fBTC mint/burn rules. The immutable fBTC policy checks
> only that this script runs in the minting tx, so every code path of the
> checker must fully constrain the fBTC mint value: an action that ignores
> `self.mint` would let any tx invoking it change the supply freely. The V1
> checker replicates the original rules (exactly one asset entry with the
> configured name; positive quantity requires the peg-in withdraw script
> running with a `CompletePegIn` redeemer, negative requires peg-out with
> `CompletePegOut`). Upgrading mint logic = deploy a new checker, register
> its stake credential, and one authorized config Update of field 19; the
> fBTC policy id and circulating fBTC are untouched.

- [ ] **Step 3: Commit**

```bash
git add documentation/technical_documentation.md
git commit -m "docs: delegated fBTC minting policy - config field 19 mint checker"
```

---

### Task 5: Scala ConfigDatum sync + redeemer types

**Files:**
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/watchtower/ConfigTypes.scala`
- Test: `offchain/bitcoin-watchtower/binocular/src/test/scala/binocular/ConfigDatumEncodingTest.scala` (new)

**Interfaces:**
- Produces: `ConfigDatum` with two appended fields `updateAuth: Option[AuthorizationMethod]` (index 18 — NOTE: the Scala mirror is currently MISSING this field that on-chain already has; this task fixes the existing drift too) and `bridgedTokenMintCheckerScriptHash: ByteString` (index 19); `BridgedTokenMintRedeemer(configRefInputIndex: BigInt)` (single field); `FbtcMintCheckerRedeemer(configRefInputIndex: BigInt, pegWithdrawRedeemerIndex: BigInt)`. Tasks 7–9 consume these.
- `AuthorizationMethod` already exists in `binocular/watchtower/PegInTypes.scala` (same package).

- [ ] **Step 1: Write the failing encoding test**

The on-chain `Option<AuthorizationMethod>` is Plutus `Constr 0 [v]` for `Some` / `Constr 1 []` for `None`. Use the Scalus prelude Option (`scalus.cardano.onchain.plutus.prelude.Option`, same package as the `List` the tx builders already import) and PIN the encoding:

```scala
package binocular

import binocular.watchtower.*
import org.scalatest.funsuite.AnyFunSuite
import scalus.uplc.builtin.{ByteString, Data}
import scalus.uplc.builtin.Data.toData
import scalus.cardano.onchain.plutus.prelude.Option as POption

class ConfigDatumEncodingTest extends AnyFunSuite {

    test("updateAuth Some/None encode as Constr 0/[v] and Constr 1/[] (Aiken Option)") {
        val some: POption[AuthorizationMethod] =
            POption.Some(AuthorizationMethod.CardanoSignature(ByteString.fromHex("aa")))
        val none: POption[AuthorizationMethod] = POption.None
        assert(some.toData match { case Data.Constr(0, _ :: Nil) => true; case _ => false })
        assert(none.toData == Data.Constr(1, Nil))
    }

    test("ConfigDatum has 20 positional fields; checker hash is field 19") {
        val checker = ByteString.fromHex("ee" * 28)
        val d = ConfigDatum(
          bridgedTokenPolicyId = ByteString.fromHex("aa" * 28),
          bridgedTokenAssetName = ByteString.fromString("fBTC"),
          sourceChainMerkleTreePolicyId = ByteString.empty,
          sourceChainMerkleTreeAssetName = ByteString.empty,
          blockHeaderMerkleTreePolicyId = ByteString.empty,
          blockHeaderMerkleTreeAssetName = ByteString.empty,
          completedPegInsMerkleTreePolicyId = ByteString.empty,
          completedPegInsMerkleTreeAssetName = ByteString.empty,
          completedPegOutsMerkleTreePolicyId = ByteString.empty,
          completedPegOutsMerkleTreeAssetName = ByteString.empty,
          pegInWithdrawScriptHash = ByteString.empty,
          pegOutWithdrawScriptHash = ByteString.empty,
          pegInCloseVerifierScriptHash = ByteString.empty,
          legitTmAndPegOutProducedVerifierScriptHash = ByteString.empty,
          legitTmAndPegOutNotProducedVerifierScriptHash = ByteString.empty,
          treasuryNftPolicyId = ByteString.empty,
          treasuryNftAssetName = ByteString.empty,
          minStake = BigInt(0),
          updateAuth = POption.None,
          bridgedTokenMintCheckerScriptHash = checker
        )
        d.toData match {
            case Data.Constr(0, fields) =>
                assert(fields.size == 20)
                assert(fields(19) == Data.B(checker))
            case other => fail(s"expected Constr 0, got $other")
        }
    }
}
```

If `scalus.cardano.onchain.plutus.prelude.Option` does not exist or encodes differently (check the Scalus version in `build.sbt` and its prelude sources under `~/.cache/coursier` or scalus.org docs), define the mirror locally in ConfigTypes.scala instead — the encoding contract in this test is what matters, not which type provides it:

```scala
enum ConfigUpdateAuth derives FromData, ToData {
    case Some(auth: AuthorizationMethod)
    case None
}
```

(and use `ConfigUpdateAuth` in place of `POption[AuthorizationMethod]` everywhere below).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd offchain/bitcoin-watchtower/binocular && sbt "testOnly binocular.ConfigDatumEncodingTest"`
Expected: FAIL — `ConfigDatum` has no `updateAuth`/`bridgedTokenMintCheckerScriptHash` parameters.

- [ ] **Step 3: Update ConfigTypes.scala**

In `ConfigDatum`, after `minStake: BigInt`, append (adjusting the class-level doc comment to mention indexes 18/19):

```scala
    // Index 18: the authority allowed to Update/Retire the config UTxO
    // (config.ak spend handler). None = permanently frozen.
    updateAuth: scalus.cardano.onchain.plutus.prelude.Option[AuthorizationMethod],
    // Index 19: the withdraw script carrying ALL fBTC mint/burn rules; the
    // immutable bridged_token policy only requires it to run in the tx.
    bridgedTokenMintCheckerScriptHash: ByteString
```

Replace `BridgedTokenMintRedeemer` (and its comment) with:

```scala
// Mint redeemer for `bridged-token.ak::MintRedeemer` (the fBTC policy). The policy is a pure
// delegator: it reads config[19] = bridged_token_mint_checker_script_hash from the config ref
// input at `configRefInputIndex` and requires that withdraw script to run in the tx. All actual
// mint/burn rules live in the checker (FbtcMintCheckerRedeemer below).
case class BridgedTokenMintRedeemer(
    configRefInputIndex: BigInt
) derives FromData,
      ToData

// Withdraw redeemer for `fbtc-mint-checker.ak::CheckerRedeemer`. V1 checker rules: exactly one
// asset entry under the fBTC policy with the configured name; mint (>0) requires the peg_in
// withdraw redeemer at `pegWithdrawRedeemerIndex` to be a CompletePegIn, burn (<0) a peg_out
// CompletePegOut. Both indices are computed from the assembled tx.
case class FbtcMintCheckerRedeemer(
    configRefInputIndex: BigInt,
    pegWithdrawRedeemerIndex: BigInt
) derives FromData,
      ToData
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sbt "testOnly binocular.ConfigDatumEncodingTest"`
Expected: PASS. (`sbt compile` will now FAIL in the tx builders/commands — that's Tasks 7–9; commit only after compile is green, so proceed to Task 6/7 before committing if needed, or commit with `sbt "testOnly …"` evidence and note the WIP. Preferred: hold the commit until Task 9 completes and the whole module compiles.)

---

### Task 6: BifrostContracts — renamed title + checker contract

**Files:**
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/watchtower/BifrostContracts.scala`

**Interfaces:**
- Produces: `BridgedTokenContract.ValidatorTitle == "bitcoin/bridged_token.bridged_token.mint"`; new `FbtcMintCheckerContract(blueprint, configNftPolicyId, configNftAssetName)` with `.scriptHash`, `.script`.

- [ ] **Step 1: Update the bridged-token title**

Replace `BridgedTokenContract.ValidatorTitle` value and fix the stale doc comment ("a source quirk" note is obsolete after the rename):

```scala
    val ValidatorTitle = "bitcoin/bridged_token.bridged_token.mint"
```

- [ ] **Step 2: Add the checker contract wrapper (after `BridgedTokenContract`)**

```scala
/** The `fbtc_mint_checker` withdraw validator: params `(configNFTPolicyId, configNFTAssetName)`.
  * Its script hash is ConfigDatum index 19 — the swappable script carrying all fBTC mint/burn
  * rules; the `bridged_token` policy only requires a withdrawal from it. Small enough to inline
  * in the witness set (no CIP-33 ref needed), like the peg-out produced verifier.
  */
final case class FbtcMintCheckerContract(script: Script.PlutusV3) {
    def scriptHash: ScriptHash = script.scriptHash
}

object FbtcMintCheckerContract {
    val ValidatorTitle = "bitcoin/fbtc_mint_checker.fbtc_mint_checker.withdraw"

    def apply(
        blueprint: BifrostBlueprint,
        configNftPolicyId: ByteString,
        configNftAssetName: ByteString
    ): FbtcMintCheckerContract = {
        val applied = Program
            .fromCborHex(blueprint.compiledCode(ValidatorTitle))
            .$(Data.B(configNftPolicyId))
            .$(Data.B(configNftAssetName))
        FbtcMintCheckerContract(Script.PlutusV3(applied.cborByteString))
    }
}
```

- [ ] **Step 3: Compile check (still red overall until Task 9 — acceptable), move on**

---

### Task 7: PegInCompleteTx — checker withdrawal + index rework

**Files:**
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/watchtower/PegInCompleteTx.scala`

**Interfaces:**
- Consumes: `FbtcMintCheckerRedeemer`, single-field `BridgedTokenMintRedeemer` (Task 5).
- Produces: `PegInCompleteTx.Scripts(pegIn, completedPegIns, bridgedToken, fbtcMintChecker)` — Task 9 constructs this.

- [ ] **Step 1: Extend `Scripts`**

```scala
    final case class Scripts(
        pegIn: PlutusScript,
        completedPegIns: PlutusScript,
        bridgedToken: PlutusScript,
        fbtcMintChecker: PlutusScript
    )
```

- [ ] **Step 2: Replace the single-withdrawal index assumption**

Replace `pegInWithdrawRedeemerIndex` (lines ~117–129) with the withdrawal-position-aware helpers (mirror of PegOutCompleteTx, which already handles multiple withdrawals — update the object doc comment accordingly: there are now TWO 0-ADA withdrawals, `peg_in` and the fBTC mint checker, ordered by reward account):

```scala
        def scriptSpends(tx: Transaction): Int =
            Seq(inputs.pir.input, inputs.completedPegIns.input).count(inputsSorted(tx).contains)
        def mintPolicies(tx: Transaction): Int =
            tx.body.value.mint.map(_.assets.size).getOrElse(0)
        def withdrawalPos(tx: Transaction, h: ScriptHash): Int =
            tx.body.value.withdrawals
                .map(_.withdrawals.keys.toIndexedSeq.indexWhere(_.address == stake(h)))
                .getOrElse(-1)
        def rewardRedeemerIndex(tx: Transaction, h: ScriptHash): BigInt =
            BigInt(scriptSpends(tx) + mintPolicies(tx) + withdrawalPos(tx, h))
        def pegInWithdrawRedeemerIndex(tx: Transaction): BigInt =
            rewardRedeemerIndex(tx, scripts.pegIn.scriptHash)
```

Move the existing `def stake(h: ScriptHash): StakeAddress = …` definition ABOVE these helpers (it currently sits below, at line ~169).

- [ ] **Step 3: Update the mint redeemer and add the checker redeemer**

```scala
        val bridgedTokenMintRedeemer: Transaction => Data = tx =>
            BridgedTokenMintRedeemer(configRefInputIndex = configRefIndex(tx)).toData

        // The checker validates the fBTC mint by pointing at the peg_in CompletePegIn withdrawal.
        val fbtcMintCheckerRedeemer: Transaction => Data = tx =>
            FbtcMintCheckerRedeemer(
              configRefInputIndex = configRefIndex(tx),
              pegWithdrawRedeemerIndex = pegInWithdrawRedeemerIndex(tx)
            ).toData
```

- [ ] **Step 4: Add the checker withdrawal (always inlined — the checker is small)**

After `withdrawWitness`, add:

```scala
        val checkerWithdrawWitness: TwoArg = TwoArg(
          scriptSource = ScriptSource.PlutusScriptValue(scripts.fbtcMintChecker),
          redeemerBuilder = fbtcMintCheckerRedeemer
        )
```

and in the final builder chain, after `.withdrawRewards(stake(scripts.pegIn.scriptHash), Coin.zero, withdrawWitness)` add:

```scala
            .withdrawRewards(
              stake(scripts.fbtcMintChecker.scriptHash),
              Coin.zero,
              checkerWithdrawWitness
            )
```

- [ ] **Step 5: Compile** — still possibly red until Task 9's command updates; `sbt compile` after Task 9.

---

### Task 8: PegOutCompleteTx — checker withdrawal + index rework

**Files:**
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/watchtower/PegOutCompleteTx.scala`

**Interfaces:**
- Produces: `PegOutCompleteTx.Scripts(pegOut, completedPegOuts, bridgedToken, producedVerifier, fbtcMintChecker)` — Task 9 constructs this.

- [ ] **Step 1: Extend `Scripts`**

```scala
    final case class Scripts(
        pegOut: PlutusScript,
        completedPegOuts: PlutusScript,
        bridgedToken: PlutusScript,
        producedVerifier: PlutusScript,
        fbtcMintChecker: PlutusScript
    )
```

- [ ] **Step 2: Update the mint redeemer and add the checker redeemer**

The reward-index helpers already exist here. Replace `bridgedTokenMintRedeemer` with:

```scala
        val bridgedTokenMintRedeemer: Transaction => Data = tx =>
            BridgedTokenMintRedeemer(configRefInputIndex = configRefIndex(tx)).toData

        // The checker validates the fBTC burn by pointing at the peg_out CompletePegOut withdrawal.
        val fbtcMintCheckerRedeemer: Transaction => Data = tx =>
            FbtcMintCheckerRedeemer(
              configRefInputIndex = configRefIndex(tx),
              pegWithdrawRedeemerIndex = rewardRedeemerIndex(tx, pegOutHash)
            ).toData
```

- [ ] **Step 3: Add the checker withdrawal (third 0-ADA withdrawal; update the object doc comment)**

After `producedVerifierWitness`:

```scala
        val checkerWithdrawWitness: TwoArg = TwoArg(
          scriptSource = PlutusScriptValue(scripts.fbtcMintChecker),
          redeemerBuilder = fbtcMintCheckerRedeemer
        )
```

and in the final chain, after the producedVerifier `withdrawRewards`:

```scala
            .withdrawRewards(
              stake(scripts.fbtcMintChecker.scriptHash),
              Coin.zero,
              checkerWithdrawWitness
            )
```

---

### Task 9: Command wiring (deploy, register, both completes)

**Files:**
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/cli/commands/DeployBridgeCommand.scala`
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/cli/commands/RegisterBridgeCredsCommand.scala`
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/cli/commands/PegInCompleteCommand.scala`
- Modify: `offchain/bitcoin-watchtower/binocular/src/main/scala/binocular/cli/commands/PegOutCompleteCommand.scala`

- [ ] **Step 1: DeployBridgeCommand — build the checker, fill the two new datum fields**

After `val bridgedToken = BridgedTokenContract(...)` (line ~253), add:

```scala
        val fbtcMintChecker = FbtcMintCheckerContract(blueprint, configPolicy, ConfigAssetName)
        val fbtcMintCheckerHash = ByteString.fromArray(fbtcMintChecker.scriptHash.bytes)
```

In the `configDatum` literal, after `minStake = BigInt(0)`, add:

```scala
          // Demo/testnet governance: the sponsor's payment key may Update/Retire the config
          // (progressive decentralization rotates this later via a config update).
          updateAuth = scalus.cardano.onchain.plutus.prelude.Option.Some(
            AuthorizationMethod.CardanoSignature(
              ByteString.fromArray(setup.hdAccount.paymentKeyHash.bytes)
            )
          ),
          bridgedTokenMintCheckerScriptHash = fbtcMintCheckerHash
```

(If Task 5 fell back to a local `ConfigUpdateAuth` enum, use `ConfigUpdateAuth.Some(...)` instead.) Also add a `Console.info("fbtc mint checker hash", fbtcMintCheckerHash.toHex)` line next to the other hash prints, and fix the stale doc comment "Because `config.ak` is immutable (`spend = False`)" — the config is now updatable by `updateAuth`.

- [ ] **Step 2: RegisterBridgeCredsCommand — register the checker's reward credential**

After `val pegOutProducedVerifierHash = …` add:

```scala
        val fbtcMintChecker = FbtcMintCheckerContract(blueprint, configNftPolicy, configNftAsset)
```

and extend `creds`:

```scala
        val creds: List[(String, ScriptHash)] = List(
          "peg_in" -> pegInHash,
          "peg_out" -> pegOutHash,
          "peg_out_produced_verifier" -> pegOutProducedVerifierHash,
          "fbtc_mint_checker" -> fbtcMintChecker.scriptHash
        )
```

Update the class doc comment: peg-in completion now runs TWO rewarding scripts (`peg_in` + the fBTC mint checker), peg-out completion THREE.

- [ ] **Step 3: PegInCompleteCommand — construct and pass the checker**

After `val bridgedToken = BridgedTokenContract(...)` (line ~146):

```scala
        val fbtcMintChecker = FbtcMintCheckerContract(blueprint, configNftPolicy, configNftAsset)
```

and in the `PegInCompleteTx.Scripts(...)` call (line ~345) add the fourth argument `fbtcMintChecker.script`.

- [ ] **Step 4: PegOutCompleteCommand — same pattern**

Construct `FbtcMintCheckerContract(blueprint, configNftPolicy, configNftAsset)` next to the other contract constructions and pass `fbtcMintChecker.script` as the fifth argument of `PegOutCompleteTx.Scripts(...)`.

- [ ] **Step 5: Compile everything**

Run: `cd offchain/bitcoin-watchtower/binocular && sbt compile`
Expected: success (this closes the red window opened in Task 5).

- [ ] **Step 6: Format + commit Tasks 5–9 together**

```bash
sbt scalafmtAll && sbt compile
git add offchain/bitcoin-watchtower/binocular/src
git commit -m "feat(offchain): wire the fBTC mint checker into deploy/register/completion txs"
```

---

### Task 10: Blueprint test resource + known-answer refresh + full test run

**Files:**
- Modify: `offchain/bitcoin-watchtower/binocular/src/test/resources/bifrost-plutus-min.json`
- Modify: `offchain/bitcoin-watchtower/binocular/src/test/scala/binocular/BifrostContractsTest.scala`

- [ ] **Step 1: Regenerate the trimmed blueprint resource from the new `onchain/plutus.json`**

Inspect the existing resource to see which validator titles it keeps (the `.mint` entries plus whatever the tests reference), then rebuild it with the same `jq` shape from the freshly built `onchain/plutus.json`, now including `bitcoin/bridged_token.bridged_token.mint` and `bitcoin/fbtc_mint_checker.fbtc_mint_checker.withdraw`. Example (adjust the title list to match the tests):

```bash
jq '{preamble: {title: .preamble.title}, validators: [.validators[] | select(.title | test("\\.(mint|withdraw)$")) | {title, compiledCode}]}' \
  onchain/plutus.json > offchain/bitcoin-watchtower/binocular/src/test/resources/bifrost-plutus-min.json
```

- [ ] **Step 2: Run the contract tests to harvest the new hashes**

Run: `sbt "testOnly binocular.BifrostContractsTest"`
Expected: the four known-answer tests FAIL, printing the freshly computed hashes.

- [ ] **Step 3: Update the known-answer constants**

Replace the expected hex constants in `BifrostContractsTest` with the printed actual values, and update the header comment: these are now REGRESSION LOCKS over the new (not-yet-deployed) compiled code, no longer on-chain-validated values; they get re-validated at the next `deploy-bridge`. Add one new lock:

```scala
    test("fbtc_mint_checker hash is stable for the 2-param encoding") {
        val checker = FbtcMintCheckerContract(blueprint, configPolicy, configAssetName)
        assert(hex(checker.scriptHash) == "<value printed by the failing run>")
    }
```

- [ ] **Step 4: Full offchain verification**

Run: `sbt scalafmtAll && sbt compile && sbt test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add offchain/bitcoin-watchtower/binocular/src/test
git commit -m "test(offchain): refresh bifrost blueprint resource + hash locks for delegated fBTC policy"
```

- [ ] **Step 6: Ops note (no code)**

The existing preprod deployment (values in `preprod-*.conf` and the old known-answer hashes) is orphaned by the new script hashes: a fresh `deploy-bridge` → `register-bridge-creds` → `deploy-script-refs` cycle is required before the completion commands work again. `DeployScriptRefsCommand` needs NO change (the checker is inlined, not CIP-33-referenced).

---

## Final verification (whole plan)

1. `cd onchain && aiken check && aiken build` — green, `git status` clean except intended files.
2. `cd offchain/bitcoin-watchtower/binocular && sbt scalafmtAll && sbt compile && sbt test` — green.
3. `git log --oneline` shows the 6 commits above; no Co-Authored-By trailers.
