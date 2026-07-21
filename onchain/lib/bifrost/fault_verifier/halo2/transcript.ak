use aiken/builtin.{blake2b_256}
use aiken/crypto/bitwise.{State}
use aiken/crypto/bls12_381/scalar.{
  Scalar, add, from_bytes_little_endian, mul_int, to_bytes_little_endian,
}
use aiken/primitive/bytearray

const prefix_challenge = #"00"

const prefix_common = #"01"

pub type Transcript {
  remaining_proof: ByteArray,
  accumulated_for_hash: ByteArray,
}

pub fn construct_transcript(
  proof: Data,
  transcript_repr: State<Scalar>,
) -> Transcript {
  expect bytes: ByteArray = proof
  let transcript = Transcript {
    remaining_proof: bytes,
    accumulated_for_hash: #[],
  }
  common_scalar(transcript_repr, transcript)
}

pub fn read_scalar(transcript: Transcript) -> (State<Scalar>, Transcript) {
  let scalar_bytes = bytearray.take(transcript.remaining_proof, 32)
  let scalar = from_bytes_little_endian(scalar_bytes)

  let remaining_proof_data = bytearray.drop(transcript.remaining_proof, 32)

  let bytes_to_append = bytearray.concat(prefix_common, scalar_bytes)
  let new_bytes_for_hash = bytearray.concat(
    transcript.accumulated_for_hash,
    bytes_to_append,
  )
  (
    scalar,
    Transcript {
      remaining_proof: remaining_proof_data,
      accumulated_for_hash: new_bytes_for_hash,
    },
  )
}

pub fn common_scalar(
  scalar: State<Scalar>,
  transcript: Transcript,
) -> Transcript {
  let scalar_bytes = to_bytes_little_endian(scalar)

  let bytes_to_append = bytearray.concat(prefix_common, scalar_bytes)
  let new_bytes_for_hash = bytearray.concat(
    transcript.accumulated_for_hash,
    bytes_to_append,
  )

  Transcript { ..transcript, accumulated_for_hash: new_bytes_for_hash }
}

pub fn read_point(transcript: Transcript) -> (ByteArray, Transcript) {
  let g1_bytes = bytearray.take(transcript.remaining_proof, 48)
  let remaining_proof_data = bytearray.drop(transcript.remaining_proof, 48)

  let bytes_to_append = bytearray.concat(prefix_common, g1_bytes)
  let new_bytes_for_hash = bytearray.concat(
    transcript.accumulated_for_hash,
    bytes_to_append,
  )

  (
    g1_bytes,
    Transcript {
      remaining_proof: remaining_proof_data,
      accumulated_for_hash: new_bytes_for_hash,
    },
  )
}

pub fn squeeze_challenge(transcript: Transcript) -> (State<Scalar>, Transcript) {
  let data_for_squeeze = bytearray.concat(
    transcript.accumulated_for_hash,
    prefix_challenge,
  )
  let squeeze_hash = blake2b_256(data_for_squeeze)

  // To ensure the challenge is uniformly distributed over the scalars,
  // we generate two hash digests, map them with bias to the scalars,
  // and add them together with the offset R = 2^256 % q where
  // q is scalar field's prime.
  let squeeze_scalar = add(
    from_bytes_little_endian(squeeze_hash),
    mul_int(
      from_bytes_little_endian(blake2b_256(squeeze_hash)),
      0x1824b159acc5056f998c4fefecbc4ff55884b7fa0003480200000001fffffffe,
    ),
  )
  (
    squeeze_scalar,
    Transcript { ..transcript, accumulated_for_hash: data_for_squeeze },
  )
}
