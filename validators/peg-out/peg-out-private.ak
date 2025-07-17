use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/option
use aiken/primitive/bytearray
use bifrost/constants.{btc_asset_name}
use bifrost/types/peg_out/peg_out_private.{
  Cancel, PegOutPrivateDatum, PegOutPrivateMintRedeemer,
  PegOutPrivateWithdrawRedeemer, Prove,
}
use bifrost/types/treasury_movement.{TreasuryMovementDatum}
use bifrost/utils.{hash_output_ref}
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, Transaction, Withdraw, find_input,
}

validator peg_out_private_validator(
  config_policy_id: ByteArray,
  config_asset_name: ByteArray,
  peg_out_private_spend_script_hash: ByteArray,
) {
  //We exclude the burnt tokens (quantity < 0) as they are always allowed
  //Each minted token must be unique and in the peg-in spend script
  mint(
    redeemer: PegOutPrivateMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        config_policy_id,
        config_asset_name,
      )
    let treasury_movement_nft_policy_id =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let treasury_movement_nft_asset_name =
      builtin.un_b_data(utils.safe_list_at(config, 1))
    let btc_policy_id = builtin.un_b_data(utils.safe_list_at(config, 2))
    let minted_tokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(tokenPair) { tokenPair.2nd > 0 },
      )
    let peg_out_private_outputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(
            peg_out_private_spend_script_hash,
          )
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

            let output = utils.safe_list_at(peg_out_private_outputs, index)
            let output_has_unique_token = and {
                dict.size(assets.tokens(output.value, policy_id)) == 1,
                assets.quantity_of(output.value, policy_id, asset_name) == 1,
              }
            expect InlineDatum(outputDatum) = output.datum
            expect datum: PegOutPrivateDatum = outputDatum
            let treasury_movement_ref_input =
              utils.safe_list_at(
                self.reference_inputs,
                redeemer.treasury_movement_ref_input_index,
              )
            let output_has_correct_datum = and {
                datum.treasury_btc_address == get_current_treasury_btc_address(
                  treasury_movement_nft_policy_id,
                  treasury_movement_nft_asset_name,
                  treasury_movement_ref_input.output,
                ),
                datum.btc_amount_to_burn == quantity_of(
                  output.value,
                  btc_policy_id,
                  constants.btc_asset_name,
                ),
              }
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
    redeemer: PegOutPrivateWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(peg_out_private_policy_id) = credential
    let config =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        config_policy_id,
        config_asset_name,
      )

    let peg_out_private_inputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            peg_out_private_spend_script_hash,
          )
        },
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      peg_out_private_inputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(input_datum) = input.output.datum
        expect datum: PegOutPrivateDatum = input_datum
        let redeemer_action =
          utils.safe_list_at(redeemer.actions_for_each_input, index)
        let is_owner =
          utils.is_signed_by(datum.ada_user_address, self.extra_signatories)
        when redeemer_action is {
          Cancel { peg_out_private_token_asset_name } -> {
            let burn_the_nft = and {
                quantity_of(
                  input.output.value,
                  peg_out_private_policy_id,
                  peg_out_private_token_asset_name,
                ) == 1,
                quantity_of(
                  self.mint,
                  peg_out_private_policy_id,
                  peg_out_private_token_asset_name,
                ) == -1,
              }
            and {
              is_owner,
              burn_the_nft,
            }
          }
          Prove { peg_out_private_token_asset_name } -> {
            //TODO zk proof of the treasury movement tx where:
            //1) the refund has happened coming from datum.treasury_btc_address
            //2) datum.ada_user_address receives exactly btc_amount_to_burn BTC
            let zk_verification = True
            let burn_the_nft = and {
                quantity_of(
                  input.output.value,
                  peg_out_private_policy_id,
                  peg_out_private_token_asset_name,
                ) == 1,
                quantity_of(
                  self.mint,
                  peg_out_private_policy_id,
                  peg_out_private_token_asset_name,
                ) == -1,
              }
            and {
              is_owner,
              zk_verification,
              burn_the_nft,
            }
          }
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn get_current_treasury_btc_address(
  treasury_movement_nft_policy_id: ByteArray,
  treasury_movement_nft_asset_name: ByteArray,
  treasury_movement_ref_input_output: Output,
) {
  expect InlineDatum(outputDatum) = treasury_movement_ref_input_output.datum
  expect datum: TreasuryMovementDatum = outputDatum
  expect
    quantity_of(
      treasury_movement_ref_input_output.value,
      treasury_movement_nft_policy_id,
      treasury_movement_nft_asset_name,
    ) == 1
  datum.current_treasury_btc_address
}
