use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/option
use aiken/primitive/bytearray
use bifrost/types/peg_in.{
  Cancel, PegInDatum, PegInMintRedeemer, PegInWithdrawRedeemer, Prove,
}
use bifrost/utils.{hash_output_ref}
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, Transaction, Withdraw, find_input,
}

validator peg_in_validator(
  config_policy_id: ByteArray,
  config_asset_name: ByteArray,
  peg_in_spend_script_hash: ByteArray,
) {
  //We exclude the burnt tokens (quantity < 0) as they are always allowed
  //Each minted token must be unique 
  mint(redeemer: PegInMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let minted_tokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(tokenPair) { tokenPair.2nd > 0 },
      )
    let peg_in_outputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(peg_in_spend_script_hash)
        },
      )
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent =
      option.is_some(find_input(self.inputs, redeemer.input_ref))
    if list.length(minted_tokens) > 0 {
      let is_each_minted_token_accounted_for =
        list.indexed_foldr(
          minted_tokens,
          True,
          fn(index, Pair(asset_name, quantity), result) {
            expect result

            let correct_asset_name = and {
                bytearray.at(asset_name, 0) == index,
                bytearray.drop(asset_name, 1) == input_ref_hash,
              }

            let output = utils.safe_list_at(peg_in_outputs, index)
            let output_has_unique_token = and {
                dict.size(assets.tokens(output.value, policy_id)) == 1,
                assets.quantity_of(output.value, policy_id, asset_name) == 1,
              }
            //TODO
            let output_has_correct_datum = True
            and {
              quantity == 1,
              correct_asset_name,
              output_has_unique_token,
              output_has_correct_datum,
            }
          },
        )

      and {
        is_input_ref_spent,
        is_each_minted_token_accounted_for,
      }
    } else {
      True
    }
  }

  withdraw(
    redeemer: PegInWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(peg_in_policy_id) = credential
    let config =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        config_policy_id,
        config_asset_name,
      )

    let peg_in_inputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            peg_in_spend_script_hash,
          )
        },
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      peg_in_inputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(input_datum) = input.output.datum
        expect datum: PegInDatum = input_datum
        let redeemer_action =
          utils.safe_list_at(redeemer.actions_for_each_input, index)
        when redeemer_action is {
          Cancel -> {
            //TODO
            let burn_the_nft = True
            burn_the_nft
          }
          Prove -> {
            //TODO
            let zk_verification = True
            zk_verification
          }
        }
      },
    )
  }

  else(_) {
    fail
  }
}
