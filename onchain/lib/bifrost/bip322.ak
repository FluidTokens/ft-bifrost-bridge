//// BIP-322 "simple" message signing — Taproot (P2TR) key-path sighash.
////
//// A wallet's `signMessage(msg, "bip322-simple")` for a Taproot address produces a
//// BIP-340 Schnorr signature over the BIP-341 key-path sighash of a virtual `to_sign`
//// transaction that spends a virtual `to_spend` transaction committing
//// `tagged_hash("BIP0322-signed", msg)`. This module reconstructs that sighash so the
//// signature verifies on-chain with the same `verify_schnorr_signature` builtin already
//// used for the BIP-340 depositor authorization in `peg-in`.
////
//// Scope: Taproot **key-path**, SIGHASH_DEFAULT (0x00), no annex. The two virtual txs
//// have a fixed shape (1 input, 1 output, all amounts 0), so every serialized field is a
//// constant except `message` and the 32-byte Taproot output key `Q` (the witness
//// program of the depositor's P2TR address, i.e. the bytes after `OP_1 PUSH32`).
////
//// References:
////   BIP-322 — https://github.com/bitcoin/bips/blob/master/bip-0322.mediawiki
////   BIP-341 (taproot sighash) — https://github.com/bitcoin/bips/blob/master/bip-0341.mediawiki
////   BIP-340 (schnorr / tagged_hash) — https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki

use aiken/collection/list
use aiken/crypto
use aiken/primitive/bytearray

// ASCII bytes of the two hash tags.
const bip0322_tag: ByteArray = #"424950303332322d7369676e6564"

// "BIP0322-signed"
const tapsighash_tag: ByteArray = #"54617053696768617368"

// "TapSighash"

// tagged_hash(tag, msg) = SHA256( SHA256(tag) ++ SHA256(tag) ++ msg )  — BIP-340.
fn tagged_hash(tag: ByteArray, msg: ByteArray) -> ByteArray {
  let h = crypto.sha2_256(tag)
  crypto.sha2_256(h |> bytearray.concat(h) |> bytearray.concat(msg))
}

fn concat_all(parts: List<ByteArray>) -> ByteArray {
  list.foldl(parts, #"", fn(p, acc) { bytearray.concat(acc, p) })
}

// SHA256d — Bitcoin txid hash (internal/little-endian byte order).
fn sha256d(b: ByteArray) -> ByteArray {
  crypto.sha2_256(crypto.sha2_256(b))
}

// txid of the BIP-322 `to_spend` virtual tx (legacy serialization, no witness).
// It commits `message_hash` in the scriptSig and the address spk `OP_1 PUSH32 Q` in vout 0.
fn to_spend_txid(message_hash: ByteArray, output_key: ByteArray) -> ByteArray {
  sha256d(
    concat_all(
      [
        #"00000000",
        // nVersion = 0
        #"01",
        // vin count = 1
        #"0000000000000000000000000000000000000000000000000000000000000000",
        // prevout hash
        #"ffffffff",
        // prevout n = 0xFFFFFFFF
        #"22",
        // scriptSig length = 34
        #"0020", message_hash,
        // OP_0 PUSH32 <message_hash>
        #"00000000",
        // nSequence = 0
        #"01",
        // vout count = 1
        #"0000000000000000",
        // value = 0
        #"22", #"5120", output_key,
        // scriptPubKey = OP_1 PUSH32 <Q>
        #"00000000",
      ],
    ),
  )
}

// BIP-341 key-path sighash (SIGHASH_DEFAULT, no annex) of the `to_sign` virtual tx,
// which spends to_spend:0 (value 0, spk = the address) into a single OP_RETURN output.
fn keypath_sighash(spend_txid: ByteArray, output_key: ByteArray) -> ByteArray {
  let sha_prevouts = crypto.sha2_256(concat_all([spend_txid, #"00000000"]))
  let sha_amounts = crypto.sha2_256(#"0000000000000000")
  let sha_scriptpubkeys = crypto.sha2_256(concat_all([#"22", #"5120", output_key]))
  let sha_sequences = crypto.sha2_256(#"00000000")
  let sha_outputs =
    crypto.sha2_256(concat_all([#"0000000000000000", #"01", #"6a"]))
  tagged_hash(
    tapsighash_tag,
    concat_all(
      [
        #"00",
        // sighash epoch
        #"00",
        // hash_type = SIGHASH_DEFAULT
        #"00000000",
        // nVersion
        #"00000000",
        // nLockTime
        sha_prevouts, sha_amounts, sha_scriptpubkeys, sha_sequences, sha_outputs,
        #"00",
        // spend_type (ext_flag=0 key path, annex absent)
        #"00000000",
      ],
    ),
  )
}

/// The 32-byte digest a BIP-322 simple (key-path) signature signs, for `message` and the
/// depositor's Taproot output key `output_key` (the 32-byte witness program of their P2TR
/// address). Pass this to `verify_schnorr_signature` as the message.
pub fn keypath_message_hash(
  message: ByteArray,
  output_key: ByteArray,
) -> ByteArray {
  to_spend_txid(tagged_hash(bip0322_tag, message), output_key)
    |> keypath_sighash(output_key)
}

/// Verify a BIP-322 simple (key-path) signature over `message` for Taproot output key
/// `output_key`. Drop-in replacement for the raw BIP-340 `verify_schnorr_signature` call.
pub fn verify_keypath(
  output_key: ByteArray,
  message: ByteArray,
  signature: ByteArray,
) -> Bool {
  crypto.verify_schnorr_signature(
    output_key,
    keypath_message_hash(message, output_key),
    signature,
  )
}

// ── Cross-check vs. the Python reference (scratchpad/poll … pure-hashlib model) ──────────
// message = "hello" (#"68656c6c6f"), output_key Q = 0x11*32.

test bip322_tagged_hash_empty() {
  tagged_hash(bip0322_tag, #"") == #"888bab9b0d983d5058a18821fa257f99d05105d3fa0a01f162666e905c4cebc1"
}

test bip322_message_hash_hello() {
  tagged_hash(bip0322_tag, #"68656c6c6f") == #"01c50d7013be7867908b15ba83876c4bb9dc8f1cbd28b9c16ebfc2228cd31e31"
}

test bip322_to_spend_txid_sample() {
  to_spend_txid(
    tagged_hash(bip0322_tag, #"68656c6c6f"),
    #"1111111111111111111111111111111111111111111111111111111111111111",
  ) == #"bc7a67c933751585fbc7dd661bc7b8401182bdd1be71df3d0eaf3a62ce3cf6f4"
}

test bip322_keypath_message_hash_sample() {
  keypath_message_hash(
    #"68656c6c6f",
    #"1111111111111111111111111111111111111111111111111111111111111111",
  ) == #"e9a119d942f4da1bfc14a99c941cdb353e45d7c3300045c90eb6e5ccffff9b3d"
}
// ── Ground-truth end-to-end (fill from a real UniSat bip322-simple signature) ────────────
// Sign a known string with a known Taproot address, then assert verify_keypath == True:
//
// test bip322_unisat_vector() {
//   verify_keypath(
//     #"<32-byte taproot output key Q of the signing address>",
//     #"<utf8 hex of the exact signed message string>",
//     #"<64-byte schnorr sig extracted from the bip322-simple witness>",
//   )
// }
