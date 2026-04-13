use aiken/merkle_patricia_forestry.{Proof}
use aiken_design_patterns/linked_list

pub type ListRootData {
  ListRootData
}

pub type RegistrationNodeData {
  bifrost_id_pk: ByteArray,
  bifrost_url: ByteArray,
}

pub type RegistrationListDatum =
  linked_list.Element<ListRootData, RegistrationNodeData>

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
}
