use aiken/collection/pairs
use bifrost/types/config.{ConfigDatum}
use bifrost/types/general.{CardanoSignature}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, placeholder,
}

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
    //Anchor the delegation to THIS policy. The checker validates the mint of
    //the policy named by config[0] (bridged_token_policy_id); since this
    //policy never inspects self.mint itself, config[0] must equal our own
    //policy id, otherwise our mint would be unconstrained while the checker
    //polices a different policy. config[0] is the fBTC identity = our own
    //hash by construction, so this only ever fails on a broken config.
    expect config.get_bridged_token_policy_id(config_fields) == policy_id
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

//config[0] must equal the minting policy id: else the checker (which reads
//config[0]) would constrain a different policy, leaving this mint unpoliced.
test mint_rejects_config_policy_id_mismatch() fail {
  let other_policy =
    #"bb111111111111111111111111111111111111111111111111111111"
  let tx =
    Transaction {
      ..placeholder,
      reference_inputs: [t_config_ref_input()],
      withdrawals: [Pair(Script(t_checker_hash), 0)],
      mint: assets.from_asset(other_policy, "fBTC", 100),
    }
  expect
    bridged_token.mint(
      t_config_policy,
      t_config_asset,
      MintRedeemer { config_ref_input_index: 0 },
      other_policy,
      tx,
    )
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
