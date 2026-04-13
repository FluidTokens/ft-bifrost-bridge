use aiken/collection/dict
use aiken/collection/list
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use bifrost/types/treasury.{
  TreasuryDatum, TreasuryMintRedeemer, TreasurySpendRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, flatten, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, OutputReference, Transaction, find_input}

validator treasury_info(registry_policy_id: PolicyId) {
  mint(redeemer: TreasuryMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent =
      option.is_some(find_input(self.inputs, redeemer.input_ref))

    expect [treasury_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    //Minted tokens from this policy id must be only 1 and with quantity 1
    expect [Pair(_this_token_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))

    //AssetName must be correct
    expect [(this_token_policy_id, this_token_asset_name, 1)] =
      flatten(without_lovelace(treasury_output.value))
    let only_minted_token_is_correctly_in_output = and {
        this_token_policy_id == policy_id,
        this_token_asset_name == input_ref_hash,
      }

    //Output must contain proper InlineDatum
    let output_has_correct_datum =
      treasury_output.datum == InlineDatum(
        TreasuryDatum {
          bifrost_identity_root: mpf.root(mpf.empty),
          current_treasury_address: redeemer.current_treasury_address,
          current_treasury_utxo_id: redeemer.current_treasury_utxo_id,
          current_spos_frost_key: redeemer.current_spos_frost_key,
        },
      )

    //Output with the minted token must go to this script
    let output_goes_to_this_script =
      treasury_output.address == Address {
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
    _datum: Option<TreasuryDatum>,
    redeemer: TreasurySpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Pair(own_asset_name, 1) =
      utils.get_singleton_asset_with_policy(own_input.output.value, own_hash)

    let continued_treasury_output =
      utils.find_singleton_asset_output_at_script(
        self.outputs,
        own_hash,
        own_hash,
        own_asset_name,
      )

    let output_has_correct_datum =
      continued_treasury_output.datum == InlineDatum(
        TreasuryDatum {
          bifrost_identity_root: redeemer.new_bifrost_identity_root,
          current_treasury_address: redeemer.new_treasury_address,
          current_treasury_utxo_id: redeemer.new_treasury_utxo_id,
          current_spos_frost_key: redeemer.new_spos_frost_key,
        },
      )

    and {
      utils.quantity_of_policy_id(self.mint, registry_policy_id) != 0,
      own_input.output.value == continued_treasury_output.value,
      own_input.output.address == continued_treasury_output.address,
      output_has_correct_datum,
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}
