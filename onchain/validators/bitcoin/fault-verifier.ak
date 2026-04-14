use aiken/collection/dict
use aiken/collection/list
use aiken/primitive/bytearray
use bifrost/types/fault_verifier as fault_verifier_types
use bifrost/utils
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Transaction, find_input}

fn is_pool_id(token_name: ByteArray) -> Bool {
  bytearray.length(token_name) == 28
}

fn fault_token_name(accused_pool_id: ByteArray) -> ByteArray {
  accused_pool_id
}

validator fault_verifier {
  mint(
    redeemer: fault_verifier_types.FaultProofMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    when redeemer is {
      fault_verifier_types.PublishProof { input_ref, accused_pool_id, fault } -> {
        let token_name = fault_token_name(accused_pool_id)

        expect Some(_input_present) = find_input(self.inputs, input_ref)

        expect [verifier_output] =
          list.filter(
            self.outputs,
            fn(output) { quantity_of(output.value, policy_id, token_name) == 1 },
          )

        and {
          utils.quantity_of_policy_id(self.mint, policy_id) == 1,
          is_pool_id(token_name),
          quantity_of(self.mint, policy_id, token_name) == 1,
          verifier_output.datum == InlineDatum(fault),
        }
      }
      fault_verifier_types.BurnProof -> {
        expect [Pair(token_name, -1)] =
          dict.to_pairs(tokens(self.mint, policy_id))
        and {
          utils.quantity_of_policy_id(self.mint, policy_id) == -1,
          is_pool_id(token_name),
        }
      }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}
