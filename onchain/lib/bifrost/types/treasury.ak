pub type TreasuryInfoDatum {
  current_treasury_btc_address: ByteArray,
  current_treasury_btc_utxo_id: ByteArray,
}

pub type TreasuryInfoSpendRedeemer {
  config_ref_input_index: Int,
  oracle_state_ref_input_index: Int,
  new_treasury_btc_address: ByteArray,
  new_treasury_btc_utxo_id: ByteArray,
}
