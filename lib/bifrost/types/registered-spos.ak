pub type RegisteredSposDatum {
  registration_time: Int,
  spo_cardano_ecdsa_key: ByteArray,
  spo_bitcoin_secp256k1_key: ByteArray,
}

pub type RegisteredSposMintRedeemer {
  Init
  Deinit
  Register {
    key_to_prepend: ByteArray,
    config_ref_input_index: Int,
    prepended_node_output_index: Int,
    anchor_node_output_index: Int,
    spo_bitcoin_secp256k1_key_signature: ByteArray,
  }
  Deregister {
    node_to_deregister_key: ByteArray,
    removed_node_input_index: Int,
    anchor_node_input_index: Int,
  }
}

pub type RegisteredSposSpendRedeemer {
  RegisteredSposSpendRedeemer
}
