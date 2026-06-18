use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use bifrost/types/fault_verifier as fault_verifier_types
use bifrost/types/spos_registry.{RegistrationListDatum, RegistrationNodeData}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, find_input,
  placeholder,
}

fn is_pool_id(token_name: ByteArray) -> Bool {
  bytearray.length(token_name) == 28
}

fn is_evidence_hash(evidence_hash: ByteArray) -> Bool {
  bytearray.length(evidence_hash) == 32
}

fn is_fault_token_name(token_name: ByteArray) -> Bool {
  bytearray.length(token_name) == 32
}

fn fault_token_name(
  accused_pool_id: ByteArray,
  evidence_hash: ByteArray,
) -> ByteArray {
  crypto.blake2b_256(bytearray.concat(accused_pool_id, evidence_hash))
}

// The canonical DKG payload namespace header, shared by both rounds:
//   TAG(14) ‖ epoch(8 BE) ‖ threshold(8 BE) ‖ attempt(8 BE) ‖ pool_id(28)
// (see heimdall `http::canonical`). Two payloads are in the same namespace iff
// these 66 bytes match; the accused pool id is the 28-byte tail at offset 38.
const namespace_header_length: Int = 66

const pool_id_offset: Int = 38

const pool_id_length: Int = 28

fn namespace_header(payload: ByteArray) -> ByteArray {
  bytearray.take(payload, namespace_header_length)
}

fn payload_pool_id(payload: ByteArray) -> ByteArray {
  bytearray.slice(payload, pool_id_offset, pool_id_offset + pool_id_length - 1)
}

// The Equivocation evidence commitment bound into the token name:
// blake2b_256(min(a,b) ‖ max(a,b)) over the two canonical payloads. Sorting
// makes it order-independent; this MUST match heimdall
// `EquivocationEvidence::evidence_hash` so the off-chain-derived token name and
// the on-chain recomputation agree.
fn equivocation_evidence_hash(a: ByteArray, b: ByteArray) -> ByteArray {
  let combined =
    if bytearray.compare(a, b) == Less {
      bytearray.concat(a, b)
    } else {
      bytearray.concat(b, a)
    }
  crypto.blake2b_256(combined)
}

// The accused pool's registered `bifrost_id_pk`, read from its `spos_registry`
// node supplied as a read-only reference input. Binds the redeemer-supplied key
// to `accused_pool_id` so an equivocation cannot be forged with an attacker's
// own key bearing a victim's pool_id. Mirrors `spo-bans.ak`'s
// `validate_registered_pool_ref` (the node key is the registry NFT asset name).
fn registered_bifrost_id_pk(
  ref_input: Input,
  registration_script_hash: ByteArray,
  pool_id: ByteArray,
) -> ByteArray {
  expect Script(script_hash) = ref_input.output.address.payment_credential
  expect Pair(asset_name, 1) =
    utils.get_singleton_asset_with_policy(
      ref_input.output.value,
      registration_script_hash,
    )
  expect InlineDatum(raw_datum) = ref_input.output.datum
  expect datum: RegistrationListDatum = raw_datum
  expect linked_list.Node { data } = datum.data
  expect script_hash == registration_script_hash
  expect asset_name == pool_id
  data.bifrost_id_pk
}

// Parameterized by the `spos_registry` policy id (script hash) — the registry is
// the only authority on `pool_id → bifrost_id_pk`, so the EquivocationProof
// branch references the accused's registration node to bind the key.
validator fault_verifier(registration_script_hash: ByteArray) {
  mint(
    redeemer: fault_verifier_types.FaultProofMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    when redeemer is {
      fault_verifier_types.PublishProof { input_ref, accused_pool_id, fault } -> {
        let token_name = fault_token_name(accused_pool_id, fault.evidence_hash)

        expect Some(_input_present) = find_input(self.inputs, input_ref)

        // TODO: Verify the submitted InvalidPayload ZK proof before minting.
        // The accompanying ZK fault circuit exposes Poseidon(structured_fields)
        // as its public input, which is NOT yet bound to the SHA256(message
        // _hash) the accused signed — see heimdall technical_questions.md §5a.
        // Equivocation (below) is fully verified; InvalidPayload stays a mock
        // until that binding is settled.
        expect [verifier_output] =
          list.filter(
            self.outputs,
            fn(output) { quantity_of(output.value, policy_id, token_name) == 1 },
          )

        and {
          utils.quantity_of_policy_id(self.mint, policy_id) == 1,
          is_pool_id(accused_pool_id),
          is_evidence_hash(fault.evidence_hash),
          is_fault_token_name(token_name),
          fault.accused_pool_id == accused_pool_id,
          quantity_of(self.mint, policy_id, token_name) == 1,
          verifier_output.datum == InlineDatum(fault),
        }
      }

      // Direct equivocation fault (technical_documentation §9.2). Real check,
      // no ZK: two distinct canonical payloads for the same namespace, each
      // BIP-340-signed by the accused's bifrost_id_pk — and that key is bound to
      // `accused_pool_id` via the accused's spos_registry node (referenced as a
      // read-only input), so it cannot be forged with an attacker's own key.
      fault_verifier_types.EquivocationProof {
        input_ref,
        registration_ref_input_index,
        bifrost_id_pk,
        fault,
        payload_a,
        signature_a,
        payload_b,
        signature_b,
      } -> {
        let token_name = fault_token_name(fault.accused_pool_id, fault.evidence_hash)

        expect Some(_input_present) = find_input(self.inputs, input_ref)

        let registration_ref_input =
          utils.safe_list_at(self.reference_inputs, registration_ref_input_index)

        expect [verifier_output] =
          list.filter(
            self.outputs,
            fn(output) { quantity_of(output.value, policy_id, token_name) == 1 },
          )

        and {
          // Structural shape (as PublishProof).
          utils.quantity_of_policy_id(self.mint, policy_id) == 1,
          is_pool_id(fault.accused_pool_id),
          is_evidence_hash(fault.evidence_hash),
          is_fault_token_name(token_name),
          quantity_of(self.mint, policy_id, token_name) == 1,
          verifier_output.datum == InlineDatum(fault),
          fault.kind == fault_verifier_types.Equivocation,
          // §9.2.1 — the two payloads differ (a real conflict).
          payload_a != payload_b,
          // §9.2.1 — both belong to the same namespace, attributed to the
          // accused pool.
          namespace_header(payload_a) == namespace_header(payload_b),
          payload_pool_id(payload_a) == fault.accused_pool_id,
          // Key binding — bifrost_id_pk must be the key registered for
          // accused_pool_id in spos_registry (the registration node referenced
          // as a read-only input). Closes the forge-with-own-key gap.
          bifrost_id_pk == registered_bifrost_id_pk(
            registration_ref_input,
            registration_script_hash,
            fault.accused_pool_id,
          ),
          // §9.2.2 — both BIP-340 signatures verify under bifrost_id_pk over
          // sha2_256(canonical payload) (the sign-the-hash scheme).
          crypto.verify_schnorr_signature(
            bifrost_id_pk,
            crypto.sha2_256(payload_a),
            signature_a,
          ),
          crypto.verify_schnorr_signature(
            bifrost_id_pk,
            crypto.sha2_256(payload_b),
            signature_b,
          ),
          // Bind the token name to THIS evidence.
          fault.evidence_hash == equivocation_evidence_hash(payload_a, payload_b),
        }
      }

      fault_verifier_types.BurnProof -> {
        expect [Pair(token_name, -1)] =
          dict.to_pairs(tokens(self.mint, policy_id))
        and {
          utils.quantity_of_policy_id(self.mint, policy_id) == -1,
          is_fault_token_name(token_name),
        }
      }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

// ---------------------------------------------------------------------------
// Tests for the equivocation binding helpers (the offset/sort logic). The full
// signature path is covered by a Rust-generated vector against
// `crypto.verify_schnorr_signature`, the same primitive spos-registry.ak uses.
// ---------------------------------------------------------------------------

test namespace_header_and_pool_id_extraction() {
  // TAG(14) ‖ epoch=7 ‖ threshold=51 ‖ attempt=0 ‖ pool_id(28) ‖ tail
  let tag = "bifrost-dkg-r1"
  let epoch = #"0000000000000007"
  let threshold = #"0000000000000033"
  let attempt = #"0000000000000000"
  let pool = #"11111111111111111111111111111111111111111111111111111111"
  let header =
    tag
      |> bytearray.concat(epoch)
      |> bytearray.concat(threshold)
      |> bytearray.concat(attempt)
      |> bytearray.concat(pool)
  let payload = bytearray.concat(header, #"deadbeefcafe")
  and {
    bytearray.length(header) == namespace_header_length,
    namespace_header(payload) == header,
    payload_pool_id(payload) == pool,
  }
}

test equivocation_evidence_hash_is_order_independent() {
  let a = #"0102030405"
  let b = #"ff00ff00"
  and {
    equivocation_evidence_hash(a, b) == equivocation_evidence_hash(b, a),
    // a < b lexicographically (0x01 < 0xff), so the sorted preimage is a ‖ b
    equivocation_evidence_hash(a, b) == crypto.blake2b_256(
      bytearray.concat(a, b),
    ),
  }
}

// ---------------------------------------------------------------------------
// Full EquivocationProof signature-path tests (WI-021).
//
// The constants below are a *deterministic* BIP-340 vector generated by
// heimdall (`cargo test equivocation_onchain_vector`, fixture
// tests/fixtures/equivocation_onchain_vector.ak): one accused `bifrost_id_pk`,
// two distinct same-namespace canonical DKG-r1 payloads each Schnorr-signed by
// it over `sha2_256(payload)`, plus a same-pool/different-namespace payload and
// a tampered signature for the reject cases. These exercise the real
// `crypto.verify_schnorr_signature` path end to end against a Rust-produced
// signature — the same primitive (and message-hash scheme) heimdall uses.
// ---------------------------------------------------------------------------

const vec_registration_script_hash: ByteArray =
  #"5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e"

const vec_policy_id: ByteArray =
  #"7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a"

const vec_accused_pool_id: ByteArray =
  #"11111111111111111111111111111111111111111111111111111111"

const vec_bifrost_id_pk: ByteArray =
  #"24653eac434488002cc06bbfb7f10fe18991e35f9fe4302dbea6d2353dc0ab1c"

const vec_payload_a: ByteArray =
  #"626966726f73742d646b672d7231000000000000000700000000000000330000000000000000111111111111111111111111111111111111111111111111111111110390297a8b6fc300b5346ca6c74bffafbbe558f3daea2a035902a2971d9391f092022739d9becc0c40e68125d4d8518cf2207f52f3fe0893c9f5fbba4e328f1bb15fb08f76127de18a1dd8afdbb908da792af9f2728191b81ab38e959898f020d1aaba6e322e8703b2b51e7022004c6516994bc5c2fa65c26d244fa4a53286932b85"

const vec_signature_a: ByteArray =
  #"d67be2eb4eaf0a7c31ca9738af583600aabdcebacdd592d781af3f71e4833e000273849729d39bcac8778590eda543a947dc33febd815537e3903cca0fb1e122"

const vec_payload_b: ByteArray =
  #"626966726f73742d646b672d723100000000000000070000000000000033000000000000000011111111111111111111111111111111111111111111111111111111028df0380f2873394ecf73cf4096dfc1a492c260cccf58b54bdf250fe52fb202e20216306733deec28ade877c2f6331cc08f5655fcbb80770624985832d429dec677d04192af58a40e8d099a62d4a6b173dab3252737f4a55dc8179d7c5477dfc85dea2d796c0906662f30abc09ef2f7ef60043f52294960f8171ceb004d689618f2"

const vec_signature_b: ByteArray =
  #"8056a4680c7948eac8d6fde8656fc39cc49cd4d235f2ac90578797d66523bb0e15b668c6a0e5595c2cc0a31bff58b4154d6bf240069375ec95f6b95ef9a04e2b"

const vec_signature_b_tampered: ByteArray =
  #"8156a4680c7948eac8d6fde8656fc39cc49cd4d235f2ac90578797d66523bb0e15b668c6a0e5595c2cc0a31bff58b4154d6bf240069375ec95f6b95ef9a04e2b"

const vec_payload_other_ns: ByteArray =
  #"626966726f73742d646b672d723100000000000000070000000000000033000000000000000111111111111111111111111111111111111111111111111111111111039e2f3d91d12dde27a58860cedc072df8510275d27aa6bc33fbe0f95c2e194eba03ca677e89f1bbbcff4308146d088bb93d3e8ca717229f3d170944c6d7338077ac31626c78ef5a211a97bf11eef61e44abfd793c2ed431c6ebff3d377e7478968edd2974817988389b57d4bd0524fbdfc0e619026ef8e9aeb6493887b4246f2a4f"

const vec_signature_other_ns: ByteArray =
  #"d567b7f03da1e801a49711706fa48ca0aacda818d941a0ace5349186068bb2b6a3d97bc1afc08aa229205a318bc80b077359156437916dffbc85a2d680cb3676"

const vec_namespace_hash: ByteArray =
  #"2e1cd5b61ef875e742f36cdd32a1adf2d8d493687c605ebe7b0ca350dc5c1472"

const vec_expected_evidence_hash: ByteArray =
  #"e9d7969b59e155c6921cee02aafa81e876db1cd392c96cb49cfd3593b5a20c19"

fn mock_address(hash: ByteArray) -> Address {
  Address { payment_credential: Script(hash), stake_credential: None }
}

// The accused's spos_registry node, referenced read-only so the validator can
// bind `bifrost_id_pk` to `accused_pool_id`: a `Script(registration_hash)`
// output holding the registry NFT named `accused_pool_id` with the node datum.
fn registration_ref_input(pk: ByteArray) -> Input {
  let datum: RegistrationListDatum =
    linked_list.Element {
      data: linked_list.Node {
        data: RegistrationNodeData { bifrost_id_pk: pk, bifrost_url: #"" },
      },
      link: None,
    }
  Input {
    output_reference: OutputReference {
      transaction_id: #"0000000000000000000000000000000000000000000000000000000000000002",
      output_index: 0,
    },
    output: Output {
      address: mock_address(vec_registration_script_hash),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(vec_registration_script_hash, vec_accused_pool_id, 1),
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

// Build the (redeemer, transaction) pair for an EquivocationProof mint: the
// FaultProof token name and datum bind `evidence_hash = blake2b_256(min ‖ max)`
// of the two payloads, the registration node is at `reference_inputs[0]`, and
// the spent `input_ref` is present.
fn equivocation_case(
  pk: ByteArray,
  pa: ByteArray,
  sa: ByteArray,
  pb: ByteArray,
  sb: ByteArray,
) -> (fault_verifier_types.FaultProofMintRedeemer, Transaction) {
  let evidence_hash = equivocation_evidence_hash(pa, pb)
  let fault =
    fault_verifier_types.FaultProofDatum {
      kind: fault_verifier_types.Equivocation,
      accused_pool_id: vec_accused_pool_id,
      namespace_hash: vec_namespace_hash,
      evidence_hash,
    }
  let token_name = fault_token_name(vec_accused_pool_id, evidence_hash)
  let input_ref =
    OutputReference {
      transaction_id: #"0000000000000000000000000000000000000000000000000000000000000001",
      output_index: 0,
    }
  let spent_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_address(vec_policy_id),
        value: assets.from_lovelace(2_000_000),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let verifier_output =
    Output {
      address: mock_address(vec_policy_id),
      value: assets.from_lovelace(1_500_000)
        |> assets.add(vec_policy_id, token_name, 1),
      datum: InlineDatum(fault),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [spent_input],
      reference_inputs: [registration_ref_input(pk)],
      outputs: [verifier_output],
      mint: assets.from_asset(vec_policy_id, token_name, 1),
    }
  let redeemer =
    fault_verifier_types.EquivocationProof {
      input_ref,
      registration_ref_input_index: 0,
      bifrost_id_pk: pk,
      fault,
      payload_a: pa,
      signature_a: sa,
      payload_b: pb,
      signature_b: sb,
    }
  (redeemer, tx)
}

// The Rust-derived `evidence_hash` equals the on-chain recomputation over the
// same two payloads — proving heimdall and the validator agree on the hash.
test equivocation_evidence_hash_matches_rust_vector() {
  equivocation_evidence_hash(vec_payload_a, vec_payload_b) == vec_expected_evidence_hash
}

// ACCEPT: two valid signatures, same namespace, distinct payloads, key bound to
// the accused pool — the full `crypto.verify_schnorr_signature` path succeeds.
test equivocation_proof_accepts_valid_vector() {
  let (redeemer, tx) =
    equivocation_case(
      vec_bifrost_id_pk,
      vec_payload_a,
      vec_signature_a,
      vec_payload_b,
      vec_signature_b,
    )
  fault_verifier.mint(vec_registration_script_hash, redeemer, vec_policy_id, tx)
}

// REJECT: signature_b is tampered (still 64 bytes) — verify_schnorr fails.
test equivocation_proof_rejects_bad_signature() {
  let (redeemer, tx) =
    equivocation_case(
      vec_bifrost_id_pk,
      vec_payload_a,
      vec_signature_a,
      vec_payload_b,
      vec_signature_b_tampered,
    )
  !fault_verifier.mint(
    vec_registration_script_hash,
    redeemer,
    vec_policy_id,
    tx,
  )
}

// REJECT: payload_b is in a different namespace (attempt+1) — the namespace
// headers differ, though both are validly signed by the accused.
test equivocation_proof_rejects_wrong_namespace() {
  let (redeemer, tx) =
    equivocation_case(
      vec_bifrost_id_pk,
      vec_payload_a,
      vec_signature_a,
      vec_payload_other_ns,
      vec_signature_other_ns,
    )
  !fault_verifier.mint(
    vec_registration_script_hash,
    redeemer,
    vec_policy_id,
    tx,
  )
}

// REJECT: the two payloads are identical — not a real conflict.
test equivocation_proof_rejects_identical_payload() {
  let (redeemer, tx) =
    equivocation_case(
      vec_bifrost_id_pk,
      vec_payload_a,
      vec_signature_a,
      vec_payload_a,
      vec_signature_a,
    )
  !fault_verifier.mint(
    vec_registration_script_hash,
    redeemer,
    vec_policy_id,
    tx,
  )
}
