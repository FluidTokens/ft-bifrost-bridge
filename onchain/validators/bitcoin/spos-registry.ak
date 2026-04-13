use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use bifrost/types/spos_registry.{
  ListRootData, RegistrationListDatum, RegistrationNodeData,
  SposRegistryMintRedeemer, SposRegistrySpendRedeemer,
}
use bifrost/types/treasury.{TreasuryDatum}
use bifrost/utils
use cardano/address.{Script}
use cardano/assets.{PolicyId, Value, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, find_input,
}

const registration_root_key = "reg-root"

const registration_node_key_prefix = ""

const registration_node_key_prefix_length = 0

const registration_domain_separator = "bifrost-spo"

const revocation_domain_separator = "bifrost-revoke"

fn registration_message(
  pool_id: ByteArray,
  bifrost_id_pk: ByteArray,
  bifrost_url: ByteArray,
) -> ByteArray {
  bytearray.concat(
    registration_domain_separator,
    bytearray.concat(pool_id, bytearray.concat(bifrost_id_pk, bifrost_url)),
  )
}

fn revocation_message(pool_id: ByteArray) -> ByteArray {
  bytearray.concat(revocation_domain_separator, pool_id)
}

fn get_treasury_datum(output: Output) -> TreasuryDatum {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: TreasuryDatum = raw_datum
  datum
}

fn get_registration_node_data(output: Output) -> RegistrationNodeData {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: RegistrationListDatum = raw_datum
  when datum.data is {
    linked_list.Node { data } -> data
    linked_list.Root { .. } -> fail @"Registration output must be a node"
  }
}

fn validate_registration_anchor_data(
  anchor_key: Option<ByteArray>,
  anchor_data: Data,
) -> Bool {
  when anchor_key is {
    None -> {
      expect _: ListRootData = anchor_data
      True
    }
    Some(_) -> {
      expect _: RegistrationNodeData = anchor_data
      True
    }
  }
}

fn validate_root_data(_root_lovelace: Int, root_data: Data) -> Bool {
  validate_registration_anchor_data(None, root_data)
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

fn updated_treasury_datum(
  treasury_input_datum: TreasuryDatum,
  new_bifrost_identity_root: ByteArray,
) -> TreasuryDatum {
  TreasuryDatum {
    bifrost_identity_root: new_bifrost_identity_root,
    current_treasury_address: treasury_input_datum.current_treasury_address,
    current_treasury_utxo_id: treasury_input_datum.current_treasury_utxo_id,
    current_spos_frost_key: treasury_input_datum.current_spos_frost_key,
  }
}

fn treasury_state_transition_ok(
  self: Transaction,
  treasury_input_index: Int,
  treasury_output_index: Int,
  new_bifrost_identity_root: ByteArray,
) -> Bool {
  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_output = utils.safe_list_at(self.outputs, treasury_output_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)
  let treasury_output_datum = get_treasury_datum(treasury_output)

  treasury_output_datum == updated_treasury_datum(
    treasury_input_datum,
    new_bifrost_identity_root,
  )
}

fn validate_bootstrap(
  self: Transaction,
  policy_id: PolicyId,
  bootstrap_ref: OutputReference,
) -> Bool {
  expect Some(_bootstrap_input) = find_input(self.inputs, bootstrap_ref)

  and {
    utils.quantity_of_policy_id(self.mint, policy_id) == 1,
    quantity_of(self.mint, policy_id, registration_root_key) == 1,
    validate_bootstrap_root(
      self.outputs,
      self.mint,
      policy_id,
      registration_root_key,
    ),
  }
}

fn validate_registration(
  redeemer: SposRegistryMintRedeemer,
  policy_id: PolicyId,
  self: Transaction,
) -> Bool {
  expect SposRegistryMintRedeemer.Register {
    cold_vkey,
    cold_sig,
    bifrost_sig,
    registration_anchor_input_index,
    registration_anchor_output_index,
    treasury_input_index,
    treasury_output_index,
    bifrost_identity_absence_proof,
  } = redeemer

  expect Pair(pool_id, 1) =
    utils.get_singleton_asset_with_policy(self.mint, policy_id)

  let anchor_input =
    utils.safe_list_at(self.inputs, registration_anchor_input_index)
  let continued_anchor_output =
    utils.safe_list_at(self.outputs, registration_anchor_output_index)
  let new_registration_output =
    utils.find_singleton_asset_output_at_script(
      self.outputs,
      policy_id,
      policy_id,
      pool_id,
    )
  let RegistrationNodeData { bifrost_id_pk, bifrost_url } =
    get_registration_node_data(new_registration_output)

  let registration_linked_list_ok =
    linked_list.insert_ascending(
      anchor_input,
      continued_anchor_output,
      new_registration_output,
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
        expect parsed_new_node_data: RegistrationNodeData = new_node_data

        let message =
          registration_message(
            new_node_key,
            parsed_new_node_data.bifrost_id_pk,
            parsed_new_node_data.bifrost_url,
          )

        and {
          validate_registration_anchor_data(anchor_key, anchor_data),
          anchor_lovelace_change == 0,
          new_node_key == pool_id,
          parsed_new_node_data == RegistrationNodeData {
            bifrost_id_pk,
            bifrost_url,
          },
          crypto.blake2b_224(cold_vkey) == new_node_key,
          crypto.verify_ed25519_signature(cold_vkey, message, cold_sig),
          crypto.verify_schnorr_signature(
            bifrost_id_pk,
            crypto.sha2_256(message),
            bifrost_sig,
          ),
        }
      },
    )
      |> linked_list.run_eval_with(
          policy_id,
          registration_root_key,
          registration_node_key_prefix,
          registration_node_key_prefix_length,
        )

  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)

  let updated_bifrost_identity_root =
    mpf.insert(
      mpf.from_root(treasury_input_datum.bifrost_identity_root),
      bifrost_id_pk,
      pool_id,
      bifrost_identity_absence_proof,
    )
      |> mpf.root

  and {
    registration_linked_list_ok,
    treasury_state_transition_ok(
      self,
      treasury_input_index,
      treasury_output_index,
      updated_bifrost_identity_root,
    ),
  }
}

fn validate_deregistration(
  redeemer: SposRegistryMintRedeemer,
  policy_id: PolicyId,
  self: Transaction,
) -> Bool {
  expect SposRegistryMintRedeemer.Deregister {
    cold_vkey,
    cold_sig,
    registration_input_index,
    registration_anchor_input_index,
    registration_anchor_output_index,
    treasury_input_index,
    treasury_output_index,
    bifrost_identity_removal_proof,
  } = redeemer

  expect Pair(pool_id, -1) =
    utils.get_singleton_asset_with_policy(self.mint, policy_id)

  let registration_input =
    utils.safe_list_at(self.inputs, registration_input_index)
  let registration_anchor_input =
    utils.safe_list_at(self.inputs, registration_anchor_input_index)
  let continued_anchor_output =
    utils.safe_list_at(self.outputs, registration_anchor_output_index)
  let RegistrationNodeData { bifrost_id_pk, bifrost_url: _bifrost_url } =
    get_registration_node_data(registration_input.output)

  let deregistration_linked_list_ok =
    linked_list.remove(
      registration_anchor_input,
      registration_input,
      continued_anchor_output,
      self.mint,
      fn(
        anchor_lovelace_change,
        anchor_key,
        anchor_data,
        _removed_node_lovelace,
        removed_node_key,
        removed_node_data,
        _removed_node_link,
      ) {
        expect parsed_removed_node_data: RegistrationNodeData =
          removed_node_data
        let message = revocation_message(removed_node_key)

        and {
          validate_registration_anchor_data(anchor_key, anchor_data),
          anchor_lovelace_change == 0,
          removed_node_key == pool_id,
          parsed_removed_node_data.bifrost_id_pk == bifrost_id_pk,
          crypto.blake2b_224(cold_vkey) == removed_node_key,
          crypto.verify_ed25519_signature(cold_vkey, message, cold_sig),
        }
      },
    )
      |> linked_list.run_eval_with(
          policy_id,
          registration_root_key,
          registration_node_key_prefix,
          registration_node_key_prefix_length,
        )

  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)

  let updated_bifrost_identity_root =
    mpf.delete(
      mpf.from_root(treasury_input_datum.bifrost_identity_root),
      bifrost_id_pk,
      pool_id,
      bifrost_identity_removal_proof,
    )
      |> mpf.root

  and {
    deregistration_linked_list_ok,
    treasury_state_transition_ok(
      self,
      treasury_input_index,
      treasury_output_index,
      updated_bifrost_identity_root,
    ),
  }
}

validator spo_registry(bootstrap_tx_id: ByteArray, bootstrap_output_index: Int) {
  mint(
    redeemer: SposRegistryMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    let bootstrap_ref = OutputReference(bootstrap_tx_id, bootstrap_output_index)

    when redeemer is {
      SposRegistryMintRedeemer.Bootstrap ->
        validate_bootstrap(self, policy_id, bootstrap_ref)
      SposRegistryMintRedeemer.Register { .. } ->
        validate_registration(redeemer, policy_id, self)
      SposRegistryMintRedeemer.Deregister { .. } ->
        validate_deregistration(redeemer, policy_id, self)
    }
  }

  spend(
    _datum: Option<Data>,
    _redeemer: SposRegistrySpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential

    utils.quantity_of_policy_id(self.mint, own_hash) != 0
  }

  else(_ctx: ScriptContext) {
    False
  }
}
