use aiken_design_patterns/linked_list
use cardano/transaction.{OutputReference}

pub type BanListRootData {
  BanListRootData
}

pub type BanNodeData {
  ban_counter: Int,
  ban_until_epoch: Int,
}

pub type BanListDatum =
  linked_list.Element<BanListRootData, BanNodeData>

pub type SpoBansMintRedeemer {
  Bootstrap { input_ref: OutputReference }
  MintBanNode { withdraw_redeemer_index: Int, pool_id: ByteArray }
}

pub type SpoBansSpendRedeemer {
  BanListAction { withdraw_redeemer_index: Int }
}

pub type SpoBansWithdrawRedeemer {
  ApplyBan {
    fault_input_index: Int,
    registration_ref_input_index: Int,
    ban_anchor_input_index: Int,
    ban_anchor_output_index: Int,
    existing_ban_input_index: Option<Int>,
    ban_node_output_index: Int,
    current_epoch: Int,
  }
}
