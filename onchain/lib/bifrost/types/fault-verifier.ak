use cardano/transaction.{OutputReference}

pub type FaultKind {
  InvalidPayload
  Equivocation
}

pub type FaultProofDatum {
  kind: FaultKind,
  namespace_hash: ByteArray,
  evidence_hash: ByteArray,
}

pub type FaultProofMintRedeemer {
  PublishProof {
    input_ref: OutputReference,
    accused_pool_id: ByteArray,
    fault: FaultProofDatum,
  }
  BurnProof
}
