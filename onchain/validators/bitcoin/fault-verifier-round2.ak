use bifrost/fault_verifier/common
use bifrost/fault_verifier/dkg
use bifrost/fault_verifier/round2/proof_verifier
use bifrost/types/fault_verifier as fault_verifier_types
use bifrost/utils
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{Transaction}

validator fault_verifier_round2(registration_script_hash: PolicyId) {
  mint(
    redeemer: fault_verifier_types.FaultProofMintRedeemer<
      fault_verifier_types.Round2InvalidPayloadEvidence,
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
        let round2_entry = dkg.selected_round2_entry(
          evidence.canonical_round2_bytes,
          evidence.round2_entry_index,
        )
        let evidence_hash = round2_entry.evidence_hash

        and {
          dkg.is_round1_payload(
            evidence.canonical_round1_bytes,
            evidence.accused_pool_id,
          ),
          dkg.is_round2_payload(
            evidence.canonical_round2_bytes,
            evidence.accused_pool_id,
          ),
          dkg.public_inputs_match(
            evidence.halo2_public_inputs,
            evidence_hash,
            evidence.accused_pool_id,
          ),
          dkg.opened_share_matches(
            round2_entry,
            evidence.pad,
            evidence.opened_share,
          ),
          common.verify_bifrost_signature(
            bifrost_id_pk,
            evidence.canonical_round1_bytes,
            evidence.round1_signature,
          ),
          common.verify_bifrost_signature(
            bifrost_id_pk,
            evidence.canonical_round2_bytes,
            evidence.round2_signature,
          ),
          proof_verifier.verifier(
            evidence.halo2_proof,
            dkg.halo2_public_inputs(evidence_hash, evidence.accused_pool_id),
          ),
          common.mint_single_fault_token(
            self,
            policy_id,
            evidence.accused_pool_id,
            evidence_hash,
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
