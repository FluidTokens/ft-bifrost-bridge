use cardano/transaction.{OutputReference}

// Treasury state datum (normative — technical_documentation.md §Treasury state
// UTxO). The two vestigial pointer fields (current_treasury_address /
// current_treasury_utxo_id) were retired in N10b — the TM chain is the pointer —
// and replaced by the federation fields that complete address derivation:
//   #0 bifrost_identity_root  — MPF root of active bifrost_id_pk -> pool_id
//   #1 current_spos_frost_key — Y_51 after the first DKG; Y_federation until then
//   #2 y_federation           — the federation fallback key (script-leaf key)
//   #3 federation_csv_blocks  — the timeout_federation CSV baked into the leaves
//   #4 last_reset_tm_txid     — btc_txid of the federation-sweep TM that last
//                               authorized a FederationReset (empty at bootstrap);
//                               the anti-replay anchor that makes reset fresh.
pub type TreasuryDatum {
  bifrost_identity_root: ByteArray,
  current_spos_frost_key: ByteArray,
  y_federation: ByteArray,
  federation_csv_blocks: Int,
  last_reset_tm_txid: ByteArray,
}

pub type TreasuryMintRedeemer {
  input_ref: OutputReference,
  current_spos_frost_key: ByteArray,
  y_federation: ByteArray,
  federation_csv_blocks: Int,
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
  // Federation reset (emergency, dead-roster recovery): sets current_spos_frost_key
  // ONLY to the datum's own y_federation, gated on (a) a BIP340 signature under
  // y_federation over sha2_256("bifrost-update-y-reset" ++ spent_outpoint(36B) ++
  // epoch(8B BE) ++ y_federation(32B)), and (b) a Confirmed TM (referenced at
  // tm_ref_input_index, authenticated by the TM NFT) whose spent_via_federation_leaf
  // flag is set — Binocular's objective proof the treasury tip was swept via the
  // federation CSV leaf (roster provably dead). The referenced TM's btc_txid must
  // differ from last_reset_tm_txid and is written into it (anti-replay: a stale
  // sweep can't reset a roster that already recovered).
  FederationReset { tm_ref_input_index: Int, epoch: Int, signature: ByteArray }
}
