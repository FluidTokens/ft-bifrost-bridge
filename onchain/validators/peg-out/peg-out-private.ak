use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/option
use aiken/primitive/bytearray
use bifrost/constants
use bifrost/types/bitcoin_oracle.{OracleState}
use bifrost/types/peg_out/peg_out_private.{
  Cancel, PegOutPrivateDatum, PegOutPrivateMintRedeemer,
  PegOutPrivateWithdrawRedeemer, Prove,
}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, find_input}

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
    let treasury_info_nft_policy_id =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let btc_policy_id = builtin.un_b_data(utils.safe_list_at(config, 2))
    let minted_tokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(token_pair) { token_pair.2nd > 0 },
      )
    if list.length(minted_tokens) > 0 {
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
            expect InlineDatum(output_datum) = output.datum
            expect datum: PegOutPrivateDatum = output_datum
            let treasury_info_ref_input =
              utils.safe_list_at(
                self.reference_inputs,
                redeemer.treasury_info_ref_input_index,
              )
            let treasury_info =
              utils.get_treasury_info_as_data_list(
                treasury_info_ref_input,
                treasury_info_nft_policy_id,
              )
            let current_treasury_btc_address =
              builtin.un_b_data(utils.safe_list_at(treasury_info, 0))
            let output_has_correct_datum = and {
                datum.treasury_btc_address == current_treasury_btc_address,
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
          Cancel {
            peg_out_private_token_asset_name,
            oracle_state_ref_input_index,
            treasury_info_ref_input_index,
          } -> {
            let btc_oracle_policy_id =
              builtin.un_b_data(utils.safe_list_at(config, 2))

            let oracle_state_ref_input =
              utils.safe_list_at(
                self.reference_inputs,
                oracle_state_ref_input_index,
              )

            let oracle_state =
              utils.get_oracle_state(
                oracle_state_ref_input,
                btc_oracle_policy_id,
              )
            let treasury_info_nft_policy_id =
              builtin.un_b_data(utils.safe_list_at(config, 0))
            let treasury_info_ref_input =
              utils.safe_list_at(
                self.reference_inputs,
                treasury_info_ref_input_index,
              )
            let treasury_info =
              utils.get_treasury_info_as_data_list(
                treasury_info_ref_input,
                treasury_info_nft_policy_id,
              )
            let current_treasury_btc_address =
              builtin.un_b_data(utils.safe_list_at(treasury_info, 0))
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
            let zk_verification =
              zk_verify_missed_peg_out(
                oracle_state,
                datum.treasury_btc_address,
                current_treasury_btc_address,
                peg_out_private_token_asset_name,
              )
            and {
              is_owner,
              burn_the_nft,
              datum.treasury_btc_address != current_treasury_btc_address,
              zk_verification,
            }
          }
          Prove {
            peg_out_private_token_asset_name,
            oracle_state_ref_input_index,
          } -> {
            let btc_policy_id = builtin.un_b_data(utils.safe_list_at(config, 1))
            let btc_oracle_policy_id =
              builtin.un_b_data(utils.safe_list_at(config, 2))

            let oracle_state_ref_input =
              utils.safe_list_at(
                self.reference_inputs,
                oracle_state_ref_input_index,
              )

            let oracle_state =
              utils.get_oracle_state(
                oracle_state_ref_input,
                btc_oracle_policy_id,
              )
            let zk_verification =
              zk_verify_refund(
                oracle_state,
                datum.treasury_btc_address,
                peg_out_private_token_asset_name,
              )
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
            let burn_the_btc =
              quantity_of(self.mint, btc_policy_id, constants.btc_asset_name) == datum.btc_amount_to_burn * -1
            and {
              is_owner,
              zk_verification,
              burn_the_nft,
              burn_the_btc,
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

fn zk_verify_missed_peg_out(
  _oracle_state: OracleState,
  _old_treasury_btc_address: ByteArray,
  _new_treasury_btc_address: ByteArray,
  _peg_out_private_nft_asset_name: ByteArray,
) {
  //TODO zk proof of the treasury movement tx where:
  //1) the tx has happened coming from old_treasury_btc_address to new_treasury_btc_address
  //2) no output goes to datum.btc_destination_address with output.metadata == peg_out_private_nft_asset_name
  True
}

fn zk_verify_refund(
  _oracle_state: OracleState,
  _treasury_btc_address: ByteArray,
  _peg_out_private_nft_asset_name: ByteArray,
) {
  //TODO zk proof of the treasury movement tx where:
  //1) the refund has happened coming from treasury_btc_address
  //2) datum.btc_destination_address receives exactly btc_amount_to_burn BTC
  //3) output.metadata == peg_out_private_nft_asset_name
  True
}
