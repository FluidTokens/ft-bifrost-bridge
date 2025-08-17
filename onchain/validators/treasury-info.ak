use aiken/builtin
use bifrost/constants
use bifrost/types/bitcoin_oracle.{OracleState}
use bifrost/types/treasury_info.{TreasuryInfoDatum, TreasuryInfoSpendRedeemer}
use bifrost/utils.{quantity_of_policy_id}
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, Transaction, find_input,
}

//Contains all SC params
validator treasury_info_validator(
  tx0: ByteArray,
  index0: Int,
  config_policy_id: ByteArray,
  config_asset_name: ByteArray,
) {
  mint(_redeemer: Redeemer, policy_id: PolicyId, self: Transaction) {
    let contract_credential = Script(policy_id)

    let one_time_utxo = OutputReference(tx0, index0)
    //we won't use input_present, we just need it to be there, otherwise error
    expect Some(_input_present) = find_input(self.inputs, one_time_utxo)
    let output_treasury_info = utils.safe_list_at(self.outputs, 0)

    and {
      //First output goes to this address
      output_treasury_info.address.payment_credential == contract_credential,
      //Only 1 token of same policy
      quantity_of_policy_id(self.mint, policy_id) == 1,
      //I am minting only 1 token (NFT)
      quantity_of(self.mint, policy_id, constants.treasury_info_nft_asset_name) == 1,
      //NFT goes to the output
      quantity_of(
        output_treasury_info.value,
        policy_id,
        constants.treasury_info_nft_asset_name,
      ) == 1,
    }
  }

  spend(
    datumOpt: Option<TreasuryInfoDatum>,
    redeemer: TreasuryInfoSpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(datum) = datumOpt
    let config =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        config_policy_id,
        config_asset_name,
      )
    let btc_oracle_policy_id = builtin.un_b_data(utils.safe_list_at(config, 2))
    expect Some(input_contract) = find_input(self.inputs, own_ref)
    let output_contract = utils.safe_list_at(self.outputs, 0)
    expect InlineDatum(output_datum) = output_contract.datum
    //value can be anything but the type must be of correct type
    expect _casted_datum: TreasuryInfoDatum = output_datum

    expect Script(contract_script_hash) =
      input_contract.output.address.payment_credential
    let expected_datum =
      TreasuryInfoDatum {
        current_treasury_btc_address: redeemer.new_treasury_btc_address,
        current_treasury_btc_utxo_id: redeemer.new_treasury_btc_utxo_id,
      }

    let oracle_state_ref_input =
      utils.safe_list_at(
        self.reference_inputs,
        redeemer.oracle_state_ref_input_index,
      )

    let oracle_state =
      utils.get_oracle_state(oracle_state_ref_input, btc_oracle_policy_id)

    let zk_verification =
      zk_verify_treasury_info(
        oracle_state,
        datum.current_treasury_btc_utxo_id,
        redeemer.new_treasury_btc_address,
        redeemer.new_treasury_btc_utxo_id,
      )
    and {
      input_contract.output.value == output_contract.value,
      input_contract.output.address == output_contract.address,
      quantity_of(
        input_contract.output.value,
        contract_script_hash,
        constants.treasury_info_nft_asset_name,
      ) == 1,
      zk_verification,
      builtin.equals_data(datum, expected_datum),
    }
  }

  else(_) {
    fail
  }
}

fn zk_verify_treasury_info(
  _oracle_state: OracleState,
  _current_treasury_btc_utxo_id: ByteArray,
  _new_treasury_btc_address: ByteArray,
  _new_treasury_btc_utxo_id: ByteArray,
) {
  //TODO zk proof of the treasury movement tx where:
  //1) The tx spends current_treasury_btc_utxo_id
  //2) The tx.outputs[0].utxo_id == new_treasury_btc_utxo_id
  //3) The tx.outputs[0].address == new_treasury_btc_address
  True
}
