use cardano/transaction.{OutputReference}

pub type PegInDatum {
  treasury_btc_address: ByteArray,
}

pub type PegInMintRedeemer {
  config_ref_input_index: Int,
  input_ref: OutputReference,
}

pub type PegInWithdrawRedeemer {
  config_ref_input_index: Int,
  actions_for_each_input: List<PegInAction>,
}

pub type PegInAction {
  Cancel
  Prove
}
