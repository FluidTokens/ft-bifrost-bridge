use cardano/transaction.{OutputReference}

pub type FaultKind {
  InvalidPayload
  Equivocation
}

pub type FaultProofDatum {
  kind: FaultKind,
  accused_pool_id: ByteArray,
  namespace_hash: ByteArray,
  evidence_hash: ByteArray,
}

pub type FaultProofMintRedeemer {
  // Constructor indices are stable: PublishProof = 0, BurnProof = 1,
  // EquivocationProof = 2 (declared last so the existing 0/1 are unchanged).
  PublishProof {
    input_ref: OutputReference,
    accused_pool_id: ByteArray,
    fault: FaultProofDatum,
  }
  BurnProof
  // Direct equivocation fault (technical_documentation §9.2): two distinct
  // canonical payloads for the same namespace, each BIP-340-signed by the
  // accused's bifrost_id_pk. No ZK — the double-signature is the misbehavior.
  EquivocationProof {
    input_ref: OutputReference,
    // The accused's x-only bifrost identity key both signatures verify under.
    bifrost_id_pk: ByteArray,
    fault: FaultProofDatum,
    // The two conflicting canonical payloads (the signed message preimages;
    // each signature is over sha2_256(payload)).
    payload_a: ByteArray,
    signature_a: ByteArray,
    payload_b: ByteArray,
    signature_b: ByteArray,
  }
}
