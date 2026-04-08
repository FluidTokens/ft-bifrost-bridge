pub type TreasuryDatum {
  current_treasury_address: ByteArray,
  current_treasury_utxo_id: ByteArray,
  current_spos_frost_key: ByteArray,
}

pub type TreasurySpendRedeemer {
  config_ref_input_index: Int,
  new_treasury_address: ByteArray,
  new_treasury_utxo_id: ByteArray,
  new_spos_frost_key: ByteArray,
}
