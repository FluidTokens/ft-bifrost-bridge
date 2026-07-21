// Mirror of binocular's Scalus `TreasuryMovementValidator` datum (the canonical Treasury-Movement
// contract — see internal-docs bitfrost/watchtower/tm-nft-spec.md, Route 1). The TM UTxO lives at
// the binocular `TreasuryMovementValidator` address and carries the TM NFT (policy = that script's
// hash). `peg_in.ak::CompletePegIn` references the Confirmed UTxO and reads these fields, so the
// Constr tags + field order MUST stay identical to the Scalus `TmDatum` enum:
//
//   enum TmDatum {
//     Unconfirmed(signedBtcTx, creator, created)                              // Constr 0
//     Confirmed(btcTxid, sweptPegInUtxoIds, fulfilledPegOuts, creator, created) } // Constr 1
//   case class PegOutEntry(scriptPubKey, amount)                              // Constr 0
//
// NOTE: Aiken's `expect` on raw Data validates the constructor's EXACT arity — a shape mismatch
// here makes every CompletePegIn fail at the datum decode, so this mirror must track the Scalus
// type verbatim (creator/created were appended for the grace-period GC of Confirmed records).

// A fulfilled peg-out parsed from a TM output: the raw Bitcoin scriptPubKey + satoshi amount.
pub type PegOutEntry {
  script_pub_key: ByteArray,
  amount: Int,
}

pub type TreasuryMovementDatum {
  // Posted when the signed Bitcoin TM is published to Cardano; carries the full segwit tx bytes
  // plus provenance: the poster's payment key hash and the posting time (POSIX ms, anchored by
  // the TM mint policy to equal the tx's validity upper bound).
  Unconfirmed { signed_btc_tx: ByteArray, creator: ByteArray, created: Int }
  // Produced by binocular `confirm-tmtx` once the TM is Binocular-confirmed: the recomputed txid,
  // the swept peg-in outpoints (each = 36-byte prev_txid(LE) ++ vout), the fulfilled peg-outs,
  // and the creator/created provenance carried verbatim from the Unconfirmed record (the creator
  // may burn the NFT and reclaim the min-ADA after the 30-day grace period).
  Confirmed {
    btc_txid: ByteArray,
    swept_peg_in_utxo_ids: List<ByteArray>,
    fulfilled_peg_outs: List<PegOutEntry>,
    creator: ByteArray,
    created: Int,
  }
}
