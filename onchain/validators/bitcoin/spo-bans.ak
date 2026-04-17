use aiken/collection/dict
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use aiken_design_patterns/stake_validator
use bifrost/types/fault_verifier.{FaultProofDatum}
use bifrost/types/spo_bans as spo_bans_types
use bifrost/types/spos_registry.{RegistrationListDatum}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, Value, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, ScriptPurpose,
  Transaction, find_input,
}

const ban_root_key = "ban-root"

const ban_node_key_prefix = "ban/"

const ban_node_key_prefix_length = 4

fn ban_node_asset_name(pool_id: ByteArray) -> ByteArray {
  bytearray.concat(ban_node_key_prefix, pool_id)
}

fn get_fault_proof_datum(output: Output) -> FaultProofDatum {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: FaultProofDatum = raw_datum
  datum
}

fn get_fault_proof_info(
  input: Input,
  fault_proof_policy_id: PolicyId,
) -> (ByteArray, Int) {
  expect Pair(token_name, 1) =
    utils.get_singleton_asset_with_policy(
      input.output.value,
      fault_proof_policy_id,
    )
  expect _fault = get_fault_proof_datum(input.output)
  expect True = bytearray.length(token_name) == 32
  (
    bytearray.take(token_name, 28),
    bytearray.drop(token_name, 28) |> bytearray.to_int_big_endian,
  )
}

fn get_ban_node_data(output: Output) -> spo_bans_types.BanNodeData {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: spo_bans_types.BanListDatum = raw_datum
  when datum.data is {
    linked_list.Node { data } -> data
    linked_list.Root { .. } -> fail @"Ban output must be a node"
  }
}

fn validate_registered_pool_ref(
  input: Input,
  registration_script_hash: ByteArray,
  pool_id: ByteArray,
) -> Bool {
  expect Script(script_hash) = input.output.address.payment_credential
  expect Pair(asset_name, 1) =
    utils.get_singleton_asset_with_policy(
      input.output.value,
      registration_script_hash,
    )
  expect InlineDatum(raw_datum) = input.output.datum
  expect datum: RegistrationListDatum = raw_datum

  expect linked_list.Node { data: _registration_data } = datum.data

  and {
    script_hash == registration_script_hash,
    asset_name == pool_id,
  }
}

fn validate_ban_anchor_data(
  anchor_key: Option<ByteArray>,
  anchor_data: Data,
) -> Bool {
  when anchor_key is {
    None -> {
      expect _: spo_bans_types.BanListRootData = anchor_data
      True
    }
    Some(_) -> {
      expect _: spo_bans_types.BanNodeData = anchor_data
      True
    }
  }
}

fn validate_root_data(_root_lovelace: Int, root_data: Data) -> Bool {
  validate_ban_anchor_data(None, root_data)
}

fn validate_bootstrap_root(
  outputs: List<Output>,
  tx_mint: Value,
  policy_id: PolicyId,
  root_key: ByteArray,
) -> Bool {
  let root_output =
    utils.find_singleton_asset_output_at_script(
      outputs,
      policy_id,
      policy_id,
      root_key,
    )

  linked_list.init(True, root_output, tx_mint, validate_root_data)
    |> linked_list.run_root_with(policy_id, root_key)
}

fn has_minimal_apply_ban_withdraw(
  own_hash: ByteArray,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  withdraw_redeemer_index: Int,
) -> Bool {
  stake_validator.validate_withdraw(
    own_hash,
    redeemers,
    withdraw_redeemer_index,
    fn(redeemer) {
      expect _: spo_bans_types.SpoBansWithdrawRedeemer = redeemer
      True
    },
  )
}

fn has_valid_ban_auth_asset(value: Value, own_hash: PolicyId) -> Bool {
  expect Pair(asset_name, 1) =
    utils.get_singleton_asset_with_policy(value, own_hash)

  asset_name == ban_root_key || bytearray.take(
    asset_name,
    ban_node_key_prefix_length,
  ) == ban_node_key_prefix
}

fn fault_proof_burn_ok(
  self: Transaction,
  fault_token_name: ByteArray,
  fault_proof_policy_id: PolicyId,
) -> Bool {
  expect [Pair(burnt_fault_token_name, -1)] =
    dict.to_pairs(tokens(self.mint, fault_proof_policy_id))

  burnt_fault_token_name == fault_token_name
}

fn pow2(exponent: Int) -> Int {
  if exponent <= 0 {
    1
  } else {
    2 * pow2(exponent - 1)
  }
}

fn first_ban_transition_ok(
  self: Transaction,
  own_hash: PolicyId,
  pool_id: ByteArray,
  ban_anchor_input_index: Int,
  ban_anchor_output_index: Int,
  ban_node_output_index: Int,
  current_epoch: Int,
) -> Bool {
  let ban_anchor_input = utils.safe_list_at(self.inputs, ban_anchor_input_index)
  let continued_ban_anchor_output =
    utils.safe_list_at(self.outputs, ban_anchor_output_index)
  let new_ban_node_output =
    utils.safe_list_at(self.outputs, ban_node_output_index)

  linked_list.insert_ascending(
    ban_anchor_input,
    continued_ban_anchor_output,
    new_ban_node_output,
    self.mint,
    fn(
      anchor_lovelace_change,
      anchor_key,
      anchor_data,
      _new_node_lovelace,
      new_node_key,
      new_node_data,
      _new_node_link,
    ) {
      expect parsed_new_node_data: spo_bans_types.BanNodeData = new_node_data

      and {
        validate_ban_anchor_data(anchor_key, anchor_data),
        anchor_lovelace_change == 0,
        new_node_key == pool_id,
        parsed_new_node_data == spo_bans_types.BanNodeData {
          ban_counter: 1,
          ban_until_epoch: current_epoch + 1,
        },
      }
    },
  )
    |> linked_list.run_eval_with(
        own_hash,
        ban_root_key,
        ban_node_key_prefix,
        ban_node_key_prefix_length,
      )
}

fn repeated_ban_transition_ok(
  self: Transaction,
  own_hash: PolicyId,
  pool_id: ByteArray,
  fault_epoch: Int,
  existing_ban_input_index: Int,
  ban_node_output_index: Int,
  current_epoch: Int,
) -> Bool {
  let existing_ban_input =
    utils.safe_list_at(self.inputs, existing_ban_input_index)

  linked_list.spend_for_updating_elements_data(
    existing_ban_input_index,
    ban_node_output_index,
    existing_ban_input.output_reference,
    self.inputs,
    self.outputs,
    self.mint,
    fn(lovelace_change, node_key, input_data, continued_data) {
      expect old_ban_data: spo_bans_types.BanNodeData = input_data
      expect new_ban_data: spo_bans_types.BanNodeData = continued_data

      and {
        lovelace_change == 0,
        node_key == Some(pool_id),
        old_ban_data.ban_counter >= 1,
        fault_epoch > old_ban_data.ban_until_epoch -
          pow2(old_ban_data.ban_counter - 1),
        new_ban_data == spo_bans_types.BanNodeData {
          ban_counter: old_ban_data.ban_counter + 1,
          ban_until_epoch: current_epoch + pow2(old_ban_data.ban_counter),
        },
      }
    },
  )
    |> linked_list.run_eval_with(
        own_hash,
        ban_root_key,
        ban_node_key_prefix,
        ban_node_key_prefix_length,
      )
}

validator spo_bans(
  registration_script_hash: ByteArray,
  fault_proof_policy_id: PolicyId,
  bootstrap_tx_id: ByteArray,
  bootstrap_output_index: Int,
) {
  mint(
    redeemer: spo_bans_types.SpoBansMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    when redeemer is {
      spo_bans_types.Bootstrap { input_ref } -> {
        expect Some(_bootstrap_input) = find_input(self.inputs, input_ref)

        and {
          utils.quantity_of_policy_id(self.mint, policy_id) == 1,
          quantity_of(self.mint, policy_id, ban_root_key) == 1,
          validate_bootstrap_root(
            self.outputs,
            self.mint,
            policy_id,
            ban_root_key,
          ),
          input_ref == OutputReference(bootstrap_tx_id, bootstrap_output_index),
        }
      }
      spo_bans_types.MintBanNode { withdraw_redeemer_index, pool_id } -> {
        let token_name = ban_node_asset_name(pool_id)
        let ban_node_output =
          utils.find_singleton_asset_output_at_script(
            self.outputs,
            policy_id,
            policy_id,
            token_name,
          )
        expect _ban_node_data = get_ban_node_data(ban_node_output)

        and {
          utils.quantity_of_policy_id(self.mint, policy_id) == 1,
          quantity_of(self.mint, policy_id, token_name) == 1,
          has_minimal_apply_ban_withdraw(
            policy_id,
            self.redeemers,
            withdraw_redeemer_index,
          ),
        }
      }
    }
  }

  spend(
    _datum: Option<spo_bans_types.BanListDatum>,
    redeemer: spo_bans_types.SpoBansSpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential
    let spo_bans_types.BanListAction { withdraw_redeemer_index } = redeemer

    and {
      has_valid_ban_auth_asset(own_input.output.value, own_hash),
      has_minimal_apply_ban_withdraw(
        own_hash,
        self.redeemers,
        withdraw_redeemer_index,
      ),
    }
  }

  withdraw(
    redeemer: spo_bans_types.SpoBansWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(own_hash) = credential
    let spo_bans_types.ApplyBan {
      fault_input_index,
      registration_ref_input_index,
      ban_anchor_input_index,
      ban_anchor_output_index,
      existing_ban_input_index,
      ban_node_output_index,
      current_epoch,
    } = redeemer

    let registration_ref_input =
      utils.safe_list_at(self.reference_inputs, registration_ref_input_index)
    let fault_input = utils.safe_list_at(self.inputs, fault_input_index)
    let fault_token_name =
      utils.get_singleton_asset_with_policy(
        fault_input.output.value,
        fault_proof_policy_id,
      )
        |> fn(Pair(token_name, _quantity)) { token_name }
    let (fault_pool_id, fault_epoch) =
      get_fault_proof_info(fault_input, fault_proof_policy_id)

    when existing_ban_input_index is {
      Some(index) -> {
        and {
          validate_registered_pool_ref(
            registration_ref_input,
            registration_script_hash,
            fault_pool_id,
          ),
          current_epoch >= 0,
          fault_proof_burn_ok(self, fault_token_name, fault_proof_policy_id),
          utils.quantity_of_policy_id(self.mint, own_hash) == 0,
          repeated_ban_transition_ok(
            self,
            own_hash,
            fault_pool_id,
            fault_epoch,
            index,
            ban_node_output_index,
            current_epoch,
          ),
        }
      }
      None -> {
        let token_name = ban_node_asset_name(fault_pool_id)

        and {
          validate_registered_pool_ref(
            registration_ref_input,
            registration_script_hash,
            fault_pool_id,
          ),
          current_epoch >= 0,
          fault_proof_burn_ok(self, fault_token_name, fault_proof_policy_id),
          quantity_of(self.mint, own_hash, token_name) == 1,
          first_ban_transition_ok(
            self,
            own_hash,
            fault_pool_id,
            ban_anchor_input_index,
            ban_anchor_output_index,
            ban_node_output_index,
            current_epoch,
          ),
        }
      }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}
