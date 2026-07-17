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
