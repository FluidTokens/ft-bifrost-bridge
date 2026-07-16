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

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

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
    CheckerRedeemer {
      config_ref_input_index: 0,
      peg_withdraw_redeemer_index: 0,
    },
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
            Script(
              #"ff11111111111111111111111111111111111111111111111111111111",
            ),
          ),
          unrelated,
        ),
      ],
    }
  expect t_withdraw(tx)
}
