use bifrost/fault_verifier/common
use bifrost/types/fault_verifier as fault_verifier_types
use bifrost/utils
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{Transaction}

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
          // Fail closed until the final canonical namespace parser is wired in.
          False,
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
