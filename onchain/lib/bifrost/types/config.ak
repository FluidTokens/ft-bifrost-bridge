use cardano/address.{Credential}

pub type ConfigDatum {
  treasury_info_nft_policy_id: ByteArray,
  btc_policy_id: ByteArray,
  btc_oracle_policy_id: ByteArray,
  spo_registration_duration: Int,
  operator_booking_duration: Int,
  operator_bond_amount: Int,
  admin_credential: Credential,
  //Variables used offchain that must be unquestionable
  min_stake: Int,
}
