use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/primitive/bytearray
use bifrost/types/fault_verifier as fault_verifier_types
use bifrost/utils
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Transaction, find_input}

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

validator fault_verifier {
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
      // BIP-340-signed by the accused's bifrost_id_pk.
      //
      // NOTE (residual, same class as §5a): this trusts the redeemer-supplied
      // `bifrost_id_pk`. Full soundness additionally requires binding it to
      // `accused_pool_id` via an spos_registry reference input (the registry is
      // the only authority on pool_id → bifrost_id_pk). That binding — and the
      // accompanying registry-policy parameterization — is deliberately left
      // out here, matching the documentation's §9.2 which takes the accused key
      // as given.
      fault_verifier_types.EquivocationProof {
        input_ref,
        bifrost_id_pk,
        fault,
        payload_a,
        signature_a,
        payload_b,
        signature_b,
      } -> {
        let token_name = fault_token_name(fault.accused_pool_id, fault.evidence_hash)

        expect Some(_input_present) = find_input(self.inputs, input_ref)

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
