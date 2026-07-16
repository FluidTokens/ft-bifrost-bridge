use aiken/collection/dict
use aiken/collection/list
use bifrost/types/config
use bifrost/types/peg_in.{CompletePegIn, PegInWithdrawRedeemer}
use bifrost/types/peg_out.{CompletePegOut, PegOutWithdrawRedeemer}
use bifrost/utils
use cardano/address.{Script}
use cardano/assets.{PolicyId, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{Transaction, Withdraw}

pub type MintRedeemer {
  config_ref_input_index: Int,
  //Can be either PegIn or PegOut depending if we are minting or burning
  wanted_peg_withdraw_redeemer_index: Int,
}

validator completed_peg_ins_merkle_tree_validator(
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
    let bridged_token_asset_name =
      config.get_bridged_token_asset_name(config_fields)
    let peg_in_withdraw_script_hash =
      config.get_peg_in_withdraw_script_hash(config_fields)
    let peg_out_withdraw_script_hash =
      config.get_peg_out_withdraw_script_hash(config_fields)
    //Minted tokens from this policy id must have only the expected AssetName
    expect [Pair(minted_token_asset_name, minted_tokens_quantity)] =
      dict.to_pairs(tokens(self.mint, policy_id))
    expect minted_token_asset_name == bridged_token_asset_name

    if minted_tokens_quantity > 0 {
      let peg_in_withdraw_redeemer =
        utils.safe_list_at(
          self.redeemers,
          redeemer.wanted_peg_withdraw_redeemer_index,
        )
      expect
        peg_in_withdraw_redeemer.1st == Withdraw(
          Script(peg_in_withdraw_script_hash),
        )
      expect peg_in_redeemer: PegInWithdrawRedeemer =
        peg_in_withdraw_redeemer.2nd

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
    } else {
      let peg_out_withdraw_redeemer =
        utils.safe_list_at(
          self.redeemers,
          redeemer.wanted_peg_withdraw_redeemer_index,
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
  }

  else(_ctx: ScriptContext) {
    False
  }
}
