use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/option
use bifrost/utils
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/assets.{
  AssetName, PolicyId, flatten, quantity_of, tokens, without_lovelace,
}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, find_input,
}

validator completed_peg_ins_merkle_tree_validator(
  //TODO Circular dependency
  peg_in_withdraw_script_hash: ByteArray,
  //TODO Circular dependency
  peg_out_withdraw_script_hash: ByteArray,
  bridged_token_asset_name: AssetName,
) {
  mint(redeemer: Data, policy_id: PolicyId, self: Transaction) {
    //Minted tokens from this policy id must have only the expected AssetName
    expect [Pair(minted_token_asset_name, minted_tokens_quantity)] =
      dict.to_pairs(tokens(self.mint, policy_id))
    expect minted_token_asset_name == bridged_token_asset_name

    let needed_withdraw_script_hash =
      if minted_tokens_quantity > 0 {
        peg_in_withdraw_script_hash
      } else {
        peg_out_withdraw_script_hash
      }

    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(script_hash), _amnt) ->
            script_hash == needed_withdraw_script_hash
          _ -> False
        }
      },
    )
  }

  else(_ctx: ScriptContext) {
    False
  }
}
