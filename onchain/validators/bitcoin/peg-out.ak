use aiken/builtin
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry as mpf
use aiken_design_patterns/stake_validator
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/types/general.{AuthorizationMethod}
use bifrost/types/peg_out.{
  ActionType, Cancel, CompletePegOut, InputCancel, InputCompletePegOut,
  PegOutDatum, PegOutWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{AssetName, PolicyId, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}

validator peg_out_validator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: PegOutWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let bridged_token_policy_id =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let bridged_token_asset_name =
      builtin.un_b_data(utils.safe_list_at(config, 1))
    let source_chain_merkle_tree_policy_id =
      builtin.un_b_data(utils.safe_list_at(config, 2))
    let source_chain_merkle_tree_asset_name =
      builtin.un_b_data(utils.safe_list_at(config, 3))
    let block_header_merkle_tree_policy_id =
      builtin.un_b_data(utils.safe_list_at(config, 4))
    let block_header_merkle_tree_asset_name =
      builtin.un_b_data(utils.safe_list_at(config, 5))
    let completed_peg_outs_merkle_tree_policy_id =
      builtin.un_b_data(utils.safe_list_at(config, 8))
    let completed_peg_outs_merkle_tree_asset_name =
      builtin.un_b_data(utils.safe_list_at(config, 9))
    let legit_treasury_movement_and_peg_out_produced_verifier_script_hash =
      builtin.un_b_data(utils.safe_list_at(config, 13))
    let legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash =
      builtin.un_b_data(utils.safe_list_at(config, 14))
    let peg_out_inputs =
      list.filter(
        self.inputs,
        fn(input) { input.output.address.payment_credential == credential },
      )
    let source_chain_merkle_tree_ref_input =
      utils.safe_list_at(
        self.reference_inputs,
        redeemer.source_chain_merkle_tree_ref_input_index,
      )
    //Source chain merkle tree ref input must have the unique NFT
    expect
      quantity_of(
        source_chain_merkle_tree_ref_input.output.value,
        source_chain_merkle_tree_policy_id,
        source_chain_merkle_tree_asset_name,
      ) == 1
    let source_chain_merkle_tree =
      utils.get_mpf_from_output(source_chain_merkle_tree_ref_input.output)

    when redeemer.action_type is {
      Cancel { per_input_cancel_info, tmtilasponpvsh_withdraw_redeemer_index } ->
        //Every PegOut must be properly authorized and excluded from the Treasury Movement tx
        utils.indexed_all(
          peg_out_inputs,
          fn(index, input) {
            let bridged_tokens_to_peg_out =
              quantity_of(
                input.output.value,
                bridged_token_policy_id,
                bridged_token_asset_name,
              )
            let bridged_tokens_to_peg_out_as_data: Data =
              bridged_tokens_to_peg_out
            let InputCancel {
              block_header,
              block_header_merkle_tree_ref_input_index,
              block_header_in_source_chain_inclusion_proof,
              treasury_movement_raw_tx,
              treasury_movement_tx_inclusion_proof,
            } = utils.safe_list_at(per_input_cancel_info, index)
            let block_header_hash =
              utils.bitcoin_hash(builtin.un_b_data(block_header))
            let block_header_merkle_tree_ref_input =
              utils.safe_list_at(
                self.reference_inputs,
                block_header_merkle_tree_ref_input_index,
              )
            //Block header must belong to the official source chain
            let block_header_included_in_source_chain =
              mpf.has(
                source_chain_merkle_tree,
                block_header_hash,
                block_header_hash,
                block_header_in_source_chain_inclusion_proof,
              )
            //Block header merkle tree ref input must have the unique NFT
            expect
              quantity_of(
                block_header_merkle_tree_ref_input.output.value,
                block_header_merkle_tree_policy_id,
                block_header_merkle_tree_asset_name,
              ) == 1
            let block_header_merkle_tree =
              utils.get_mpf_from_output(
                block_header_merkle_tree_ref_input.output,
              )
            let treasury_movement_tx_hash =
              utils.bitcoin_hash(builtin.un_b_data(treasury_movement_raw_tx))
            expect InlineDatum(input_datum) = input.output.datum
            expect datum: PegOutDatum = input_datum
            //PegOut cancel authorized
            let user_authorized =
              authorize_action(
                create_auth(
                  datum.owner_auth,
                  self.inputs,
                  self.reference_inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              )
            //Treasury Movement tx must belong to block header merkle tree
            let treasury_movement_tx_included_in_block_header =
              mpf.has(
                block_header_merkle_tree,
                treasury_movement_tx_hash,
                treasury_movement_tx_hash,
                treasury_movement_tx_inclusion_proof,
              )
            //Prove that the Treasury Movement is legit and dpes NOT produce this PegOut
            //delegating it to a specific withdraw script
            let tmtilaspisvsh_redeemer <-
              stake_validator.validate_withdraw(
                legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash,
                self.redeemers,
                tmtilasponpvsh_withdraw_redeemer_index,
              )
            expect [
              redeemer_source_chain_treasury_utxo_id,
              redeemer_source_chain_destination_address, redeemer_peg_out_amount,
              redeemer_treasury_movement_raw_tx,
              ..
            ] = builtin.un_list_data(tmtilaspisvsh_redeemer)

            //Ensuring the redeemer data is the same we have here means
            //the result is trustable. The tx fails if the withdraw script
            //doesn't validate.
            let treasury_movement_tx_is_legit_and_does_not_produce_peg_out_utxo =
              and {
                redeemer_source_chain_treasury_utxo_id == datum.source_chain_treasury_utxo_id,
                redeemer_source_chain_destination_address == datum.source_chain_destination_address,
                redeemer_peg_out_amount == bridged_tokens_to_peg_out_as_data,
                redeemer_treasury_movement_raw_tx == treasury_movement_raw_tx,
              }
            and {
              user_authorized,
              block_header_included_in_source_chain,
              treasury_movement_tx_included_in_block_header,
              treasury_movement_tx_is_legit_and_does_not_produce_peg_out_utxo,
            }
          },
        )
      CompletePegOut {
        per_input_complete_peg_out_info,
        completed_peg_outs_input_index,
        completed_peg_outs_output_index,
        added_peg_out_to_completed_peg_outs_inclusion_proofs,
        tmtilaspopvsh_withdraw_redeemer_index,
      } -> {
        let completed_peg_outs_input =
          utils.safe_list_at(self.inputs, completed_peg_outs_input_index)
        //Complete PegOuts merkle tree input must have the unique NFT
        expect
          quantity_of(
            completed_peg_outs_input.output.value,
            completed_peg_outs_merkle_tree_policy_id,
            completed_peg_outs_merkle_tree_asset_name,
          ) == 1
        let input_completed_peg_out_merkle_tree =
          utils.get_mpf_from_output(completed_peg_outs_input.output)
        let completed_peg_outs_output =
          utils.safe_list_at(self.outputs, completed_peg_outs_output_index)
        //Complete PegOuts merkle tree output must have the unique NFT
        expect
          quantity_of(
            completed_peg_outs_output.value,
            completed_peg_outs_merkle_tree_policy_id,
            completed_peg_outs_merkle_tree_asset_name,
          ) == 1
        let output_completed_peg_out_merkle_tree =
          utils.get_mpf_from_output(completed_peg_outs_output)
        //Number of proofs == number of PegOuts to complete == number of PegOut infos
        let peg_out_inputs_and_info_and_proofs_have_same_length = and {
            list.length(added_peg_out_to_completed_peg_outs_inclusion_proofs) == list.length(
              per_input_complete_peg_out_info,
            ),
            list.length(peg_out_inputs) == list.length(
              per_input_complete_peg_out_info,
            ),
          }
        //Obtain a list of triples (source_chain_peg_out_utxo_id, source_chain_peg_out_utxo_id, proof)
        let peg_out_utxo_hashes_as_key_and_value_and_added_peg_outs_to_completed_peg_outs_inclusion_proofs =
          list.map2(
            per_input_complete_peg_out_info,
            added_peg_out_to_completed_peg_outs_inclusion_proofs,
            fn(peg_out_info, proof) {
              (
                peg_out_info.source_chain_peg_out_utxo_id,
                peg_out_info.source_chain_peg_out_utxo_id,
                proof,
              )
            },
          )
        //All completed PegOuts have been added to the completed PegOuts merkle tree
        let added_completed_peg_outs_to_merkle_tree =
          utils.mpf_multiple_inserts(
            input_completed_peg_out_merkle_tree,
            peg_out_utxo_hashes_as_key_and_value_and_added_peg_outs_to_completed_peg_outs_inclusion_proofs,
          ) == output_completed_peg_out_merkle_tree

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
        //The completed_peg_in_txs must not change in value
        let same_completed_peg_outs_value =
          completed_peg_outs_input.output.value == completed_peg_outs_output.value
        //The completed_peg_in_txs must not change address
        let same_completed_peg_outs_address =
          completed_peg_outs_input.output.address == completed_peg_outs_output.address
        //All the pegged out bridged tokens must be burnt
        let all_bridged_tokens_burnt =
          quantity_of(
            self.mint,
            bridged_token_policy_id,
            bridged_token_asset_name,
          ) == bridged_token_spent_amount
        and {
          utils.indexed_all(
            peg_out_inputs,
            fn(index, input) {
              let bridged_tokens_to_peg_out =
                quantity_of(
                  input.output.value,
                  bridged_token_policy_id,
                  bridged_token_asset_name,
                )
              let bridged_tokens_to_peg_out_as_data: Data =
                bridged_tokens_to_peg_out
              let InputCompletePegOut {
                block_header,
                block_header_merkle_tree_ref_input_index,
                block_header_in_source_chain_inclusion_proof,
                treasury_movement_raw_tx,
                treasury_movement_tx_inclusion_proof,
                source_chain_peg_out_utxo_id,
                peg_out_in_completed_peg_outs_exclusion_proof,
              } = utils.safe_list_at(per_input_complete_peg_out_info, index)
              let source_chain_peg_out_utxo_id_as_data: Data =
                source_chain_peg_out_utxo_id

              expect InlineDatum(input_datum) = input.output.datum
              expect datum: PegOutDatum = input_datum

              let block_header_hash =
                utils.bitcoin_hash(builtin.un_b_data(block_header))

              let block_header_merkle_tree_ref_input =
                utils.safe_list_at(
                  self.reference_inputs,
                  block_header_merkle_tree_ref_input_index,
                )
              //Block header must belong to the official source chain
              let block_header_included_in_source_chain =
                mpf.has(
                  source_chain_merkle_tree,
                  block_header_hash,
                  block_header_hash,
                  block_header_in_source_chain_inclusion_proof,
                )
              //Block header merkle tree ref input must have the unique NFT
              expect
                quantity_of(
                  block_header_merkle_tree_ref_input.output.value,
                  block_header_merkle_tree_policy_id,
                  block_header_merkle_tree_asset_name,
                ) == 1
              let block_header_merkle_tree =
                utils.get_mpf_from_output(
                  block_header_merkle_tree_ref_input.output,
                )
              let treasury_movement_tx_hash =
                utils.bitcoin_hash(builtin.un_b_data(treasury_movement_raw_tx))

              //PegIn completion authorized
              let user_authorized =
                authorize_action(
                  create_auth(
                    datum.owner_auth,
                    self.inputs,
                    self.reference_inputs,
                    self.withdrawals,
                    self.extra_signatories,
                    self.mint,
                  ),
                )

              //Treasury Movement tx must belong to block header merkle tree
              let treasury_movement_tx_included_in_block_header =
                mpf.has(
                  block_header_merkle_tree,
                  treasury_movement_tx_hash,
                  treasury_movement_tx_hash,
                  treasury_movement_tx_inclusion_proof,
                )
              //Prove that the Treasury Movement is legit and produces the PegOut utxo
              //delegating it to a specific withdraw script
              let tmtilaspopvsh_redeemer <-
                stake_validator.validate_withdraw(
                  legit_treasury_movement_and_peg_out_produced_verifier_script_hash,
                  self.redeemers,
                  tmtilaspopvsh_withdraw_redeemer_index,
                )
              expect [
                redeemer_source_chain_treasury_utxo_id,
                redeemer_source_chain_destination_address,
                redeemer_source_chain_peg_out_utxo_id, redeemer_peg_out_amount,
                redeemer_treasury_movement_raw_tx,
                ..
              ] = builtin.un_list_data(tmtilaspopvsh_redeemer)

              //Ensuring the redeemer data is the same we have here means
              //the result is trustable. The tx fails if the withdraw script
              //doesn't validate.
              let treasury_movement_tx_is_legit_and_produces_peg_out_utxo =
                and {
                  redeemer_source_chain_treasury_utxo_id == datum.source_chain_treasury_utxo_id,
                  redeemer_source_chain_destination_address == datum.source_chain_destination_address,
                  redeemer_source_chain_peg_out_utxo_id == source_chain_peg_out_utxo_id_as_data,
                  redeemer_peg_out_amount == bridged_tokens_to_peg_out_as_data,
                  redeemer_treasury_movement_raw_tx == treasury_movement_raw_tx,
                }

              let completed_peg_out_exclusion_proven =
                mpf.miss(
                  input_completed_peg_out_merkle_tree,
                  source_chain_peg_out_utxo_id,
                  peg_out_in_completed_peg_outs_exclusion_proof,
                )

              and {
                user_authorized,
                block_header_included_in_source_chain,
                treasury_movement_tx_included_in_block_header,
                treasury_movement_tx_is_legit_and_produces_peg_out_utxo,
                completed_peg_out_exclusion_proven,
              }
            },
          ),
          peg_out_inputs_and_info_and_proofs_have_same_length,
          added_completed_peg_outs_to_merkle_tree,
          all_bridged_tokens_burnt,
          same_completed_peg_outs_value,
          same_completed_peg_outs_address,
        }
      }
    }
  }

  spend(
    _datumOpt: Option<Data>,
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
          Pair(Script(script_hash), _amnt) -> script_hash == own_script_hash
          _ -> False
        }
      },
    )
  }

  else(_ctx: ScriptContext) {
    False
  }
}
