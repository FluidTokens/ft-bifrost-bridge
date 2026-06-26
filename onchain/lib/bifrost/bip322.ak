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
// NB: the de-facto BIP-322 message tag is "BIP0322-signed-message" — what bip322-js,
// UniSat and other wallets actually use — NOT the "BIP0322-signed" written in the BIP-322
// spec text. Confirmed by verifying a real UniSat signature (see bip322_unisat_vector).
const bip0322_tag: ByteArray = #"424950303332322d7369676e65642d6d657373616765"

// "BIP0322-signed-message"
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

const hex_chars: ByteArray = #"30313233343536373839616263646566"

// "0123456789abcdef"

/// Lowercase-hex ASCII encoding of `bytes` (n input bytes → 2n ASCII output bytes).
/// Lets a binary binding digest be carried in a wallet's text `signMessage` call.
pub fn hex_lower(bytes: ByteArray) -> ByteArray {
  bytearray.foldl(
    bytes,
    #"",
    fn(byte, acc) {
      acc
        |> bytearray.concat(bytearray.push(#"", bytearray.at(hex_chars, byte / 16)))
        |> bytearray.concat(bytearray.push(#"", bytearray.at(hex_chars, byte % 16)))
    },
  )
}

// ── Cross-check vs. a pure-hashlib reference (tag "BIP0322-signed-message") ───────────────
// message = "hello" (#"68656c6c6f"), output_key Q = 0x11*32.

test bip322_hex_lower() {
  hex_lower(#"00ff1a") == #"303066663161" && hex_lower(#"") == #""
}

test bip322_tagged_hash_empty() {
  tagged_hash(bip0322_tag, #"") == #"c90c269c4f8fcbe6880f72a721ddfbf1914268a794cbb21cfafee13770ae19f1"
}

test bip322_message_hash_hello() {
  tagged_hash(bip0322_tag, #"68656c6c6f") == #"528e990bccf82644773d67eff12fb504e84b42c8396475da8c939404f4a32385"
}

test bip322_to_spend_txid_sample() {
  to_spend_txid(
    tagged_hash(bip0322_tag, #"68656c6c6f"),
    #"1111111111111111111111111111111111111111111111111111111111111111",
  ) == #"dca379b8992e984a7671d2a44fd92c4f73c8240cfb5756ac715c0067fdf155ee"
}

test bip322_keypath_message_hash_sample() {
  keypath_message_hash(
    #"68656c6c6f",
    #"1111111111111111111111111111111111111111111111111111111111111111",
  ) == #"b31652fca4ab51235384ade30e3cfe3b5bee8364eced7251aa5d8fccd38aaea0"
}
// ── Ground-truth end-to-end: a real UniSat `signMessage("hello","bip322-simple")` ────────
// addr = tb1pndljy8st8rdhvvafgt28qn8nh6jnuyvuhq4uxtp6sds55vmlp5eql7edl6
//   → output key Q = 9b7f221e…337f0d32 ; message "hello" = #"68656c6c6f"
//   → witness 0140<64B>, sig = the 64-byte key-path schnorr signature (SIGHASH_DEFAULT).
// This passing proves the on-chain sighash matches UniSat's BIP-322 implementation.
test bip322_unisat_vector() {
  verify_keypath(
    #"9b7f221e0b38db7633a942d4704cf3bea53e119cb82bc32c3a83614a337f0d32",
    #"68656c6c6f",
    #"c3b2f35164f020cc3ac5d173c1fe86ccee121b2189af705a7a075cc8f1069200d2876939d577f0bac632451155a903c406c31f23a509ee060ffdcb407d6c49fd",
  )
}
