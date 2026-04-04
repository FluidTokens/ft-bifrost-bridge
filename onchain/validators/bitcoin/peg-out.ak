use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry as mpf
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/types/general.{AuthorizationMethod}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{AssetName, PolicyId, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}

pub type PegOutDatum {
  ownerAuth: AuthorizationMethod,
}

pub type ActionType {
  Cancel {
    peg_out_key: ByteArray,
    peg_out_in_treasury_exclusion_proof: mpf.Proof,
  }
  CompletePegOut {
    completed_peg_outs_input_index: Int,
    completed_peg_outs_output_index: Int,
    peg_out_key: ByteArray,
    peg_out_value: ByteArray,
    peg_out_in_treasury_inclusion_proof: mpf.Proof,
    peg_out_in_completed_peg_outs_exclusion_proof: mpf.Proof,
    added_peg_out_to_completed_peg_outs_inclusion_proof: mpf.Proof,
  }
}

pub type PegOutWithdrawRedeemer {
  block_merkle_tree_ref_input_index: Int,
  actionType: ActionType,
}

validator peg_out(
  bridged_token_policy_id: PolicyId,
  bridged_token_asset_name: AssetName,
  block_merkle_tree_policy_id: PolicyId,
  block_merkle_tree_asset_name: AssetName,
  completed_peg_outs_merkle_tree_policy_id: PolicyId,
  completed_peg_outs_merkle_tree_asset_name: AssetName,
) {
  withdraw(
    redeemer: PegOutWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let block_merkle_tree_ref_input =
      utils.safe_list_at(
        self.reference_inputs,
        redeemer.block_merkle_tree_ref_input_index,
      )
    expect
      quantity_of(
        block_merkle_tree_ref_input.output.value,
        block_merkle_tree_policy_id,
        block_merkle_tree_asset_name,
      ) == 1
    let block_merkle_tree =
      get_mpf_from_output(block_merkle_tree_ref_input.output)
    let peg_out_inputs =
      list.filter(
        self.inputs,
        fn(input) { input.output.address.payment_credential == credential },
      )
    when redeemer.actionType is {
      Cancel { peg_out_key, peg_out_in_treasury_exclusion_proof } ->
        //Every PegOut must be properly authorized and excluded from the Treasury Movement tx
        utils.indexed_all(
          peg_out_inputs,
          fn(index, input) {
            expect InlineDatum(input_datum) = input.output.datum
            expect datum: PegOutDatum = input_datum
            let user_authorized =
              authorize_action(
                create_auth(
                  datum.ownerAuth,
                  self.inputs,
                  self.reference_inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              )
            let peg_out_exclusion_proven =
              mpf.miss(
                block_merkle_tree,
                peg_out_key,
                peg_out_in_treasury_exclusion_proof,
              )
            and {
              user_authorized,
              peg_out_exclusion_proven,
            }
          },
        )
      CompletePegOut {
        completed_peg_outs_input_index,
        completed_peg_outs_output_index,
        peg_out_key,
        peg_out_value,
        peg_out_in_treasury_inclusion_proof,
        peg_out_in_completed_peg_outs_exclusion_proof,
        added_peg_out_to_completed_peg_outs_inclusion_proof,
      } -> {
        let completed_peg_outs_input =
          utils.safe_list_at(self.inputs, completed_peg_outs_input_index)
        expect
          quantity_of(
            completed_peg_outs_input.output.value,
            completed_peg_outs_merkle_tree_policy_id,
            completed_peg_outs_merkle_tree_asset_name,
          ) == 1
        let input_completed_peg_out_merkle_tree =
          get_mpf_from_output(completed_peg_outs_input.output)
        let completed_peg_outs_output =
          utils.safe_list_at(self.outputs, completed_peg_outs_output_index)
        expect
          quantity_of(
            completed_peg_outs_output.value,
            completed_peg_outs_merkle_tree_policy_id,
            completed_peg_outs_merkle_tree_asset_name,
          ) == 1
        let output_completed_peg_out_merkle_tree =
          get_mpf_from_output(completed_peg_outs_output)
        let bridged_token_spent_amount =
          list.foldr(
            peg_out_inputs,
            0,
            fn(input, result) {
              result + quantity_of(
                input.output.value,
                bridged_token_policy_id,
                bridged_token_asset_name,
              )
            },
          )
        let all_bridged_tokens_burnt =
          quantity_of(
            self.mint,
            bridged_token_policy_id,
            bridged_token_asset_name,
          ) == bridged_token_spent_amount
        and {
          //Every PegOut must be properly authorized, included in the Treasury Movement tx, 
          //excluded from the current complete_peg_outs tree and added to it
          utils.indexed_all(
            peg_out_inputs,
            fn(index, input) {
              expect InlineDatum(input_datum) = input.output.datum
              expect datum: PegOutDatum = input_datum
              let user_authorized =
                authorize_action(
                  create_auth(
                    datum.ownerAuth,
                    self.inputs,
                    self.reference_inputs,
                    self.withdrawals,
                    self.extra_signatories,
                    self.mint,
                  ),
                )
              let peg_out_inclusion_proven =
                mpf.has(
                  block_merkle_tree,
                  peg_out_key,
                  peg_out_value,
                  peg_out_in_treasury_inclusion_proof,
                )
              let completed_peg_out_exclusion_proven =
                mpf.miss(
                  input_completed_peg_out_merkle_tree,
                  peg_out_key,
                  peg_out_in_completed_peg_outs_exclusion_proof,
                )
              let added_completed_peg_out_to_merkle_tree =
                mpf.insert(
                  input_completed_peg_out_merkle_tree,
                  peg_out_key,
                  peg_out_value,
                  added_peg_out_to_completed_peg_outs_inclusion_proof,
                ) == output_completed_peg_out_merkle_tree
              and {
                user_authorized,
                peg_out_inclusion_proven,
                completed_peg_out_exclusion_proven,
                added_completed_peg_out_to_merkle_tree,
              }
            },
          ),
          //All the pegged out tokens must be burnt
          all_bridged_tokens_burnt,
        }
      }
    }
  }

  spend(
    datumOpt: Option<Data>,
    _redeemer: Data,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) =
      list.find(self.inputs, fn(input) { input.output_reference == own_ref })
    expect Script(own_script_hash) = own_input.output.address.payment_credential
    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(scriptHash), _amnt) -> scriptHash == own_script_hash
          _ -> False
        }
      },
    )
  }

  else(_ctx: ScriptContext) {
    False
  }
}

pub fn get_mpf_from_output(output: Output) {
  //TODO
  mpf.empty
}
