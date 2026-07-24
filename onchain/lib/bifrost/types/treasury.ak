use cardano/transaction.{OutputReference}

pub type TreasuryDatum {
  bifrost_identity_root: ByteArray,
  current_treasury_address: ByteArray,
  current_treasury_utxo_id: ByteArray,
  current_spos_frost_key: ByteArray,
}

pub type TreasuryMintRedeemer {
  input_ref: OutputReference,
  current_treasury_address: ByteArray,
  current_treasury_utxo_id: ByteArray,
  current_spos_frost_key: ByteArray,
}

pub type TreasurySpendRedeemer {
  // Registry-coupled update (Register / Deregister): only bifrost_identity_root
  // may change, gated on a registry-policy mint in the same transaction. Every
  // other datum field — including current_spos_frost_key — is preserved by
  // treasury.ak itself, so key rotation is no longer possible on this path
  // (it moved to the UpdateY branch below). This resolves the prior contradiction
  // where the key was writable here yet pinned by spos-registry.ak.
  RegistryUpdate { new_bifrost_identity_root: ByteArray }
  // Update-Y (DKG key rotation): only current_spos_frost_key changes, authorized
  // by a BIP340 signature under the OUTGOING (spent) datum's key over
  //   sha2_256("bifrost-update-y" ++ spent_outpoint(36B: txid ++ vout LE)
  //            ++ epoch(8B BE) ++ new_spos_frost_key(32B)).
  // Submission is permissionless: the signature is the authorization and the
  // message commits to the spent outpoint (replay-proof).
  UpdateY { new_spos_frost_key: ByteArray, epoch: Int, signature: ByteArray }
}
