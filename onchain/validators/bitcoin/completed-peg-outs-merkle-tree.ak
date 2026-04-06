use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/option
use bifrost/types/peg_out.{CompletePegOut, PegOutWithdrawRedeemer}
use bifrost/utils
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/assets.{PolicyId, flatten, quantity_of, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, Withdraw, find_input,
}

pub type CompletedPegOutsMerkleTreeDatum {
  root: ByteArray,
}

pub type MintRedeemer {
  input_ref: OutputReference,
  config_ref_input_index: Int,
}

pub type SpendRedeemer {
  config_ref_input_index: Int,
  peg_out_withdraw_redeemer_index: Int,
}

validator completed_peg_outs_merkle_tree_validator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  one_shot_input_ref: OutputReference,
) {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let peg_out_withdraw_script_hash =
      builtin.un_b_data(utils.safe_list_at(config, 11))
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent =
      option.is_some(find_input(self.inputs, redeemer.input_ref))

    let minted_tokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(Pair(_asset_name, quantity)) { quantity > 0 },
      )

    expect [completed_peg_outs_merkle_tree_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    //Minted tokens from this policy id must be only 1 and with quantity 1
    expect [Pair(this_token_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))

    //AssetName must be correct
    expect [(this_token_policy_id, this_token_asset_name, 1)] =
      flatten(without_lovelace(completed_peg_outs_merkle_tree_output.value))
    let only_minted_token_is_correctly_in_output = and {
        this_token_policy_id == policy_id,
        this_token_asset_name == input_ref_hash,
      }
    //Output must contain proper InlineDatum
    let output_has_correct_datum =
      completed_peg_outs_merkle_tree_output.datum == InlineDatum(
        CompletedPegOutsMerkleTreeDatum {
          root: #"0000000000000000000000000000000000000000000000000000000000000000",
        },
      )

    //Output with the minted token must go to this script
    let output_goes_to_this_script =
      completed_peg_outs_merkle_tree_output.address == Address {
        payment_credential: Script(policy_id),
        stake_credential: None,
      }

    and {
      is_input_ref_spent,
      only_minted_token_is_correctly_in_output,
      output_has_correct_datum,
      output_goes_to_this_script,
    }
  }

  spend(
    _datumOpt: Option<Data>,
    redeemer: SpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let peg_out_withdraw_script_hash =
      builtin.un_b_data(utils.safe_list_at(config, 11))
    let peg_out_withdraw_redeemer =
      utils.safe_list_at(
        self.redeemers,
        redeemer.peg_out_withdraw_redeemer_index,
      )
    expect
      peg_out_withdraw_redeemer.1st == Withdraw(
        Script(peg_out_withdraw_script_hash),
      )
    expect peg_out_redeemer: PegOutWithdrawRedeemer =
      peg_out_withdraw_redeemer.2nd

    and {
      when peg_out_redeemer.action_type is {
        CompletePegOut { .. } -> True
        _ -> False
      },
      list.any(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(script_hash), _amnt) ->
              script_hash == peg_out_withdraw_script_hash
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
