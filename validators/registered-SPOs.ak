use aiken/builtin
use aiken/collection/list
use aiken/crypto.{verify_ed25519_signature}
use aiken/interval.{Finite, Interval}
use aiken_design_patterns/linked_list/ordered.{
  Key, NodeDatum, get_node_inputs, get_node_outputs,
}
use bifrost/constants
use bifrost/types/registered_spos.{
  Deinit, Deregister, Init, Register, RegisteredSposDatum,
  RegisteredSposMintRedeemer,
}
use bifrost/utils
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}

validator mint(config_policy_id: PolicyId, config_asset_name: ByteArray) {
  mint(
    redeemer: RegisteredSposMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    let node_in_outputs = get_node_inputs(self.inputs, policy_id)
    let node_outputs = get_node_outputs(self.outputs, policy_id)
    let node_mint = tokens(self.mint, policy_id)
    when redeemer is {
      Init -> {
        expect
          Pair(config_asset_name, 1) == utils.get_singleton_asset_with_policy(
            self.mint,
            config_policy_id,
          )
        Pair(constants.registered_spos_asset_name, 1) == utils.get_singleton_asset_with_policy(
          self.mint,
          policy_id,
        )
      }
      Deinit -> {
        expect
          Pair(config_asset_name, -1) == utils.get_singleton_asset_with_policy(
            self.mint,
            config_policy_id,
          )
        Pair(constants.registered_spos_asset_name, -1) == utils.get_singleton_asset_with_policy(
          self.mint,
          policy_id,
        )
      }
      Register {
        key_to_prepend,
        config_ref_input_index,
        prepended_node_output_index,
        anchor_node_output_index,
        spo_bitcoin_secp256k1_key_signature,
      } -> {
        let config =
          utils.get_config_as_data_list(
            utils.safe_list_at(self.reference_inputs, config_ref_input_index),
            config_policy_id,
            config_asset_name,
          )
        let spo_registration_duration =
          builtin.un_i_data(utils.safe_list_at(config, 3))
        expect Finite(valid_to) = self.validity_range.upper_bound.bound_type
        expect Some(registered_node_output) =
          list.at(self.outputs, prepended_node_output_index)
        expect InlineDatum(registered_spo_datum) = registered_node_output.datum
        expect parsed_registered_spo_datum: NodeDatum = registered_spo_datum
        expect registered_spo_data: RegisteredSposDatum =
          parsed_registered_spo_datum.data
        and {
          ordered.prepend(
            Key(key_to_prepend),
            prepended_node_output_index,
            anchor_node_output_index,
            node_in_outputs,
            node_outputs,
            node_mint,
          ),
          ordered.prepend(
            Key(key_to_prepend),
            prepended_node_output_index,
            anchor_node_output_index,
            node_in_outputs,
            node_outputs,
            node_mint,
          ),
          list.has(self.extra_signatories, key_to_prepend),
          registered_spo_data.registration_time == valid_to + spo_registration_duration,
          verify_ed25519_signature(
            registered_spo_data.spo_cardano_ecdsa_key,
            registered_spo_data.spo_bitcoin_secp256k1_key,
            spo_bitcoin_secp256k1_key_signature,
          ),
        }
      }
      Deregister {
        node_to_deregister_key,
        removed_node_input_index,
        anchor_node_input_index,
      } -> and {
          ordered.remove(
            Key(node_to_deregister_key),
            removed_node_input_index,
            anchor_node_input_index,
            node_in_outputs,
            node_outputs,
            node_mint,
          ),
          list.has(self.extra_signatories, node_to_deregister_key),
        }
    }
  }

  else(_) {
    fail
  }
}

validator spend(registered_spos_mint_script_hash: PolicyId) {
  spend(
    _datum: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    ordered.list_state_transition(
      tokens(self.mint, registered_spos_mint_script_hash),
    )
  }

  else(_) {
    fail
  }
}
