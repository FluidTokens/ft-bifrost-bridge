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

/// FIELD POSITIONS ARE A CONTRACT. heimdall's redeemer encoders build these
/// constructors positionally from Rust, with no schema in between, so moving a
/// field here silently changes what an off-chain builder means. `nonce_input_index`
/// therefore goes directly after the last signature of its branch — after
/// `bifrost_sig` in `Register`, after `cold_sig` in `Deregister` — where it sits
/// next to the signatures it makes single-use, and every index that follows keeps
/// the position it had in rev 5.5.
///
/// Constructor tags are append-only for the same reason: `Migrate` is tag 3,
/// after the three rev-5.5 branches.
pub type SposRegistryMintRedeemer {
  Bootstrap
  Register {
    cold_vkey: ByteArray,
    cold_sig: ByteArray,
    bifrost_sig: ByteArray,
    //spec [REG-10]: the input whose outpoint ends both signed messages. The
    //transaction spends it, an outpoint is spendable once, so the signatures
    //authorize this transaction and no other.
    nonce_input_index: Int,
    registration_anchor_input_index: Int,
    registration_anchor_output_index: Int,
    treasury_input_index: Int,
    treasury_output_index: Int,
    bifrost_identity_absence_proof: Proof,
  }
  Deregister {
    cold_vkey: ByteArray,
    cold_sig: ByteArray,
    //spec [DRG-6]: [REG-10] unchanged. Without it a revocation signature,
    //public from its first use, authorizes the exit of every later
    //registration of the same pool.
    nonce_input_index: Int,
    registration_input_index: Int,
    registration_anchor_input_index: Int,
    registration_anchor_output_index: Int,
    treasury_input_index: Int,
    treasury_output_index: Int,
    bifrost_identity_removal_proof: Proof,
  }
  //spec [MIG-1] to [MIG-6], §SPO Registration section 8. Carries one
  //registration from the policy Config #13 names to this one, against a
  //membership proof in the identity trie the Treasury state still commits to.
  //No cold signature and no Bifrost signature: the transaction reproduces
  //state the pool already consented to, so anyone may submit it. That is what
  //makes a registry revision cost operators nothing but an upgrade.
  Migrate {
    old_node_ref_input_index: Int,
    config_ref_input_index: Int,
    treasury_ref_input_index: Int,
    registration_anchor_input_index: Int,
    registration_anchor_output_index: Int,
    bifrost_identity_membership_proof: Proof,
  }
}

pub type SposRegistrySpendRedeemer {
  RegistrationListAction
}
