use aiken/collection/dict
use aiken/collection/list
use bifrost/constants.{btc_asset_name}
use bifrost/types/btc_mint.{BtcMintRedeemer}
use bifrost/types/peg_in.{PegInDatum, PegInWithdrawRedeemer, Prove}
use bifrost/utils
use cardano/address.{Script}
use cardano/assets.{PolicyId, flatten, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}

validator btc_mint_validator(
  peg_in_spend_script_hash: ByteArray,
  peg_in_policy_id: ByteArray,
) {
  //We exclude the burnt tokens (quantity < 0) as they are always allowed
  //Only 1 AssetName can be minted
  mint(redeemer: BtcMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let minted_tokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(tokenPair) { tokenPair.2nd > 0 },
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

    let peg_in_prove_inputs =
      list.indexed_foldr(
        peg_in_inputs,
        [],
        fn(index, input, result) {
          let peg_in_withdraw_redeemer =
            utils.safe_list_at(
              self.redeemers,
              redeemer.peg_in_withdraw_redeemer_index,
            )
          expect
            peg_in_withdraw_redeemer.1st == Withdraw(Script(peg_in_policy_id))
          expect peg_in_redeemer: PegInWithdrawRedeemer =
            peg_in_withdraw_redeemer.2nd
          let peg_in_redeemer_action =
            utils.safe_list_at(peg_in_redeemer.actions_for_each_input, index)

          when peg_in_redeemer_action is {
            Prove { .. } -> list.push(result, input)
            _ -> result
          }
        },
      )

    let btc_outputs =
      list.filter(
        self.outputs,
        fn(output) { quantity_of(output.value, policy_id, btc_asset_name) > 0 },
      )

    if list.length(minted_tokens) > 0 {
      let only_btc_minted = list.length(flatten(self.mint)) == 1
      let total_minted_btc = quantity_of(self.mint, policy_id, btc_asset_name)

      let total_btc_in_output =
        list.indexed_foldr(
          peg_in_prove_inputs,
          0,
          fn(index, input, total_btc_in_output) {
            expect InlineDatum(inputDatum) = input.output.datum
            expect datum: PegInDatum = inputDatum

            let corresponding_output = utils.safe_list_at(btc_outputs, index)

            expect and {
                corresponding_output.address == datum.ada_user_address,
                quantity_of(
                  corresponding_output.value,
                  policy_id,
                  btc_asset_name,
                ) == datum.btc_amount_to_mint,
              }

            total_btc_in_output + datum.btc_amount_to_mint
          },
        )

      and {
        only_btc_minted,
        total_btc_in_output == total_minted_btc,
      }
    } else {
      True
    }
  }

  else(_) {
    fail
  }
}
