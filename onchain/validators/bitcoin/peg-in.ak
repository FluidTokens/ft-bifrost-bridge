use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/option
use aiken/primitive/bytearray
use bifrost/types/bitcoin_oracle.{OracleState}
use bifrost/types/peg_in.{
  Cancel, PegInDatum, PegInMintRedeemer, PegInWithdrawRedeemer, Prove,
}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, find_input}

validator peg_in_validator(
  config_policy_id: ByteArray,
  config_asset_name: ByteArray,
  peg_in_spend_script_hash: ByteArray,
) {
  //We exclude the burnt tokens (quantity < 0) as they are always allowed
  //Each minted token must be unique and in the peg-in spend script
  mint(redeemer: PegInMintRedeemer, policy_id: PolicyId, self: Transaction) {
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
    let minted_tokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(tokenPair) { tokenPair.2nd > 0 },
      )
    if list.length(minted_tokens) > 0 {
      let peg_in_outputs =
        list.filter(
          self.outputs,
          fn(output) {
            output.address.payment_credential == Script(
              peg_in_spend_script_hash,
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

            let output = utils.safe_list_at(peg_in_outputs, index)
            let output_has_unique_token = and {
                dict.size(assets.tokens(output.value, policy_id)) == 1,
                assets.quantity_of(output.value, policy_id, asset_name) == 1,
              }
            expect InlineDatum(outputDatum) = output.datum
            expect datum: PegInDatum = outputDatum
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
            let output_has_correct_datum =
              datum.treasury_btc_address == current_treasury_btc_address
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

        let is_owner =
          utils.is_signed_by(datum.ada_user_address, self.extra_signatories)
        when redeemer_action is {
          Cancel { peg_in_token_asset_name } -> {
            let burn_the_nft = and {
                quantity_of(
                  input.output.value,
                  peg_in_policy_id,
                  peg_in_token_asset_name,
                ) == 1,
                quantity_of(
                  self.mint,
                  peg_in_policy_id,
                  peg_in_token_asset_name,
                ) == -1,
              }
            and {
              is_owner,
              burn_the_nft,
            }
          }
          Prove {
            peg_in_token_asset_name,
            oracle_state_ref_input_index,
            treasury_info_ref_input_index,
          } -> {
            let treasury_info_nft_policy_id =
              builtin.un_b_data(utils.safe_list_at(config, 0))
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

            let treasury_info_ref_input =
              utils.safe_list_at(
                self.reference_inputs,
                treasury_info_ref_input_index,
              )

            let trasury_info =
              utils.get_treasury_info_as_data_list(
                treasury_info_ref_input,
                treasury_info_nft_policy_id,
              )
            let current_treasury_btc_address =
              builtin.un_b_data(utils.safe_list_at(trasury_info, 0))
            let zk_verification =
              zk_verify_peg_in_tx(oracle_state, current_treasury_btc_address)
            let burn_the_nft = and {
                quantity_of(
                  input.output.value,
                  peg_in_policy_id,
                  peg_in_token_asset_name,
                ) == 1,
                quantity_of(
                  self.mint,
                  peg_in_policy_id,
                  peg_in_token_asset_name,
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

fn zk_verify_peg_in_tx(
  _oracle_state: OracleState,
  _current_treasury_btc_address: ByteArray,
) {
  //TODO zk proof of the Bitcoin tx where:
  //1) The tx contains nft.asset_name in the metadata
  //2) Has sent to datum.treasury_btc_address exactly datum.btc_amount_to_mint BTC
  //3) datum.btc_source_address has signed that tx
  True
}
