use aiken/collection/dict
use aiken/collection/list
use aiken/option
use bifrost/constants
use bifrost/types/config
use bifrost/types/peg_in.{CompletePegIn, PegInWithdrawRedeemer}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, OutputReference, Transaction, Withdraw, find_input,
}

pub type CompletedPegInsMerkleTreeDatum {
  root: ByteArray,
}

pub type SpendRedeemer {
  config_ref_input_index: Int,
  peg_in_withdraw_redeemer_index: Int,
}

validator completed_peg_ins_merkle_tree_validator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  one_shot_input_ref: OutputReference,
) {
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

  spend(
    _datumOpt: Option<Data>,
    redeemer: SpendRedeemer,
    _own_ref: OutputReference,
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
    let peg_in_withdraw_script_hash =
      config.get_peg_in_withdraw_script_hash(config_fields)
    let peg_in_withdraw_redeemer =
      utils.safe_list_at(
        self.redeemers,
        redeemer.peg_in_withdraw_redeemer_index,
      )
    expect
      peg_in_withdraw_redeemer.1st == Withdraw(
        Script(peg_in_withdraw_script_hash),
      )
    expect peg_in_redeemer: PegInWithdrawRedeemer = peg_in_withdraw_redeemer.2nd

    and {
      when peg_in_redeemer.action_type is {
        CompletePegIn { .. } -> True
        _ -> False
      },
      list.any(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(script_hash), _amnt) ->
              script_hash == peg_in_withdraw_script_hash
            _ -> False
          }
        },
      ),
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}
