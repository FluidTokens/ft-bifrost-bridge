pub type FaultProofMintRedeemer<evidence> {
  PublishProof { evidence: evidence }
  BurnProof
}

pub type Round1InvalidPayloadEvidence {
  registration_ref_input_index: Int,
  accused_pool_id: ByteArray,
  canonical_round1_bytes: ByteArray,
  payload_signature: ByteArray,
  halo2_proof: ByteArray,
  halo2_public_inputs: List<ByteArray>,
}

pub type Round2InvalidPayloadEvidence {
  registration_ref_input_index: Int,
  accused_pool_id: ByteArray,
  canonical_round1_bytes: ByteArray,
  round1_signature: ByteArray,
  canonical_round2_bytes: ByteArray,
  round2_signature: ByteArray,
  round2_entry_index: Int,
  pad: ByteArray,
  opened_share: ByteArray,
  halo2_proof: ByteArray,
  halo2_public_inputs: List<ByteArray>,
}

pub type EquivocationEvidence {
  registration_ref_input_index: Int,
  accused_pool_id: ByteArray,
  payload_a: ByteArray,
  signature_a: ByteArray,
  payload_b: ByteArray,
  signature_b: ByteArray,
  evidence_hash: ByteArray,
}
