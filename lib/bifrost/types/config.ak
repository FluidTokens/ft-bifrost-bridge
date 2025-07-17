use cardano/address.{Credential}

pub type ConfigDatum {
  treasury_movement_nft_policy_id: ByteArray,
  treasury_movement_nft_asset_name: ByteArray,
  btc_policy_id: ByteArray,
  adminCredential: Credential,
}
