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
  treasury_info_ref_input_index: Int,
}

pub type PegOutPrivateWithdrawRedeemer {
  config_ref_input_index: Int,
  actions_for_each_input: List<PegOutPrivateAction>,
}

pub type PegOutPrivateAction {
  //Cancel includes getting back the locked fBTC.
  //This is doable only after the Treasury Movement has been registered on Cardano.
  //A ZK proof is required showing that for some reason the peg out didn't happen on Bitcoin
  Cancel {
    peg_out_private_token_asset_name: ByteArray,
    oracle_state_ref_input_index: Int,
    treasury_info_ref_input_index: Int,
  }
  Prove {
    peg_out_private_token_asset_name: ByteArray,
    oracle_state_ref_input_index: Int,
  }
}
