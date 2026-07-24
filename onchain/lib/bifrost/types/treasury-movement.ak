// Mirror of binocular's Scalus `TreasuryMovementValidator` datum (the canonical Treasury-Movement
// contract — see internal-docs bitfrost/watchtower/tm-nft-spec.md, Route 1). The TM UTxO lives at
// the binocular `TreasuryMovementValidator` address and carries the TM NFT (policy = that script's
// hash). `peg_in.ak::CompletePegIn` references the Confirmed UTxO and reads these fields, so the
// Constr tags + field order MUST stay identical to the Scalus `TmDatum` enum:
//
//   enum TmDatum { Unconfirmed(signedBtcTx)                                          // Constr 0
//                  Confirmed(btcTxid, sweptPegInUtxoIds, fulfilledPegOuts,
//                            spentViaFederationLeaf) }                                // Constr 1
//   case class PegOutEntry(scriptPubKey, amount)                                     // Constr 0
//
// N10b appended `spent_via_federation_leaf` to Confirmed: at confirm time binocular
// still holds the signed BTC tx (witnesses intact) and reconstructs the leaf
// `<federation_csv_blocks> OP_CSV OP_DROP <y_federation> OP_CHECKSIG`, so it records
// there whether the treasury input was swept via that federation leaf. `treasury.ak`
// FederationReset reads this flag as the objective dead-roster evidence.

// A fulfilled peg-out parsed from a TM output: the raw Bitcoin scriptPubKey + satoshi amount.
pub type PegOutEntry {
  script_pub_key: ByteArray,
  amount: Int,
}

pub type TreasuryMovementDatum {
  // Posted when the signed Bitcoin TM is published to Cardano; carries the full segwit tx bytes.
  Unconfirmed { signed_btc_tx: ByteArray }
  // Produced by binocular `confirm-tmtx` once the TM is Binocular-confirmed: the recomputed txid,
  // the swept peg-in outpoints (each = 36-byte prev_txid(LE) ++ vout), the fulfilled peg-outs, and
  // whether the treasury input was spent via the federation CSV leaf (N10b — the dead-roster
  // evidence consumed by treasury.ak FederationReset). Appended last so existing readers that
  // destructure with `..` stay decode-compatible.
  Confirmed {
    btc_txid: ByteArray,
    swept_peg_in_utxo_ids: List<ByteArray>,
    fulfilled_peg_outs: List<PegOutEntry>,
    spent_via_federation_leaf: Bool,
  }
}
