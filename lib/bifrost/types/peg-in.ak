use cardano/address.{Address}
use cardano/transaction.{OutputReference}

pub type PegInDatum {
  treasury_btc_address: ByteArray,
  btc_amount_to_mint: Int,
  ada_user_address: Address,
  btc_source_address: ByteArray,
}

pub type PegInMintRedeemer {
  config_ref_input_index: Int,
  input_ref: OutputReference,
  treasury_info_ref_input_index: Int,
}

pub type PegInWithdrawRedeemer {
  config_ref_input_index: Int,
  actions_for_each_input: List<PegInAction>,
}

pub type PegInAction {
  Cancel { peg_in_token_asset_name: ByteArray }
  Prove {
    peg_in_token_asset_name: ByteArray,
    oracle_state_ref_input_index: Int,
    treasury_info_ref_input_index: Int,
  }
}
