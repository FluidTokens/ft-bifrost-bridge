use cardano/address.{Address}
use cardano/transaction.{OutputReference}

pub type PegOutPrivateDatum {
  treasury_btc_address: ByteArray,
  btc_amount_to_burn: Int,
  ada_user_address: Address,
  btc_destination_address: ByteArray,
}

pub type PegOutPrivateMintRedeemer {
  config_ref_input_index: Int,
  input_ref: OutputReference,
  treasury_movement_ref_input_index: Int,
}

pub type PegOutPrivateWithdrawRedeemer {
  config_ref_input_index: Int,
  actions_for_each_input: List<PegOutPrivateAction>,
}

pub type PegOutPrivateAction {
  Cancel { peg_out_private_token_asset_name: ByteArray }
  Prove { peg_out_private_token_asset_name: ByteArray }
}
