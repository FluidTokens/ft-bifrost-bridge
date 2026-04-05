use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash, blake2b_224}
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use aiken/primitive/bytearray
use aiken_design_patterns/stake_validator
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/types/general.{AuthorizationMethod}
use bifrost/types/peg_in.{
  ActionType, Cancel, CompletePegIn, InputCompletePegIn, PegInDatum,
  PegInMintRedeemer, PegInRequest, PegInWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/assets.{AssetName, PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, find_input,
}

validator peg_in_validator(
  bridged_token_policy_id: PolicyId,
  bridged_token_asset_name: AssetName,
  source_chain_merkle_tree_policy_id: PolicyId,
  source_chain_merkle_tree_asset_name: AssetName,
  block_header_merkle_tree_policy_id: PolicyId,
  block_header_merkle_tree_asset_name: AssetName,
  completed_peg_ins_merkle_tree_policy_id: PolicyId,
  completed_peg_ins_merkle_tree_asset_name: AssetName,
  legit_treasury_movement_and_peg_in_spent_verifier_script_hash: ByteArray,
) {
  mint(redeemer: PegInMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent =
      option.is_some(find_input(self.inputs, redeemer.input_ref))

    let minted_tokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(Pair(_asset_name, quantity)) { quantity > 0 },
      )

    let peg_in_outputs =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    let is_each_minted_token_accounted_for =
      utils.indexed_all(
        minted_tokens,
        fn(index, Pair(asset_name, quantity)) {
          let peg_in_request =
            utils.safe_list_at(redeemer.new_peg_in_requests, index)
          let output = utils.safe_list_at(peg_in_outputs, index)
          //AssetName must be the contact of index+input_ref_hash
          let correct_asset_name = and {
              bytearray.at(asset_name, 0) == index,
              bytearray.drop(asset_name, 1) == input_ref_hash,
            }

          //Output must have 1 token with quantity 1
          let output_has_unique_token = and {
              dict.size(assets.tokens(output.value, policy_id)) == 1,
              assets.quantity_of(output.value, policy_id, asset_name) == 1,
            }
          //Output must contain proper InlineDatum
          let output_has_correct_datum =
            output.datum == InlineDatum(
              PegInDatum {
                owner_auth: peg_in_request.owner_auth,
                source_chain_raw_peg_in_tx: peg_in_request.source_chain_raw_peg_in_tx,
                source_chain_treasury_utxo_id: peg_in_request.source_chain_treasury_utxo_id,
                peg_in_amount: peg_in_request.peg_in_amount,
              },
            )
          let source_chain_merkle_tree_ref_input =
            utils.safe_list_at(
              self.reference_inputs,
              redeemer.source_chain_merkle_tree_ref_input_index,
            )
          let source_chain_merkle_tree =
            utils.get_mpf_from_output(source_chain_merkle_tree_ref_input.output)
          let block_header_hash =
            blake2b_224(builtin.serialise_data(peg_in_request.block_header))
          let block_header_merkle_tree_ref_input =
            utils.safe_list_at(
              self.reference_inputs,
              peg_in_request.block_header_merkle_tree_ref_input_index,
            )
          let block_header_merkle_tree =
            utils.get_mpf_from_output(block_header_merkle_tree_ref_input.output)
          //Block header must belong to the official source chain
          let block_header_included_in_source_chain =
            mpf.has(
              source_chain_merkle_tree,
              block_header_hash,
              block_header_hash,
              peg_in_request.block_header_in_source_chain_inclusion_proof,
            )
          //Block header merkle tree ref input must have the unique NFT
          expect
            quantity_of(
              block_header_merkle_tree_ref_input.output.value,
              block_header_merkle_tree_policy_id,
              block_header_merkle_tree_asset_name,
            ) == 1
          let peg_in_request_tx_hash =
            blake2b_224(
              builtin.serialise_data(peg_in_request.source_chain_raw_peg_in_tx),
            )
          //PegInRequest tx must belong to block header merkle tree
          let peg_in_request_tx_included_in_block_header =
            mpf.has(
              block_header_merkle_tree,
              peg_in_request_tx_hash,
              peg_in_request_tx_hash,
              peg_in_request.peg_in_request_tx_in_block_header_inclusion_proof,
            )
          and {
            quantity == 1,
            correct_asset_name,
            output_has_unique_token,
            output_has_correct_datum,
            block_header_included_in_source_chain,
            peg_in_request_tx_included_in_block_header,
          }
        },
      )

    and {
      is_input_ref_spent,
      is_each_minted_token_accounted_for,
    }
  }

  withdraw(
    redeemer: PegInWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let peg_in_inputs =
      list.filter(
        self.inputs,
        fn(input) { input.output.address.payment_credential == credential },
      )
    when redeemer.actionType is {
      Cancel { burnt_peg_in_nft_asset_names } -> {
        expect Script(peg_in_policy_id) = credential
        utils.indexed_all(
          peg_in_inputs,
          fn(index, input) {
            let burnt_peg_in_nft_asset_name =
              utils.safe_list_at(burnt_peg_in_nft_asset_names, index)
            expect InlineDatum(input_datum) = input.output.datum
            expect PegInDatum { owner_auth, .. } = input_datum
            //PegIn cancel authorized
            let user_authorized =
              authorize_action(
                create_auth(
                  owner_auth,
                  self.inputs,
                  self.reference_inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              )
            //Input must contain a PegIn nft
            let peg_in_nft_in_input =
              quantity_of(
                input.output.value,
                peg_in_policy_id,
                burnt_peg_in_nft_asset_name,
              ) == 1
            //The input PegIn nft must be burnt
            let peg_in_nft_burnt =
              quantity_of(
                self.mint,
                peg_in_policy_id,
                burnt_peg_in_nft_asset_name,
              ) == -1
            and {
              user_authorized,
              peg_in_nft_in_input,
              peg_in_nft_burnt,
            }
          },
        )
      }
      CompletePegIn {
        per_input_complete_peg_in_info,
        completed_peg_in_txs_input_index,
        completed_peg_in_txs_output_index,
        added_peg_ins_to_completed_peg_ins_inclusion_proofs,
        tmtilaspisvsh_withdraw_redeemer_index,
      } -> {
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
        let completed_peg_in_txs_input =
          utils.safe_list_at(self.inputs, completed_peg_in_txs_input_index)
        let input_completed_peg_in_merkle_tree =
          utils.get_mpf_from_output(completed_peg_in_txs_input.output)
        let completed_peg_in_txs_output =
          utils.safe_list_at(self.outputs, completed_peg_in_txs_output_index)
        let output_completed_peg_in_merkle_tree =
          utils.get_mpf_from_output(completed_peg_in_txs_output)
        //Number of proofs == number of PegIns to complete
        let peg_in_inputs_and_proofs_have_same_length =
          list.length(added_peg_ins_to_completed_peg_ins_inclusion_proofs) == list.length(
            per_input_complete_peg_in_info,
          )
        //Obtain a list of triples (peg_in_tx_hash, peg_in_tx_hash, proof)
        let peg_in_tx_hashes_as_key_and_value_and_added_peg_ins_to_completed_peg_ins_inclusion_proofs =
          list.map2(
            peg_in_inputs,
            added_peg_ins_to_completed_peg_ins_inclusion_proofs,
            fn(input, proof) {
              expect InlineDatum(input_datum) = input.output.datum
              expect datum: PegInDatum = input_datum
              let peg_in_tx_hash =
                blake2b_224(
                  builtin.serialise_data(datum.source_chain_raw_peg_in_tx),
                )
              (peg_in_tx_hash, peg_in_tx_hash, proof)
            },
          )
        //All completed PegIns have been added to the completed PegIns merkle tree
        let added_completed_peg_ins_to_merkle_tree =
          utils.mpf_multiple_inserts(
            input_completed_peg_in_merkle_tree,
            peg_in_tx_hashes_as_key_and_value_and_added_peg_ins_to_completed_peg_ins_inclusion_proofs,
          ) == output_completed_peg_in_merkle_tree
        and {
          utils.indexed_all(
            peg_in_inputs,
            fn(index, input) {
              let InputCompletePegIn {
                block_header,
                block_header_merkle_tree_ref_input_index,
                block_header_in_source_chain_inclusion_proof,
                treasury_movement_raw_tx,
                treasury_movement_tx_inclusion_proof,
                peg_in_in_completed_peg_ins_exclusion_proof,
              } = utils.safe_list_at(per_input_complete_peg_in_info, index)

              let corresponding_output = utils.safe_list_at(self.outputs, index)
              expect InlineDatum(input_datum) = input.output.datum
              expect datum: PegInDatum = input_datum

              let block_header_hash =
                blake2b_224(builtin.serialise_data(block_header))

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
                blake2b_224(builtin.serialise_data(treasury_movement_raw_tx))
              let peg_in_tx_hash =
                blake2b_224(
                  builtin.serialise_data(datum.source_chain_raw_peg_in_tx),
                )
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
              //Prove that the Treasury Movement is legit and spends this PegIn
              //delegating it to a specific withdraw script
              let tmtilaspisvsh_redeemer <-
                stake_validator.validate_withdraw(
                  legit_treasury_movement_and_peg_in_spent_verifier_script_hash,
                  self.redeemers,
                  tmtilaspisvsh_withdraw_redeemer_index,
                )
              expect [
                redeemer_source_chain_treasury_utxo_id,
                redeemer_source_chain_raw_peg_in_tx, redeemer_peg_in_amount,
                redeemer_treasury_movement_raw_tx,
                ..
              ] = builtin.un_list_data(tmtilaspisvsh_redeemer)

              //Ensuring the redeemer data is the same we have here means
              //the result is trustable. The tx fails if the withdraw script
              //doesn't validate.
              let treasury_movement_tx_is_legit_and_spends_peg_in_utxo = and {
                  redeemer_source_chain_treasury_utxo_id == datum.source_chain_treasury_utxo_id,
                  redeemer_source_chain_raw_peg_in_tx == datum.source_chain_raw_peg_in_tx,
                  redeemer_peg_in_amount == datum.peg_in_amount,
                  redeemer_treasury_movement_raw_tx == treasury_movement_raw_tx,
                }

              //The PegIn must not yet be in the completed_peg_in merkle tree
              let completed_peg_in_exclusion_proven =
                mpf.miss(
                  input_completed_peg_in_merkle_tree,
                  peg_in_tx_hash,
                  peg_in_in_completed_peg_ins_exclusion_proof,
                )

              //The corresponding output must have the correct amount on minted bridged tokens
              let bridged_token_minted =
                quantity_of(
                  corresponding_output.value,
                  bridged_token_policy_id,
                  bridged_token_asset_name,
                ) == builtin.un_i_data(datum.peg_in_amount)

              and {
                user_authorized,
                block_header_included_in_source_chain,
                treasury_movement_tx_included_in_block_header,
                treasury_movement_tx_is_legit_and_spends_peg_in_utxo,
                completed_peg_in_exclusion_proven,
                bridged_token_minted,
              }
            },
          ),
          peg_in_inputs_and_proofs_have_same_length,
          added_completed_peg_ins_to_merkle_tree,
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
