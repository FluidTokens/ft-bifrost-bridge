use aiken/crypto
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use bifrost/fault_verifier/common
use bifrost/types/fault_verifier as fault_verifier_types
use bifrost/types/spos_registry.{RegistrationListDatum, RegistrationNodeData}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, placeholder,
}

const dkg_round1_tag = "bifrost-dkg-r1"

const dkg_round2_tag = "bifrost-dkg-r2"

const dkg_tag_length = 14

const dkg_namespace_length = 66

const dkg_pool_id_offset = 38

const round1_trailer_length = 96

const point_length = 33

const poseidon_commit_length = 32

const equivocation_domain = "bifrost-fault-equiv-v1"

fn is_round1_payload(payload: ByteArray) -> Bool {
  let payload_length = bytearray.length(payload)
  let commitment_bytes = payload_length - dkg_namespace_length - round1_trailer_length

  and {
    payload_length >= dkg_namespace_length + point_length + round1_trailer_length,
    bytearray.take(payload, dkg_tag_length) == dkg_round1_tag,
    commitment_bytes % point_length == 0,
  }
}

fn is_round2_payload(payload: ByteArray) -> Bool {
  and {
    bytearray.length(payload) >= dkg_namespace_length + poseidon_commit_length,
    bytearray.take(payload, dkg_tag_length) == dkg_round2_tag,
  }
}

fn dkg_namespace(payload: ByteArray) -> ByteArray {
  bytearray.take(payload, dkg_namespace_length)
}

fn dkg_sender_pool_id(payload: ByteArray) -> ByteArray {
  bytearray.slice(
    payload,
    dkg_pool_id_offset,
    dkg_pool_id_offset + common.pool_id_length - 1,
  )
}

fn has_same_dkg_namespace(
  payload_a: ByteArray,
  payload_b: ByteArray,
  accused_pool_id: ByteArray,
) -> Bool {
  and {
    is_round1_payload(payload_a) || is_round2_payload(payload_a),
    is_round1_payload(payload_b) || is_round2_payload(payload_b),
    dkg_namespace(payload_a) == dkg_namespace(payload_b),
    dkg_sender_pool_id(payload_a) == accused_pool_id,
  }
}

fn length_prefixed(payload: ByteArray) -> ByteArray {
  bytearray.concat(
    bytearray.from_int_big_endian(bytearray.length(payload), 8),
    payload,
  )
}

fn equivocation_hash_preimage(
  payload_a: ByteArray,
  payload_b: ByteArray,
) -> ByteArray {
  when bytearray.compare(payload_a, payload_b) is {
    Greater ->
      bytearray.concat(
        equivocation_domain,
        bytearray.concat(length_prefixed(payload_b), length_prefixed(payload_a)),
      )
    _ ->
      bytearray.concat(
        equivocation_domain,
        bytearray.concat(length_prefixed(payload_a), length_prefixed(payload_b)),
      )
  }
}

fn equivocation_evidence_hash(
  payload_a: ByteArray,
  payload_b: ByteArray,
) -> ByteArray {
  crypto.blake2b_256(equivocation_hash_preimage(payload_a, payload_b))
}

validator fault_verifier_equivocation(registration_script_hash: PolicyId) {
  mint(
    redeemer: fault_verifier_types.FaultProofMintRedeemer<
      fault_verifier_types.EquivocationEvidence,
    >,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    when redeemer is {
      fault_verifier_types.PublishProof { evidence } -> {
        let registration_ref_input = utils.safe_list_at(
          self.reference_inputs,
          evidence.registration_ref_input_index,
        )
        let bifrost_id_pk = common.read_registered_pool_ref(
          registration_ref_input,
          registration_script_hash,
          evidence.accused_pool_id,
        )

        and {
          common.verify_bifrost_signature(
            bifrost_id_pk,
            evidence.payload_a,
            evidence.signature_a,
          ),
          common.verify_bifrost_signature(
            bifrost_id_pk,
            evidence.payload_b,
            evidence.signature_b,
          ),
          has_same_dkg_namespace(
            evidence.payload_a,
            evidence.payload_b,
            evidence.accused_pool_id,
          ),
          evidence.payload_a != evidence.payload_b,
          evidence.evidence_hash == equivocation_evidence_hash(
            evidence.payload_a,
            evidence.payload_b,
          ),
          common.mint_single_fault_token(
            self,
            policy_id,
            evidence.accused_pool_id,
            evidence.evidence_hash,
          ),
        }
      }
      fault_verifier_types.BurnProof ->
        common.burn_single_fault_token(self, policy_id)
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_registration_policy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const t_equivocation_policy: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

const t_pool_id: ByteArray =
  #"01010101010101010101010101010101010101010101010101010101"

const t_bifrost_id_pk: ByteArray =
  #"989c0b76cb563971fdc9bef31ec06c3560f3249d6ee9e5d83c57625596e05f6f"

const t_payload_a: ByteArray =
  #"626966726f73742d646b672d723100000000000000010000000000000033000000000000000001010101010101010101010101010101010101010101010101010101021111111111111111111111111111111111111111111111111111111111111111121212121212121212121212121212121212121212121212121212121212121212121212121212121212121212121212121212121212121212121212121212121313131313131313131313131313131313131313131313131313131313131313"

const t_signature_a: ByteArray =
  #"79f27455e64246af8ffbc25bb5bea4bfe9957102444af5ba8525b2b6e1eb57d0758824e0717c858732d2d18a78bfacf15482a36dd14d0837e0f1e5038a8f546f"

const t_payload_b: ByteArray =
  #"626966726f73742d646b672d723100000000000000010000000000000033000000000000000001010101010101010101010101010101010101010101010101010101022222222222222222222222222222222222222222222222222222222222222222232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232424242424242424242424242424242424242424242424242424242424242424"

const t_signature_b: ByteArray =
  #"c9bd94b304a3fcc741b9c1259856cd079cb2a30af139155253c859819dfc06df23919b7c988f98e3cd333e0d07a6ef491fdb5fd0b152eb5254ac185000bece4f"

const t_payload_c_other_namespace: ByteArray =
  #"626966726f73742d646b672d723100000000000000010000000000000033000000000000000101010101010101010101010101010101010101010101010101010101023333333333333333333333333333333333333333333333333333333333333333343434343434343434343434343434343434343434343434343434343434343434343434343434343434343434343434343434343434343434343434343434343535353535353535353535353535353535353535353535353535353535353535"

const t_signature_c_other_namespace: ByteArray =
  #"9af13537d7d6a34d84ed56f070ad98e0c23ca00470e4e891b5a09ba5f63d315396308e4a205a5e67d553cbb985aa0be5494e8a2a8fa41b75fca9657764c28617"

const t_evidence_hash: ByteArray =
  #"d80be6e612c4afe7842f224d0aedfcaa9d827c9c8e890467e6fbe8955fe8462c"

const t_wrong_evidence_hash: ByteArray =
  #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

fn t_registration_input() -> Input {
  let datum: RegistrationListDatum = linked_list.Element {
    data: linked_list.Node {
      data: RegistrationNodeData {
        bifrost_id_pk: t_bifrost_id_pk,
        bifrost_url: "https://spo.example",
      },
    },
    link: None,
  }

  Input {
    output_reference: OutputReference(
      #"1111111111111111111111111111111111111111111111111111111111111111",
      0,
    ),
    output: Output {
      address: Address {
        payment_credential: Script(t_registration_policy),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_registration_policy, t_pool_id, 1),
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

fn t_evidence(
  payload_a: ByteArray,
  signature_a: ByteArray,
  payload_b: ByteArray,
  signature_b: ByteArray,
  evidence_hash: ByteArray,
) -> fault_verifier_types.EquivocationEvidence {
  fault_verifier_types.EquivocationEvidence {
    registration_ref_input_index: 0,
    accused_pool_id: t_pool_id,
    payload_a,
    signature_a,
    payload_b,
    signature_b,
    evidence_hash,
  }
}

fn t_publish_tx(evidence_hash: ByteArray) -> Transaction {
  Transaction {
    ..placeholder,
    reference_inputs: [t_registration_input()],
    mint: assets.from_asset(
      t_equivocation_policy,
      common.fault_token_name(t_pool_id, evidence_hash),
      1,
    ),
  }
}

fn t_publish(evidence: fault_verifier_types.EquivocationEvidence) -> Bool {
  fault_verifier_equivocation.mint(
    t_registration_policy,
    fault_verifier_types.PublishProof { evidence },
    t_equivocation_policy,
    t_publish_tx(evidence.evidence_hash),
  )
}

test equivocation_publish_accepts_same_namespace_distinct_payloads() {
  t_publish(
    t_evidence(
      t_payload_a,
      t_signature_a,
      t_payload_b,
      t_signature_b,
      t_evidence_hash,
    ),
  )
}

test equivocation_publish_rejects_identical_payloads() fail {
  t_publish(
    t_evidence(
      t_payload_a,
      t_signature_a,
      t_payload_a,
      t_signature_a,
      equivocation_evidence_hash(t_payload_a, t_payload_a),
    ),
  )
}

test equivocation_publish_rejects_cross_namespace_payloads() fail {
  t_publish(
    t_evidence(
      t_payload_a,
      t_signature_a,
      t_payload_c_other_namespace,
      t_signature_c_other_namespace,
      equivocation_evidence_hash(t_payload_a, t_payload_c_other_namespace),
    ),
  )
}

test equivocation_publish_rejects_wrong_evidence_hash() fail {
  t_publish(
    t_evidence(
      t_payload_a,
      t_signature_a,
      t_payload_b,
      t_signature_b,
      t_wrong_evidence_hash,
    ),
  )
}
