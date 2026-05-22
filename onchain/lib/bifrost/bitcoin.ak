// Bitcoin transaction and block utilities

use aiken/collection/list
use aiken/crypto.{sha2_256}
use aiken/primitive/bytearray

// ── Block header ──────────────────────────────────────────────────────────────

// Extract the 32-byte Merkle root from a Bitcoin block header.
// Layout: [0..3] version, [4..35] prev_hash, [36..67] merkle_root, ...
pub fn block_merkle_root(header: ByteArray) -> ByteArray {
  bytearray.take(bytearray.drop(header, 36), 32)
}

// ── TX Merkle proof ───────────────────────────────────────────────────────────

// Verify a Bitcoin transaction's inclusion in a block via a Merkle proof.
// All hashes must be in internal (little-endian) byte order.
pub fn verify_tx_merkle_proof(
  tx_hash: ByteArray,
  tx_index: Int,
  proof: List<ByteArray>,
  expected_root: ByteArray,
) -> Bool {
  let (computed_root, _) =
    list.foldl(
      proof,
      (tx_hash, tx_index),
      fn(sibling, acc) {
        let (current, idx) = acc
        let combined =
          if idx % 2 == 0 {
            bytearray.concat(current, sibling)
          } else {
            bytearray.concat(sibling, current)
          }
        (sha2_256(sha2_256(combined)), idx / 2)
      },
    )
  computed_root == expected_root
}

// ── Raw transaction parsing ───────────────────────────────────────────────────
// Parses a raw Bitcoin transaction in non-witness (legacy) serialization.
// For segwit transactions, strip the witness data before passing raw_btc_tx.

// Read a Bitcoin varint at the given offset. Returns (value, bytes_consumed).
fn read_varint(bytes: ByteArray, offset: Int) -> (Int, Int) {
  let first = bytearray.at(bytes, offset)
  if first < 0xfd {
    (first, 1)
  } else if first == 0xfd {
    let lo = bytearray.at(bytes, offset + 1)
    let hi = bytearray.at(bytes, offset + 2)
    (lo + hi * 256, 3)
  } else if first == 0xfe {
    let b0 = bytearray.at(bytes, offset + 1)
    let b1 = bytearray.at(bytes, offset + 2)
    let b2 = bytearray.at(bytes, offset + 3)
    let b3 = bytearray.at(bytes, offset + 4)
    (b0 + b1 * 256 + b2 * 65536 + b3 * 16777216, 5)
  } else {
    fail @"8-byte varint not supported"
  }
}

// Skip one Bitcoin input (prev_txid + prev_vout + script + sequence).
fn skip_input(bytes: ByteArray, offset: Int) -> Int {
  let after_outpoint = offset + 36
  let (script_len, varint_size) = read_varint(bytes, after_outpoint)
  after_outpoint + varint_size + script_len + 4
}

// Skip n Bitcoin inputs, returns new offset.
fn skip_inputs(bytes: ByteArray, offset: Int, count: Int) -> Int {
  if count == 0 {
    offset
  } else {
    skip_inputs(bytes, skip_input(bytes, offset), count - 1)
  }
}

// Skip one Bitcoin output (value + scriptpubkey).
fn skip_output(bytes: ByteArray, offset: Int) -> Int {
  let after_value = offset + 8
  let (script_len, varint_size) = read_varint(bytes, after_value)
  after_value + varint_size + script_len
}

// Navigate to vout_index and return its satoshi value (8-byte little-endian).
fn read_output_value(bytes: ByteArray, offset: Int, remaining: Int) -> Int {
  if remaining == 0 {
    let b0 = bytearray.at(bytes, offset)
    let b1 = bytearray.at(bytes, offset + 1)
    let b2 = bytearray.at(bytes, offset + 2)
    let b3 = bytearray.at(bytes, offset + 3)
    let b4 = bytearray.at(bytes, offset + 4)
    let b5 = bytearray.at(bytes, offset + 5)
    let b6 = bytearray.at(bytes, offset + 6)
    let b7 = bytearray.at(bytes, offset + 7)
    b0 + b1 * 256 + b2 * 65536 + b3 * 16777216 + b4 * 4294967296 + b5 * 1099511627776 + b6 * 281474976710656 + b7 * 72057594037927936
  } else {
    read_output_value(bytes, skip_output(bytes, offset), remaining - 1)
  }
}

// Navigate to vout_index and return its scriptpubkey bytes.
fn read_output_scriptpubkey(
  bytes: ByteArray,
  offset: Int,
  remaining: Int,
) -> ByteArray {
  if remaining == 0 {
    // offset = start of this vout; skip 8-byte value to reach scriptpubkey
    let spk_varint_offset = offset + 8
    let (script_len, varint_size) = read_varint(bytes, spk_varint_offset)
    bytearray.take(
      bytearray.drop(bytes, spk_varint_offset + varint_size),
      script_len,
    )
  } else {
    read_output_scriptpubkey(bytes, skip_output(bytes, offset), remaining - 1)
  }
}

// Shared navigation to the start of the vout section.
fn vout_section_offset(raw_tx: ByteArray) -> Int {
  let offset = 4
  let (vin_count, vin_varint_size) = read_varint(raw_tx, offset)
  let offset = offset + vin_varint_size
  let offset = skip_inputs(raw_tx, offset, vin_count)
  let (_, vout_varint_size) = read_varint(raw_tx, offset)
  offset + vout_varint_size
}

// Parse the satoshi value of a specific output. raw_tx must be non-witness form.
pub fn get_vout_satoshis(raw_tx: ByteArray, vout_index: Int) -> Int {
  read_output_value(raw_tx, vout_section_offset(raw_tx), vout_index)
}

// Return the scriptpubkey of a specific output.
pub fn get_vout_scriptpubkey(raw_tx: ByteArray, vout_index: Int) -> ByteArray {
  read_output_scriptpubkey(raw_tx, vout_section_offset(raw_tx), vout_index)
}

// ── Witness stripping (segwit → legacy / txid serialization) ────────────────────
// A txid is sha256d over the LEGACY (non-witness) serialization. A segwit tx
// carries a marker (0x00) + flag (0x01) after the version and a per-input witness
// section before the locktime; double-hashing those bytes yields the wtxid, not
// the txid. To recover the txid (e.g. to verify Merkle inclusion against a block
// header's tx-merkle-root), strip the witness data on-chain rather than trusting a
// pre-stripped copy — stripping is deterministic, so the result is as trustworthy
// as the input bytes themselves.

// Skip n Bitcoin outputs starting at `offset` (the first output), returns new offset.
fn skip_outputs(bytes: ByteArray, offset: Int, count: Int) -> Int {
  if count == 0 {
    offset
  } else {
    skip_outputs(bytes, skip_output(bytes, offset), count - 1)
  }
}

// True iff `raw_tx` is segwit-serialized: marker byte 0x00 then flag byte 0x01
// immediately after the 4-byte version (BIP144).
pub fn is_witness_tx(raw_tx: ByteArray) -> Bool {
  bytearray.at(raw_tx, 4) == 0x00 && bytearray.at(raw_tx, 5) == 0x01
}

// Return the legacy (non-witness) serialization of `raw_tx`, i.e. the bytes whose
// sha256d is the txid. Layout of a segwit tx:
//   [version 4][marker 1][flag 1][txins][txouts][witness][locktime 4]
// Drop marker+flag and the witness section, keep version ++ txins ++ txouts ++
// locktime. The witness section has a variable per-input layout, so it is not
// parsed — locktime is taken as the final 4 bytes. A non-segwit tx is returned
// unchanged.
pub fn strip_witness_data(raw_tx: ByteArray) -> ByteArray {
  if is_witness_tx(raw_tx) {
    let version = bytearray.take(raw_tx, 4)
    // txins + txouts begin at offset 6 (after version + marker + flag).
    let (vin_count, vin_varint_size) = read_varint(raw_tx, 6)
    let after_inputs = skip_inputs(raw_tx, 6 + vin_varint_size, vin_count)
    let (vout_count, vout_varint_size) = read_varint(raw_tx, after_inputs)
    let after_outputs =
      skip_outputs(raw_tx, after_inputs + vout_varint_size, vout_count)
    // body = the txins+txouts section, bytes [6, after_outputs).
    let body = bytearray.take(bytearray.drop(raw_tx, 6), after_outputs - 6)
    let locktime =
      bytearray.take(bytearray.drop(raw_tx, bytearray.length(raw_tx) - 4), 4)
    version
      |> bytearray.concat(body)
      |> bytearray.concat(locktime)
  } else {
    raw_tx
  }
}

// A minimal segwit tx (1 input, 1 output, a 1-byte witness item) and its legacy
// (witness-stripped) serialization. sha256d(stripped) is the txid; sha256d(full)
// is the wtxid. Verified out-of-band:
//   txid  = 90be577bb560e587a013c68901ba7ba2cab8a183195c5d47342a3eb9d2e27bc9
//   wtxid = bf95a4d2da4b21c271a0b5da0b474b81cb9ad3462de1e7859d0cb5080a1d4e81
test strip_witness_data_segwit() {
  let full =
    #"0200000000010111111111111111111111111111111111111111111111111111111111111111110000000000ffffffff0100f2052a01000000015101010000000000"
  let stripped =
    #"020000000111111111111111111111111111111111111111111111111111111111111111110000000000ffffffff0100f2052a01000000015100000000"
  strip_witness_data(full) == stripped
}

// A legacy (non-segwit) tx must pass through unchanged.
test strip_witness_data_legacy_noop() {
  let legacy =
    #"020000000111111111111111111111111111111111111111111111111111111111111111110000000000ffffffff0100f2052a01000000015100000000"
  strip_witness_data(legacy) == legacy
}

// Parse the 28-byte Cardano PKH from the OP_RETURN output (always vout 1).
// OP_RETURN scriptpubkey format: 6a <len> "BFR" (424652) <28-byte-pkh>
pub fn get_op_return_pkh(raw_tx: ByteArray) -> ByteArray {
  let script = get_vout_scriptpubkey(raw_tx, 1)
  // Validate: byte 0 = 0x6a (OP_RETURN), bytes 2-4 = "BFR"
  expect bytearray.at(script, 0) == 0x6a
  expect bytearray.take(bytearray.drop(script, 2), 3) == #"424652"
  // Skip 5 bytes (0x6a + length + "BFR"), take 28-byte PKH
  bytearray.take(bytearray.drop(script, 5), 28)
}
