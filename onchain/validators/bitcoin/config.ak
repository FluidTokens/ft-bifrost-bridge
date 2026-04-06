use aiken/collection/dict
use aiken/collection/list
use bifrost/authorizer
use bifrost/constants
use bifrost/types/config.{ConfigDatum} as configType
use bifrost/utils.{quantity_of_policy_id}
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, flatten, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, Transaction, find_input,
}

//Contains all SC params
validator config(tx0: ByteArray, index0: Int, config_asset_name: ByteArray) {
  mint(_redeemer: Redeemer, policy_id: PolicyId, self: Transaction) {
    let contract_credential = Script(policy_id)

    let one_time_utxo = OutputReference(tx0, index0)
    //we won't use input_present, we just need it to be there, otherwise error
    expect Some(_input_present) = find_input(self.inputs, one_time_utxo)
    let output_parameters = utils.safe_list_at(self.outputs, 0)

    and {
      //First output goes to this address
      output_parameters.address.payment_credential == contract_credential,
      //Only 1 token of same policy
      quantity_of_policy_id(self.mint, policy_id) == 1,
      //I am minting only 1 token (NFT)
      quantity_of(self.mint, policy_id, config_asset_name) == 1,
      //NFT goes to the output
      quantity_of(output_parameters.value, policy_id, config_asset_name) == 1,
    }
  }

  spend(
    datum_opt: Option<ConfigDatum>,
    _redeemer: Redeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    False
  }

  else(_) {
    fail
  }
}
