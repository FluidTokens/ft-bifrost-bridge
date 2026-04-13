use aiken/merkle_patricia_forestry.{Proof}
use aiken_design_patterns/linked_list

pub type ListRootData {
  ListRootData
}

pub type RegistrationNodeData {
  bifrost_id_pk: ByteArray,
  bifrost_url: ByteArray,
}

pub type BanNodeData {
  ban_counter: Int,
  ban_until_epoch: Int,
}

pub type RegistrationListDatum =
  linked_list.Element<ListRootData, RegistrationNodeData>

pub type BanListDatum =
  linked_list.Element<ListRootData, BanNodeData>

pub type FaultKind {
  InvalidPayload
  Equivocation
}

pub type FaultRecord {
  kind: FaultKind,
  accused_pool_id: ByteArray,
  namespace_hash: ByteArray,
  evidence_hash: ByteArray,
}

pub type SposRegistryMintRedeemer {
  Bootstrap
  Register {
    cold_vkey: ByteArray,
    cold_sig: ByteArray,
    bifrost_sig: ByteArray,
    registration_anchor_input_index: Int,
    registration_anchor_output_index: Int,
    treasury_input_index: Int,
    treasury_output_index: Int,
    bifrost_identity_absence_proof: Proof,
  }
  Deregister {
    cold_vkey: ByteArray,
    cold_sig: ByteArray,
    registration_input_index: Int,
    registration_anchor_input_index: Int,
    registration_anchor_output_index: Int,
    treasury_input_index: Int,
    treasury_output_index: Int,
    bifrost_identity_removal_proof: Proof,
  }
}

pub type SposRegistrySpendRedeemer {
  RegistrationListAction
  BanListAction
  ApplyBan {
    fault_input_index: Int,
    registration_ref_input_index: Int,
    ban_anchor_input_index: Int,
    ban_anchor_output_index: Int,
    current_epoch: Int,
  }
}
