pub type RegisteredSposDatum {
  registration_time: Int,
  registration_epoch: Int,
  spo_cardano_key: ByteArray,
  spo_btc_key: ByteArray,
  spo_ada_stake: Int,
}

pub type RegisteredSposMintRedeemer {
  Init
  Deinit
  Register {
    key_to_prepend: ByteArray,
    config_ref_input_index: Int,
    prepended_node_output_index: Int,
    anchor_node_output_index: Int,
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
