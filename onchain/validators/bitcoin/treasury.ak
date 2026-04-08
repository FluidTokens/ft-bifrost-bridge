use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/option
use bifrost/types/treasury.{TreasuryDatum}
use bifrost/utils
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/assets.{PolicyId, flatten, quantity_of, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, Withdraw, find_input,
}

pub type MintRedeemer {
  input_ref: OutputReference,
  current_treasury_address: ByteArray,
  current_treasury_utxo_id: ByteArray,
  current_spos_frost_key: ByteArray,
}

pub type SpendRedeemer {
  config_ref_input_index: Int,
}

validator treasury_info {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, self: Transaction) {
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent =
      option.is_some(find_input(self.inputs, redeemer.input_ref))

    expect [treasury_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    //Minted tokens from this policy id must be only 1 and with quantity 1
    expect [Pair(this_token_asset_name, 1)] =
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
    _datum: Option<Data>,
    _redeemer: Data,
    _own_ref: OutputReference,
    _self: Transaction,
  ) {
    False
  }

  else(_ctx: ScriptContext) {
    False
  }
}
