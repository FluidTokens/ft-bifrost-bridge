# On-chain Variant B + ConfigDatum Clean Rebuild – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `fbtc_mint_checker` delegation with Variant B (`bridged_token` presence-delegates to the existing peg-in/peg-out withdraw scripts), rebuild `ConfigDatum` to a lean 11 fields, make the cpi/cpo root NFT names constants, and rename fBTC → fSAT.

**Architecture:** `bridged_token.mint` becomes a redeemer-agnostic presence delegator gated by mint sign to `config[peg_in_withdraw]` / `config[peg_out_withdraw]`; soundness comes from `peg_in`/`peg_out` constraining the fSAT mint on *every* action (a new `mint == 0` guard on their `Cancel` branches). `ConfigDatum` drops 6 dead fields + the checker field and re-indexes; cpi/cpo asset names move to `constants.ak`.

**Tech Stack:** Aiken v1.1.23 (Plutus V3) in `onchain/`; Scala 3 + Scalus (binocular sbt project) in `offchain/bitcoin-watchtower/binocular/`.

## Global Constraints

- On-chain work runs from `onchain/`: `aiken check` (tests), `aiken build` (regenerates tracked `plutus.json`).
- Off-chain work runs from `offchain/bitcoin-watchtower/binocular/`: `sbt compile`, `sbt test`, `sbt scalafmtAll` before every commit. **After changing `plutus.json`, restart the sbt server** (`sbt shutdown` or `rm -rf target/out`) before running hash-lock tests – sbt 2.x's content cache can serve a stale blueprint resource and make hash-lock tests pass against old bytes.
- ConfigDatum evolution is append-only *after* this rebuild; this task is a one-time non-append-only reset (nothing on mainnet).
- Never use em dashes in docs/comments; use en dashes (`–`). NEVER add a `Co-Authored-By: Claude` trailer.
- Commit style: `feat(onchain):`, `refactor(onchain):`, `feat(offchain):`, `test(offchain):`.
- fSAT is a per-deploy config value, not a contract constant: validators read `bridged_token_asset_name` from the datum.
- Task ordering keeps `aiken check` green at every on-chain commit; the off-chain phase follows the on-chain `aiken build`.

## File Structure

**On-chain (`onchain/`):**
- `lib/bifrost/constants.ak` – add `completed_peg_ins_root_asset_name` / `completed_peg_outs_root_asset_name`.
- `lib/bifrost/types/config.ak` – 11-field `ConfigDatum`, re-indexed getters, pin test.
- `validators/bitcoin/config.ak` – datum fixtures.
- `validators/bitcoin/bridged-token.ak` – Variant B rewrite.
- `validators/bitcoin/fbtc-mint-checker.ak` – **delete**.
- `validators/bitcoin/peg-in.ak` / `peg-out.ak` – `Cancel` mint-guard; read cpi/cpo asset name from constant.
- `validators/bitcoin/completed-peg-ins-merkle-tree.ak` / `-outs-` – constant-name one-shot mint.

**Off-chain (`offchain/bitcoin-watchtower/binocular/src/`):**
- `main/scala/binocular/watchtower/ConfigTypes.scala` – 11-field mirror + redeemer changes.
- `main/scala/binocular/watchtower/BifrostContracts.scala` – remove checker contract; cpi/cpo `assetName` → constants.
- `main/scala/binocular/watchtower/PegInCompleteTx.scala` / `PegOutCompleteTx.scala` – remove checker withdrawal.
- `main/scala/binocular/cli/commands/DeployBridgeCommand.scala` / `RegisterBridgeCredsCommand.scala` / `PegInCompleteCommand.scala` / `PegOutCompleteCommand.scala` – wiring.
- `test/resources/bifrost-plutus-min.json`, `test/scala/binocular/BifrostContractsTest.scala`, `test/scala/binocular/ConfigDatumEncodingTest.scala` – resource + locks.

---

## Phase A – On-chain (Aiken). Run all commands from `onchain/`.

### Task 1: `Cancel` mint-guard in peg-in and peg-out

Adds `mint == 0` to both `Cancel` branches so every action of `peg_in`/`peg_out` constrains the fSAT mint. Done first so soundness is never regressed when Variant B lands. Compiles on the current ConfigDatum.

**Files:**
- Modify: `validators/bitcoin/peg-in.ak` (Cancel branch, ~line 202)
- Modify: `validators/bitcoin/peg-out.ak` (Cancel branch, ~line 152)

**Interfaces:**
- Consumes: `bridged_token_policy_id` / `bridged_token_asset_name` already bound at the top of both `withdraw` handlers.
- Produces: no new signatures; behavior change only.

- [ ] **Step 1: Add the guard in `peg-in.ak`'s Cancel branch**

Find the Cancel branch's closing conjunction:

```aiken
        and {
          close_authorized,
          peg_in_nft_in_input,
          peg_in_nft_burnt,
        }
```

Replace with:

```aiken
        //A close/cancel must never mint or burn the bridged token: this is what
        //keeps bridged_token's presence-only delegation sound (a Cancel can not
        //smuggle an unconstrained fSAT mint).
        let no_bridged_token_mint =
          quantity_of(self.mint, bridged_token_policy_id, bridged_token_asset_name) == 0
        and {
          close_authorized,
          peg_in_nft_in_input,
          peg_in_nft_burnt,
          no_bridged_token_mint,
        }
```

- [ ] **Step 2: Add the guard in `peg-out.ak`'s Cancel branch**

Find:

```aiken
        and {
          user_authorized,
          block_header_included_in_source_chain,
          treasury_movement_tx_included_in_block_header,
          treasury_movement_tx_is_legit_and_does_not_produce_peg_out_utxo,
        }
```

Replace with:

```aiken
        let no_bridged_token_mint =
          quantity_of(self.mint, bridged_token_policy_id, bridged_token_asset_name) == 0
        and {
          user_authorized,
          block_header_included_in_source_chain,
          treasury_movement_tx_included_in_block_header,
          treasury_movement_tx_is_legit_and_does_not_produce_peg_out_utxo,
          no_bridged_token_mint,
        }
```

- [ ] **Step 3: Run tests**

Run: `aiken check`
Expected: exit 0, all existing tests pass (the guard is redundant-but-harmless under the current checker design; no test exercises a Cancel that mints).

- [ ] **Step 4: Commit**

```bash
git add onchain/validators/bitcoin/peg-in.ak onchain/validators/bitcoin/peg-out.ak
git commit -m "feat(onchain): forbid fSAT mint/burn in peg-in/peg-out Cancel branches"
```

---

### Task 2: Variant B `bridged_token` + delete the checker

Rewrites `bridged_token` to presence-delegate to `config[peg_in_withdraw]`/`config[peg_out_withdraw]`, and deletes `fbtc-mint-checker.ak` and its getter. Still on the current (pre-rebuild) ConfigDatum, so it compiles.

**Files:**
- Rewrite: `validators/bitcoin/bridged-token.ak`
- Delete: `validators/bitcoin/fbtc-mint-checker.ak`
- Modify: `lib/bifrost/types/config.ak` (remove `get_bridged_token_mint_checker_script_hash` + its pin-test line + the datum field is removed in Task 4, so leave the record field for now)

**Interfaces:**
- Produces: `bridged_token(configNFTPolicyId, configNFTAssetName)` with `mint(MintRedeemer, PolicyId, Transaction)`, `MintRedeemer { config_ref_input_index: Int }`. Consumes getters `get_bridged_token_policy_id`, `get_bridged_token_asset_name`, `get_peg_in_withdraw_script_hash`, `get_peg_out_withdraw_script_hash` (all exist today).

- [ ] **Step 1: Replace `validators/bitcoin/bridged-token.ak` entirely**

```aiken
use aiken/collection/dict
use aiken/collection/pairs
use bifrost/types/config.{ConfigDatum}
use bifrost/types/general.{CardanoSignature}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, placeholder,
}

pub type MintRedeemer {
  config_ref_input_index: Int,
}

//The fSAT minting policy: an immutable presence delegator. Its script hash is
//the stable fSAT policy id (ConfigDatum field 0). It authorizes a mint (qty>0)
//by requiring the peg-in withdraw script to run, and a burn (qty<0) by
//requiring the peg-out withdraw script; those validators constrain the mint
//amount on every action (peg completion pins it; Cancel forbids it). This
//policy adds the single-asset-name guard and the config[0]==policy_id anchor.
validator bridged_token(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config_fields =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        configNFTAssetName,
      )
    //Anchor: the peg validators constrain the mint of config[0]; it must be us.
    expect config.get_bridged_token_policy_id(config_fields) == policy_id
    let asset_name = config.get_bridged_token_asset_name(config_fields)
    //Exactly one asset name under our policy, and it is the canonical one.
    expect [Pair(minted_name, minted_qty)] =
      dict.to_pairs(tokens(self.mint, policy_id))
    expect minted_name == asset_name
    if minted_qty > 0 {
      pairs.has_key(
        self.withdrawals,
        Script(config.get_peg_in_withdraw_script_hash(config_fields)),
      )
    } else {
      pairs.has_key(
        self.withdrawals,
        Script(config.get_peg_out_withdraw_script_hash(config_fields)),
      )
    }
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

const t_own_policy: ByteArray =
  #"aa111111111111111111111111111111111111111111111111111111"

const t_peg_in_hash: ByteArray =
  #"aa666666666666666666666666666666666666666666666666666666"

const t_peg_out_hash: ByteArray =
  #"aa777777777777777777777777777777777777777777777777777777"

fn t_config_datum() -> ConfigDatum {
  ConfigDatum {
    bridged_token_policy_id: t_own_policy,
    bridged_token_asset_name: "fSAT",
    completed_peg_ins_merkle_tree_policy_id: #"aa22",
    completed_peg_outs_merkle_tree_policy_id: #"aa33",
    peg_in_withdraw_script_hash: t_peg_in_hash,
    peg_out_withdraw_script_hash: t_peg_out_hash,
    peg_in_close_verifier_script_hash: #"aa66",
    legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa77",
    legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aa88",
    min_stake: 0,
    update_auth: Some(CardanoSignature { hash: #"aadd" }),
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

fn t_mint(policy_id: ByteArray, tx: Transaction) {
  bridged_token.mint(
    t_config_policy,
    t_config_asset,
    MintRedeemer { config_ref_input_index: 0 },
    policy_id,
    tx,
  )
}

test mint_accepts_with_peg_in_withdrawal() {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_peg_in_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fSAT", 100),
    }
  t_mint(t_own_policy, tx)
}

test burn_accepts_with_peg_out_withdrawal() {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_peg_out_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fSAT", -100),
    }
  t_mint(t_own_policy, tx)
}

test mint_rejects_wrong_sign_dispatch() fail {
  //mint (qty>0) but only a peg-out withdrawal present
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_peg_out_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fSAT", 100),
    }
  expect t_mint(t_own_policy, tx)
}

test mint_rejects_missing_withdrawal() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [],
      mint: assets.from_asset(t_own_policy, "fSAT", 100),
    }
  expect t_mint(t_own_policy, tx)
}

test mint_rejects_config_policy_id_mismatch() fail {
  let other = #"bb111111111111111111111111111111111111111111111111111111"
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_peg_in_hash), 0)],
      mint: assets.from_asset(other, "fSAT", 100),
    }
  expect t_mint(other, tx)
}

test mint_rejects_second_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_peg_in_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fSAT", 100)
        |> assets.add(t_own_policy, "junk", 1),
    }
  expect t_mint(t_own_policy, tx)
}

test mint_rejects_ref_input_without_config_nft() fail {
  let no_nft =
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
      reference_inputs: [no_nft],
      withdrawals: [Pair(Script(t_peg_in_hash), 0)],
      mint: assets.from_asset(t_own_policy, "fSAT", 100),
    }
  expect t_mint(t_own_policy, tx)
}
```

Note: this test datum already uses the **new 11-field** `ConfigDatum` shape. That shape does not exist until Task 4, so `aiken check` will not pass for this file until Task 4 lands. Proceed to Step 2–3 now (delete + getter removal), and do the compile/commit at the end of Task 4 which finalizes the datum. (Tasks 2–4 form one compiling unit; commit them together at Task 4 Step 6.)

- [ ] **Step 2: Delete the checker validator**

```bash
git rm onchain/validators/bitcoin/fbtc-mint-checker.ak
```

- [ ] **Step 3: Remove the checker getter from `lib/bifrost/types/config.ak`**

Delete the function:

```aiken
pub fn get_bridged_token_mint_checker_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 19))
}
```

(The record field and pin-test line are removed in Task 4.) Do not commit yet.

---

### Task 3: cpi/cpo root NFT names as constants

**Files:**
- Modify: `lib/bifrost/constants.ak`
- Rewrite mint handler: `validators/bitcoin/completed-peg-ins-merkle-tree.ak`, `validators/bitcoin/completed-peg-outs-merkle-tree.ak`
- Modify: `validators/bitcoin/peg-in.ak` / `peg-out.ak` (read the constant for the MPF asset name)

**Interfaces:**
- Produces: `constants.completed_peg_ins_root_asset_name` (`"CPI"`), `constants.completed_peg_outs_root_asset_name` (`"CPO"`); cpi/cpo mint handler that mints exactly `(constant, 1)` and consumes the validator's `one_shot_input_ref` param; `MintRedeemer` types removed from both files.

- [ ] **Step 1: Add the constants**

In `lib/bifrost/constants.ak`, append:

```aiken
pub const completed_peg_ins_root_asset_name = "CPI"

pub const completed_peg_outs_root_asset_name = "CPO"
```

- [ ] **Step 2: Rewrite the completed-peg-ins mint handler**

In `validators/bitcoin/completed-peg-ins-merkle-tree.ak`: (a) delete the `MintRedeemer` type; (b) `use bifrost/constants`; (c) rename the param `_one_shot_input_ref` → `one_shot_input_ref`; (d) replace the `mint` handler body. New handler:

```aiken
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    let is_one_shot_spent =
      option.is_some(find_input(self.inputs, one_shot_input_ref))

    expect [completed_peg_ins_merkle_tree_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    //Exactly one token of this policy, quantity 1, with the constant name
    expect [Pair(minted_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))
    let correct_asset_name =
      minted_asset_name == constants.completed_peg_ins_root_asset_name

    let output_has_correct_datum =
      completed_peg_ins_merkle_tree_output.datum == InlineDatum(
        CompletedPegInsMerkleTreeDatum {
          root: #"0000000000000000000000000000000000000000000000000000000000000000",
        },
      )

    let output_goes_to_this_script =
      completed_peg_ins_merkle_tree_output.address == Address {
        payment_credential: Script(policy_id),
        stake_credential: None,
      }

    and {
      is_one_shot_spent,
      correct_asset_name,
      output_has_correct_datum,
      output_goes_to_this_script,
    }
  }
```

Ensure imports include `find_input` (from `cardano/transaction`) and `option`. Remove the now-unused `flatten`/`without_lovelace`/`hash_output_ref` imports if the compiler flags them.

- [ ] **Step 3: Rewrite the completed-peg-outs mint handler identically**

Same edit in `validators/bitcoin/completed-peg-outs-merkle-tree.ak`, using `constants.completed_peg_outs_root_asset_name` and the file's `CompletedPegOutsMerkleTreeDatum` type.

- [ ] **Step 4: Point peg-in/peg-out at the constant for the MPF asset name**

In `validators/bitcoin/peg-in.ak`, add `use bifrost/constants` and replace:

```aiken
    let completed_peg_ins_merkle_tree_asset_name =
      config.get_completed_peg_ins_merkle_tree_asset_name(config_fields)
```

with:

```aiken
    let completed_peg_ins_merkle_tree_asset_name =
      constants.completed_peg_ins_root_asset_name
```

In `validators/bitcoin/peg-out.ak`, add `use bifrost/constants` and replace:

```aiken
    let completed_peg_outs_merkle_tree_asset_name =
      config.get_completed_peg_outs_merkle_tree_asset_name(config_fields)
```

with:

```aiken
    let completed_peg_outs_merkle_tree_asset_name =
      constants.completed_peg_outs_root_asset_name
```

Do not commit yet (still on Task 4's compiling unit).

---

### Task 4: ConfigDatum clean rebuild (11 fields) + fSAT fixtures + build

Finalizes the compiling unit (Tasks 2–4). Rewrites the datum, re-indexes surviving getters, removes dead getters, rebuilds the pin test, updates every datum fixture to the 11-field shape with `fSAT`.

**Files:**
- Modify: `lib/bifrost/types/config.ak` (record + getters + pin test)
- Modify: `validators/bitcoin/config.ak` (fixtures)

**Interfaces:**
- Produces the 11-field `ConfigDatum` and getters at new indices: `get_bridged_token_policy_id`(0), `get_bridged_token_asset_name`(1), `get_completed_peg_ins_merkle_tree_policy_id`(2), `get_completed_peg_outs_merkle_tree_policy_id`(3), `get_peg_in_withdraw_script_hash`(4), `get_peg_out_withdraw_script_hash`(5), `get_peg_in_close_verifier_script_hash`(6), `get_legit_treasury_movement_and_peg_out_produced_verifier_script_hash`(7), `get_legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash`(8), `get_min_stake`(9), `get_update_auth`(10).

- [ ] **Step 1: Replace the `ConfigDatum` record in `lib/bifrost/types/config.ak`**

```aiken
pub type ConfigDatum {
  bridged_token_policy_id: PolicyId,
  bridged_token_asset_name: AssetName,
  completed_peg_ins_merkle_tree_policy_id: PolicyId,
  completed_peg_outs_merkle_tree_policy_id: PolicyId,
  peg_in_withdraw_script_hash: ByteArray,
  peg_out_withdraw_script_hash: ByteArray,
  //Peg-in CLOSE verifier (F4/F5). Dormant until the F1-F6 milestone; a dummy
  //hash has no reward account, so Cancel is cleanly unsatisfiable.
  peg_in_close_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_produced_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: ByteArray,
  //Off-chain-only (heimdall R2 registration gate); no on-chain reader.
  min_stake: Int,
  //Authority allowed to Update/Retire the config UTxO. None = frozen.
  update_auth: Option<AuthorizationMethod>,
}
```

- [ ] **Step 2: Replace all getters with the re-indexed set**

Delete every existing `get_*` function and the dead ones, and write exactly these (keep this order; the pin test depends on it):

```aiken
pub fn get_bridged_token_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 0))
}

pub fn get_bridged_token_asset_name(config_fields: List<Data>) -> AssetName {
  builtin.un_b_data(safe_list_at(config_fields, 1))
}

pub fn get_completed_peg_ins_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 2))
}

pub fn get_completed_peg_outs_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 3))
}

pub fn get_peg_in_withdraw_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 4))
}

pub fn get_peg_out_withdraw_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 5))
}

pub fn get_peg_in_close_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 6))
}

pub fn get_legit_treasury_movement_and_peg_out_produced_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 7))
}

pub fn get_legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 8))
}

pub fn get_min_stake(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 9))
}

pub fn get_update_auth(
  config_fields: List<Data>,
) -> Option<AuthorizationMethod> {
  expect update_auth: Option<AuthorizationMethod> =
    safe_list_at(config_fields, 10)
  update_auth
}
```

- [ ] **Step 3: Rebuild the pin test**

Replace `config_getters_match_datum_fields` with:

```aiken
test config_getters_match_datum_fields() {
  let datum =
    ConfigDatum {
      bridged_token_policy_id: #"aa00",
      bridged_token_asset_name: #"aa01",
      completed_peg_ins_merkle_tree_policy_id: #"aa02",
      completed_peg_outs_merkle_tree_policy_id: #"aa03",
      peg_in_withdraw_script_hash: #"aa04",
      peg_out_withdraw_script_hash: #"aa05",
      peg_in_close_verifier_script_hash: #"aa06",
      legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa07",
      legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aa08",
      min_stake: 9,
      update_auth: Some(CardanoSignature { hash: #"aa10" }),
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  and {
    get_bridged_token_policy_id(fields) == datum.bridged_token_policy_id,
    get_bridged_token_asset_name(fields) == datum.bridged_token_asset_name,
    get_completed_peg_ins_merkle_tree_policy_id(fields) == datum.completed_peg_ins_merkle_tree_policy_id,
    get_completed_peg_outs_merkle_tree_policy_id(fields) == datum.completed_peg_outs_merkle_tree_policy_id,
    get_peg_in_withdraw_script_hash(fields) == datum.peg_in_withdraw_script_hash,
    get_peg_out_withdraw_script_hash(fields) == datum.peg_out_withdraw_script_hash,
    get_peg_in_close_verifier_script_hash(fields) == datum.peg_in_close_verifier_script_hash,
    get_legit_treasury_movement_and_peg_out_produced_verifier_script_hash(fields) == datum.legit_treasury_movement_and_peg_out_produced_verifier_script_hash,
    get_legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash(fields) == datum.legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash,
    get_min_stake(fields) == datum.min_stake,
    get_update_auth(fields) == datum.update_auth,
  }
}
```

Verify the `CardanoSignature` import is still present at the top of the file.

- [ ] **Step 4: Update fixtures in `validators/bitcoin/config.ak`**

Replace the `t_datum` constructor body (fields between `ConfigDatum {` and the closing `}`) with the 11-field shape:

```aiken
  ConfigDatum {
    bridged_token_policy_id: #"aa111111111111111111111111111111111111111111111111111111",
    bridged_token_asset_name: "fSAT",
    completed_peg_ins_merkle_tree_policy_id: #"aa444444444444444444444444444444444444444444444444444444",
    completed_peg_outs_merkle_tree_policy_id: #"aa555555555555555555555555555555555555555555555555555555",
    peg_in_withdraw_script_hash: #"aa666666666666666666666666666666666666666666666666666666",
    peg_out_withdraw_script_hash: #"aa777777777777777777777777777777777777777777777777777777",
    peg_in_close_verifier_script_hash: #"aa888888888888888888888888888888888888888888888888888888",
    legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa999999999999999999999999999999999999999999999999999999",
    legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    min_stake: 100_000_000,
    update_auth,
  }
```

If any other test in `config.ak` references a removed field (e.g. `..old_datum, min_stake: 42` still works; `bridged_token_asset_name: "fBTC2"` in `update_allows_changing_bridged_token_identity` → change literal to `"fSAT2"`), fix those literals. Grep for `fBTC` in the file and switch to `fSAT`.

- [ ] **Step 5: Run the full suite**

Run: `aiken check`
Expected: exit 0, all tests pass (includes the new `bridged_token` tests from Task 2, the constant-name cpi/cpo mint handler, and the rebuilt pin test). If a validator fails to compile, it is a missed reader of a removed getter or the old datum shape – fix by re-pointing to a surviving getter or constant.

- [ ] **Step 6: Build the blueprint and commit Tasks 2–4**

```bash
aiken build
grep -o '"title": "bitcoin/[^"]*"' onchain/plutus.json | sort -u   # confirm no fbtc_mint_checker.* title remains
git add onchain/lib/bifrost/constants.ak onchain/lib/bifrost/types/config.ak \
        onchain/validators/bitcoin/bridged-token.ak onchain/validators/bitcoin/config.ak \
        onchain/validators/bitcoin/peg-in.ak onchain/validators/bitcoin/peg-out.ak \
        onchain/validators/bitcoin/completed-peg-ins-merkle-tree.ak \
        onchain/validators/bitcoin/completed-peg-outs-merkle-tree.ak \
        onchain/plutus.json
git rm --cached onchain/validators/bitcoin/fbtc-mint-checker.ak 2>/dev/null || true
git commit -m "feat(onchain): Variant B mint delegation + 11-field ConfigDatum + CPI/CPO constants + fSAT"
```

---

## Phase B – Off-chain (binocular). Run all commands from `offchain/bitcoin-watchtower/binocular/`.

### Task 5: `ConfigTypes.scala` 11-field mirror + redeemer changes

**Files:**
- Modify: `src/main/scala/binocular/watchtower/ConfigTypes.scala`
- Test: `src/test/scala/binocular/ConfigDatumEncodingTest.scala`

**Interfaces:**
- Produces: `ConfigDatum` with 11 positional fields (order matching the Aiken record); `updateAuth` at index 10 as `scalus.cardano.onchain.plutus.prelude.Option[AuthorizationMethod]`; `BridgedTokenMintRedeemer(configRefInputIndex: BigInt)`; removes `FbtcMintCheckerRedeemer`; `CompletedPegInsMintRedeemer` / `CompletedPegOutsMintRedeemer` no longer carry `inputRef` (mint redeemer is `Data.unit`).

- [ ] **Step 1: Update the encoding test**

Replace the body of `src/test/scala/binocular/ConfigDatumEncodingTest.scala`'s "20 positional fields" test with an 11-field assertion:

```scala
    test("ConfigDatum has 11 positional fields; update_auth is field 10") {
        val d = ConfigDatum(
          bridgedTokenPolicyId = ByteString.fromHex("aa" * 28),
          bridgedTokenAssetName = ByteString.fromString("fSAT"),
          completedPegInsMerkleTreePolicyId = ByteString.empty,
          completedPegOutsMerkleTreePolicyId = ByteString.empty,
          pegInWithdrawScriptHash = ByteString.empty,
          pegOutWithdrawScriptHash = ByteString.empty,
          pegInCloseVerifierScriptHash = ByteString.empty,
          legitTmAndPegOutProducedVerifierScriptHash = ByteString.empty,
          legitTmAndPegOutNotProducedVerifierScriptHash = ByteString.empty,
          minStake = BigInt(0),
          updateAuth = POption.None
        )
        d.toData match {
            case Data.Constr(0, fields) =>
                val fs = fields.asScala.toIndexedSeq
                assert(fs.size == 11)
                assert(fs(10) == Data.Constr(1, PList()))
            case other => fail(s"expected Constr 0, got $other")
        }
    }
```

Keep the existing `updateAuth Some/None encode as Constr 0/1` test unchanged.

- [ ] **Step 2: Run it (fails to compile – expected)**

Run: `sbt -batch "testOnly binocular.ConfigDatumEncodingTest"`
Expected: FAIL – `ConfigDatum` still has the old fields.

- [ ] **Step 3: Rewrite `ConfigDatum` and redeemers in `ConfigTypes.scala`**

Replace the `ConfigDatum` case class with the 11-field version (drop the class doc's stale field notes):

```scala
case class ConfigDatum(
    bridgedTokenPolicyId: ByteString,
    bridgedTokenAssetName: ByteString,
    completedPegInsMerkleTreePolicyId: ByteString,
    completedPegOutsMerkleTreePolicyId: ByteString,
    pegInWithdrawScriptHash: ByteString,
    pegOutWithdrawScriptHash: ByteString,
    pegInCloseVerifierScriptHash: ByteString,
    legitTmAndPegOutProducedVerifierScriptHash: ByteString,
    legitTmAndPegOutNotProducedVerifierScriptHash: ByteString,
    minStake: BigInt,
    updateAuth: scalus.cardano.onchain.plutus.prelude.Option[AuthorizationMethod]
) derives FromData,
      ToData
```

Replace `BridgedTokenMintRedeemer` with the single-field version and **delete** `FbtcMintCheckerRedeemer`:

```scala
case class BridgedTokenMintRedeemer(
    configRefInputIndex: BigInt
) derives FromData,
      ToData
```

Replace `CompletedPegInsMintRedeemer` (and the peg-outs equivalent, wherever defined) so the cpi/cpo mint no longer carries `inputRef` – the mint redeemer becomes `Data.unit` at call sites, so delete these case classes if they exist and are only used for the mint. (Search: `CompletedPegInsMintRedeemer`, `CompletedPegOutsMintRedeemer`.)

- [ ] **Step 4: Run the encoding test after restart**

Run: `sbt shutdown; sbt -batch "testOnly binocular.ConfigDatumEncodingTest"`
Expected: `sbt compile` still fails elsewhere (BifrostContracts/commands reference removed types) – that is Tasks 6–8. Do not commit; proceed.

---

### Task 6: `BifrostContracts.scala` – remove checker, cpi/cpo constant names

**Files:**
- Modify: `src/main/scala/binocular/watchtower/BifrostContracts.scala`

**Interfaces:**
- Produces: no `FbtcMintCheckerContract`; `CompletedPegInsContract.assetName` returns the constant `ByteString.fromString("CPI")`; `CompletedPegOutsContract.assetName` returns `"CPO"`.

- [ ] **Step 1: Delete `FbtcMintCheckerContract`**

Remove the `final case class FbtcMintCheckerContract` and its companion `object` entirely.

- [ ] **Step 2: cpi/cpo asset names → constants**

In `object CompletedPegInsContract`, replace:

```scala
    def assetName(oneShotInputRef: TxOutRef): ByteString =
        Builtins.sha2_256(Builtins.serialiseData(oneShotInputRef.toData))
```

with:

```scala
    /** Constant per completed-peg-ins-merkle-tree.ak. */
    val assetName: ByteString = ByteString.fromString("CPI")
```

Same in `object CompletedPegOutsContract` with `"CPO"`. Callers that pass a ref (`CompletedPegInsContract.assetName(cpiRef)`) become `CompletedPegInsContract.assetName` – fix at the call sites in Task 8. Leave the `one_shot_input_ref` param on the contract `apply` (the policy id still needs it).

- [ ] **Step 3: Do not commit** (compile still red until Tasks 7–8).

---

### Task 7: Remove the checker withdrawal from completion tx builders

**Files:**
- Modify: `src/main/scala/binocular/watchtower/PegInCompleteTx.scala`
- Modify: `src/main/scala/binocular/watchtower/PegOutCompleteTx.scala`

**Interfaces:**
- Produces: `PegInCompleteTx.Scripts(pegIn, completedPegIns, bridgedToken)` (drop `fbtcMintChecker`); `PegOutCompleteTx.Scripts(pegOut, completedPegOuts, bridgedToken, producedVerifier)` (drop `fbtcMintChecker`).

- [ ] **Step 1: `PegInCompleteTx.scala`**

- Remove `fbtcMintChecker` from `Scripts`.
- Delete the `fbtcMintCheckerRedeemer` builder and the `checkerWithdrawWitness`.
- Delete the `.withdrawRewards(stake(scripts.fbtcMintChecker.scriptHash), Coin.zero, checkerWithdrawWitness)` line.
- `bridgedTokenMintRedeemer` stays `BridgedTokenMintRedeemer(configRefInputIndex = configRefIndex(tx))`.
- Update the `Scala doc` "Withdrawals" bullet back to a single `peg_in` withdrawal.

- [ ] **Step 2: `PegOutCompleteTx.scala`**

- Remove `fbtcMintChecker` from `Scripts`; delete its redeemer builder, witness, and `withdrawRewards` line.
- Peg-out keeps its two withdrawals (`peg_out` + produced verifier).
- Update the doc "Withdrawals" bullet.

- [ ] **Step 3: Do not commit** (commands still reference old shapes).

---

### Task 8: Command wiring (deploy, register, both completes)

**Files:**
- Modify: `src/main/scala/binocular/cli/commands/DeployBridgeCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/RegisterBridgeCredsCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/PegInCompleteCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/PegOutCompleteCommand.scala`

- [ ] **Step 1: `DeployBridgeCommand.scala`**

- Change `BridgedTokenAssetName` default to `ByteString.fromString("fSAT")`.
- Delete the `fbtcMintChecker` derivation, its `Console.info`, and its use.
- Replace the `configDatum = ConfigDatum(...)` construction with the 11-field version (drop the source-chain/block-header/treasury/checker fields and the cpi/cpo asset-name fields; keep `updateAuth` = the sponsor signature as before):

```scala
        val configDatum = ConfigDatum(
          bridgedTokenPolicyId = bridgedTokenPolicy,
          bridgedTokenAssetName = BridgedTokenAssetName,
          completedPegInsMerkleTreePolicyId = cpiPolicy,
          completedPegOutsMerkleTreePolicyId = cpoPolicy,
          pegInWithdrawScriptHash = pegInWithdrawHash,
          pegOutWithdrawScriptHash = pegOutWithdrawHash,
          pegInCloseVerifierScriptHash = Dummy28,
          legitTmAndPegOutProducedVerifierScriptHash = pegOutProducedVerifierHash,
          legitTmAndPegOutNotProducedVerifierScriptHash = pegOutNotProducedVerifierHash,
          minStake = BigInt(0),
          updateAuth = scalus.cardano.onchain.plutus.prelude.Option.Some(
            AuthorizationMethod.CardanoSignature(
              ByteString.fromArray(setup.hdAccount.paymentKeyHash.bytes)
            )
          )
        )
```

- The cpi/cpo NFTs are minted with the constant asset names: `val cpiAssetName = CompletedPegInsContract.assetName` (drop the `(cpiRef)` arg), same for cpo. The mint redeemer for cpi/cpo becomes `Data.unit` (drop `CompletedPegInsMintRedeemer(cpiRef)` etc.). Update the `.mint(...)` calls accordingly.

- [ ] **Step 2: `RegisterBridgeCredsCommand.scala`**

Delete the `fbtcMintChecker` derivation and its `creds` entry; restore the doc comment to "peg-in runs ONE rewarding script (peg_in); peg-out runs TWO (peg_out + produced verifier)".

- [ ] **Step 3: `PegInCompleteCommand.scala` / `PegOutCompleteCommand.scala`**

- Delete the `FbtcMintCheckerContract(...)` construction in both.
- `PegInCompleteTx.Scripts(pegIn.script, cpiContract.script, bridgedToken.script)` (drop 4th arg).
- `PegOutCompleteTx.Scripts(pegOut.script, cpoContract.script, bridgedToken.script, producedVerifier)` (drop 5th arg).
- Fix `cpiAsset` / `cpoAsset` to use the constant: `AssetName(CompletedPegInsContract.assetName)` (drop `(cpiRef)`).

- [ ] **Step 4: Compile**

Run: `sbt -batch scalafmtAll && sbt -batch compile`
Expected: success (this closes the red window from Tasks 5–7).

- [ ] **Step 5: Do not commit yet** (tests still lock old hashes – Task 9).

---

### Task 9: Blueprint resource + hash locks + full verification

**Files:**
- Modify: `src/test/resources/bifrost-plutus-min.json`
- Modify: `src/test/scala/binocular/BifrostContractsTest.scala`

- [ ] **Step 1: Regenerate the trimmed blueprint resource from the new `onchain/plutus.json`**

The tests reference `config.mint`, `bridged_token.mint`, `completed_peg_ins_merkle_tree.mint`, `completed_peg_outs_merkle_tree.mint`, `peg_in.mint` (no more checker). Regenerate:

```bash
python3 -c "
import json
src = json.load(open('../../../onchain/plutus.json'))
keep = [
  'bitcoin/config.config.mint',
  'bitcoin/bridged_token.bridged_token.mint',
  'bitcoin/completed_peg_ins_merkle_tree.completed_peg_ins_merkle_tree_validator.mint',
  'bitcoin/completed_peg_outs_merkle_tree.completed_peg_outs_merkle_tree_validator.mint',
  'bitcoin/peg_in.peg_in_validator.mint',
]
vals = [{'title': v['title'], 'compiledCode': v['compiledCode']} for v in src['validators'] if v['title'] in keep]
assert len(vals) == len(keep), [v['title'] for v in vals]
json.dump({'validators': vals}, open('src/test/resources/bifrost-plutus-min.json','w'), indent=1)
print('ok')
"
```

Remove the `fbtc_mint_checker` known-answer test from `BifrostContractsTest.scala` if present.

- [ ] **Step 2: Restart sbt, harvest the new hashes**

Run: `sbt shutdown; rm -rf target/out; sbt -batch "testOnly binocular.BifrostContractsTest"`
Expected: the known-answer tests FAIL, printing the freshly computed hashes. **Because sbt 2.x caches the resource, always `rm -rf target/out` (or `sbt shutdown`) before trusting a hash-lock run** (see Global Constraints).

- [ ] **Step 3: Update the known-answer constants**

Replace each expected hex in `BifrostContractsTest.scala` (config policy, bridged_token policy, cpi policy+asset, peg_in policy) with the printed actual values. Note the cpi/cpo **asset name** assertions now expect the constant bytes: `CompletedPegInsContract.assetName == ByteString.fromString("CPI")` (and `"CPO"`), not `sha2_256(...)`. Keep the "regression lock, re-validated at next deploy" comment.

- [ ] **Step 4: Full verification**

Run: `sbt -batch scalafmtAll && sbt shutdown && sbt -batch "compile; test"`
Expected: all tests pass.

- [ ] **Step 5: Commit the off-chain work (single commit for the binocular submodule)**

```bash
# inside the submodule
git add -A src
git commit -m "feat: Variant B + 11-field ConfigDatum + CPI/CPO constants + fSAT (binocular)"
```

- [ ] **Step 6: Bump the submodule pointer in the parent repo**

```bash
cd ../../..    # repo root
git add offchain/bitcoin-watchtower/binocular
git commit -m "feat(offchain): bump binocular - Variant B + ConfigDatum rebuild"
```

---

## Final verification (whole plan)

1. `cd onchain && aiken check && aiken build` – green; `plutus.json` has no `fbtc_mint_checker` title.
2. `cd offchain/bitcoin-watchtower/binocular && sbt shutdown && rm -rf target/out && sbt scalafmtAll && sbt compile && sbt test` – green.
3. `git -C offchain/bitcoin-watchtower/binocular grep -l FbtcMintChecker` – no matches.
4. `git log --oneline` shows the on-chain commit, the binocular commit, and the submodule bump; no Co-Authored-By trailers.

## Notes for the implementer

- **Deployment impact:** every script hash changes, so a live testnet bridge is orphaned; a fresh `deploy-bridge` → `register-bridge-creds` → `deploy-script-refs` cycle is required afterward. This plan does not run a deploy.
- **Out of scope (do not touch):** `general-spend.ak` (reads `config[1]` as a `Credential`, pre-existing, unrelated); the F1-F6 close/cancel logic (fields 6 & 8 stay dormant placeholders); the CLI restructuring and FluidTokens migration doc (later specs).
