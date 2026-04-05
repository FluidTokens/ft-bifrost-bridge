use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/option
use bifrost/utils
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/assets.{PolicyId, flatten, quantity_of, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, find_input,
}

pub type CompletedPegOutsMerkleTreeDatum {
  root: ByteArray,
}

pub type MintRedeemer {
  input_ref: OutputReference,
}

validator completed_peg_outs_merkle_tree_validator(
  //TODO Circular dependency
  peg_out_withdraw_script_hash: ByteArray,
  one_shot_input_ref: OutputReference,
) {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, self: Transaction) {
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
    _redeemer: Data,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(script_hash), _amnt) ->
            script_hash == peg_out_withdraw_script_hash
          _ -> False
        }
      },
    )
  }

  else(_ctx: ScriptContext) {
    False
  }
}
