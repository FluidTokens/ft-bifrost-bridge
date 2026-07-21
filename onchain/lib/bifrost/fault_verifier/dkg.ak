use aiken/crypto
use aiken/crypto/bitwise.{State}
use aiken/crypto/bls12_381/scalar.{Scalar, from_bytes_little_endian}
use aiken/primitive/bytearray
use bifrost/fault_verifier/common

pub const dkg_round1_tag = "bifrost-dkg-r1"

pub const dkg_round2_tag = "bifrost-dkg-r2"

const dkg_tag_length = 14

const dkg_namespace_length = 66

const dkg_pool_id_offset = 38

const point_length = 33

const signature_length = 64

const scalar_length = 32

const round1_trailer_length = signature_length + common.evidence_hash_length

const round2_entry_length = 165

const round2_entry_recipient_id_offset = common.pool_id_length

const round2_entry_ephemeral_pk_offset = round2_entry_recipient_id_offset + 8

const round2_entry_ciphertext_offset =
  round2_entry_ephemeral_pk_offset + point_length

const round2_entry_pad_commit_offset =
  round2_entry_ciphertext_offset + scalar_length

const round2_entry_evidence_hash_offset =
  round2_entry_pad_commit_offset + common.evidence_hash_length

const secp256k1_scalar_order =
  #"fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"

pub type Round2Entry {
  recipient_pool_id: ByteArray,
  recipient_identifier: ByteArray,
  ephemeral_pk: ByteArray,
  ciphertext: ByteArray,
  pad_commit: ByteArray,
  evidence_hash: ByteArray,
}

fn bytes_at(bytes: ByteArray, offset: Int, length: Int) -> ByteArray {
  bytearray.take(bytearray.drop(bytes, offset), length)
}

pub fn sender_pool_id(payload: ByteArray) -> ByteArray {
  bytes_at(payload, dkg_pool_id_offset, common.pool_id_length)
}

pub fn is_round1_payload(payload: ByteArray, accused_pool_id: ByteArray) -> Bool {
  let payload_length = bytearray.length(payload)
  let commitment_bytes = payload_length - dkg_namespace_length - round1_trailer_length

  and {
    payload_length >= dkg_namespace_length + point_length + round1_trailer_length,
    bytearray.take(payload, dkg_tag_length) == dkg_round1_tag,
    sender_pool_id(payload) == accused_pool_id,
    commitment_bytes % point_length == 0,
  }
}

pub fn is_round2_payload(payload: ByteArray, accused_pool_id: ByteArray) -> Bool {
  let payload_length = bytearray.length(payload)
  let entry_bytes = payload_length - dkg_namespace_length

  and {
    payload_length >= dkg_namespace_length + round2_entry_length,
    bytearray.take(payload, dkg_tag_length) == dkg_round2_tag,
    sender_pool_id(payload) == accused_pool_id,
    entry_bytes % round2_entry_length == 0,
  }
}

pub fn round1_evidence_hash(payload: ByteArray) -> ByteArray {
  bytes_at(
    payload,
    bytearray.length(payload) - common.evidence_hash_length,
    common.evidence_hash_length,
  )
}

pub fn selected_round2_entry(payload: ByteArray, index: Int) -> Round2Entry {
  expect index >= 0
  let offset = dkg_namespace_length + index * round2_entry_length
  expect bytearray.length(payload) >= offset + round2_entry_length
  Round2Entry {
    recipient_pool_id: bytes_at(payload, offset, common.pool_id_length),
    recipient_identifier: bytes_at(
      payload,
      offset + round2_entry_recipient_id_offset,
      8,
    ),
    ephemeral_pk: bytes_at(
      payload,
      offset + round2_entry_ephemeral_pk_offset,
      point_length,
    ),
    ciphertext: bytes_at(
      payload,
      offset + round2_entry_ciphertext_offset,
      scalar_length,
    ),
    pad_commit: bytes_at(
      payload,
      offset + round2_entry_pad_commit_offset,
      common.evidence_hash_length,
    ),
    evidence_hash: bytes_at(
      payload,
      offset + round2_entry_evidence_hash_offset,
      common.evidence_hash_length,
    ),
  }
}

pub fn public_inputs_match(
  raw: List<ByteArray>,
  evidence_hash: ByteArray,
  accused_pool_id: ByteArray,
) -> Bool {
  when raw is {
    [public_evidence_hash, public_pool_id] -> and {
        public_evidence_hash == evidence_hash,
        public_pool_id == accused_pool_id,
        common.is_evidence_hash(public_evidence_hash),
        common.is_pool_id(public_pool_id),
      }
    _ -> False
  }
}

pub fn halo2_public_inputs(
  evidence_hash: ByteArray,
  accused_pool_id: ByteArray,
) -> List<State<Scalar>> {
  [
    from_bytes_little_endian(evidence_hash),
    from_bytes_little_endian(accused_pool_id),
  ]
}

pub fn opened_share_matches(
  entry: Round2Entry,
  pad: ByteArray,
  opened_share: ByteArray,
) -> Bool {
  and {
    bytearray.length(pad) == scalar_length,
    bytearray.length(opened_share) == scalar_length,
    crypto.blake2b_256(pad) == entry.pad_commit,
    bytearray.xor_bytes(entry.ciphertext, pad, False) == opened_share,
    is_secp256k1_scalar(opened_share),
  }
}

fn is_secp256k1_scalar(bytes: ByteArray) -> Bool {
  and {
    bytearray.length(bytes) == scalar_length,
    bytearray.compare(bytes, secp256k1_scalar_order) == Less,
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_pool_id: ByteArray =
  #"01010101010101010101010101010101010101010101010101010101"

const t_evidence_hash: ByteArray =
  #"0202020202020202020202020202020202020202020202020202020202020202"

fn t_round1_payload() -> ByteArray {
  dkg_round1_tag
    |> bytearray.concat(#"0000000000000001")
    |> bytearray.concat(#"0000000000000033")
    |> bytearray.concat(#"0000000000000000")
    |> bytearray.concat(t_pool_id)
    |> bytearray.concat(
        #"031111111111111111111111111111111111111111111111111111111111111111",
      )
    |> bytearray.concat(
        #"12121212121212121212121212121212121212121212121212121212121212121313131313131313131313131313131313131313131313131313131313131313",
      )
    |> bytearray.concat(t_evidence_hash)
}

test round1_evidence_hash_is_final_32_bytes() {
  let payload = t_round1_payload()
  and {
    is_round1_payload(payload, t_pool_id),
    round1_evidence_hash(payload) == t_evidence_hash,
  }
}

test public_inputs_match_requires_exact_order_and_count() {
  public_inputs_match([t_evidence_hash, t_pool_id], t_evidence_hash, t_pool_id)
}

test xor_bytes_roundtrip() {
  let pad = #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  let opened_share = #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
  let ciphertext = bytearray.xor_bytes(opened_share, pad, False)
  bytearray.xor_bytes(ciphertext, pad, False) == opened_share
}

test opened_share_is_canonical_secp_scalar() {
  is_secp256k1_scalar(
    #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
  )
}

test opened_share_matches_ciphertext_xor_pad() {
  let pad = #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  let opened_share = #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
  let ciphertext = bytearray.xor_bytes(opened_share, pad, False)
  let entry = Round2Entry {
    recipient_pool_id: t_pool_id,
    recipient_identifier: #"0000000000000002",
    ephemeral_pk: #"022222222222222222222222222222222222222222222222222222222222222222",
    ciphertext,
    pad_commit: crypto.blake2b_256(pad),
    evidence_hash: t_evidence_hash,
  }
  opened_share_matches(entry, pad, opened_share)
}
