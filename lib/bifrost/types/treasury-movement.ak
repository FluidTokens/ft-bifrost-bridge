pub type TreasuryMovementDatum {
  current_treasury_btc_address: ByteArray,
  current_treasury_btc_utxo_id: ByteArray,
}

pub type TreasuryMovementSpendRedeemer {
  new_treasury_btc_address: ByteArray,
  new_treasury_btc_utxo_id: ByteArray,
}
