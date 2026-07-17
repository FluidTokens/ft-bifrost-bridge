use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/interval
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use aiken_design_patterns/stake_validator
use bifrost/types/spo_bans as spo_bans_types
use bifrost/types/spos_registry.{RegistrationListDatum, RegistrationNodeData}
use bifrost/utils
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, Value, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Redeemer, ScriptPurpose,
  Transaction, ValidityRange, find_input, placeholder,
}

const ban_root_key = "ban-root"

const ban_node_key_prefix = "ban/"

const ban_node_key_prefix_length = 4

fn ban_node_asset_name(pool_id: ByteArray) -> ByteArray {
  bytearray.concat(ban_node_key_prefix, pool_id)
}

fn is_pool_id(pool_id: ByteArray) -> Bool {
  bytearray.length(pool_id) == 28
}

fn is_evidence_hash(evidence_hash: ByteArray) -> Bool {
  bytearray.length(evidence_hash) == 32
}

fn fault_token_name(
  accused_pool_id: ByteArray,
  evidence_hash: ByteArray,
) -> ByteArray {
  crypto.blake2b_256(bytearray.concat(accused_pool_id, evidence_hash))
}

fn quantity_of_allowed_fault_policies(
  value: Value,
  fault_proof_policy_ids: List<PolicyId>,
) -> Int {
  list.foldl(
    fault_proof_policy_ids,
    0,
    fn(policy_id, total) {
      total + utils.quantity_of_policy_id(value, policy_id)
    },
  )
}

fn get_fault_proof_policy_id(
  input: Input,
  fault_proof_policy_ids: List<PolicyId>,
  token_name: ByteArray,
) -> PolicyId {
  expect [policy_id] = list.filter(
    fault_proof_policy_ids,
    fn(policy_id) {
      quantity_of(input.output.value, policy_id, token_name) == 1
    },
  )
  expect
    quantity_of_allowed_fault_policies(
      input.output.value,
      fault_proof_policy_ids,
    ) == 1
  policy_id
}

fn allowed_fault_policy_mint_ok(
  value: Value,
  fault_proof_policy_ids: List<PolicyId>,
  matched_policy_id: PolicyId,
) -> Bool {
  list.all(
    fault_proof_policy_ids,
    fn(policy_id) {
      let quantity = utils.quantity_of_policy_id(value, policy_id)
      if policy_id == matched_policy_id {
        quantity == -1
      } else {
        quantity == 0
      }
    },
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
  expect Pair(asset_name, 1) = utils.get_singleton_asset_with_policy(
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
  let root_output = utils.find_singleton_asset_output_at_script(
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
  expect Pair(asset_name, 1) = utils.get_singleton_asset_with_policy(
    value,
    own_hash,
  )

  asset_name == ban_root_key || bytearray.take(
    asset_name,
    ban_node_key_prefix_length,
  ) == ban_node_key_prefix
}

fn fault_proof_burn_ok(
  self: Transaction,
  fault_token_name: ByteArray,
  fault_proof_policy_id: PolicyId,
  fault_proof_policy_ids: List<PolicyId>,
) -> Bool {
  expect [Pair(burnt_fault_token_name, -1)] = dict.to_pairs(
    tokens(self.mint, fault_proof_policy_id),
  )

  and {
    burnt_fault_token_name == fault_token_name,
    allowed_fault_policy_mint_ok(
      self.mint,
      fault_proof_policy_ids,
      fault_proof_policy_id,
    ),
  }
}

fn pow2(exponent: Int) -> Int {
  if exponent <= 0 {
    1
  } else {
    2 * pow2(exponent - 1)
  }
}

fn max_int(left: Int, right: Int) -> Int {
  if left > right {
    left
  } else {
    right
  }
}

fn all_distinct(policy_ids: List<PolicyId>) -> Bool {
  when policy_ids is {
    [] -> True
    [policy_id, ..rest] -> !list.has(rest, policy_id) && all_distinct(rest)
  }
}

fn ban_config_ok(
  fault_proof_policy_ids: List<PolicyId>,
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
  max_validity_window_ms: Int,
) -> Bool {
  and {
    list.length(fault_proof_policy_ids) == 3,
    all_distinct(fault_proof_policy_ids),
    base_ban_duration_ms > 0,
    max_faults_before_permanent > 0,
    max_validity_window_ms >= 0,
  }
}

fn resolve_lower(init_lower: Int, is_inclusive: Bool) -> Int {
  if is_inclusive {
    init_lower
  } else {
    init_lower + 1
  }
}

fn resolve_upper(init_upper: Int, is_inclusive: Bool) -> Int {
  if is_inclusive {
    init_upper
  } else {
    init_upper - 1
  }
}

fn ban_start_time(
  validity_range: ValidityRange,
  max_validity_window_ms: Int,
) -> Int {
  let lower_bound_type = validity_range.lower_bound.bound_type
  let lower_is_inclusive = validity_range.lower_bound.is_inclusive
  let upper_bound_type = validity_range.upper_bound.bound_type
  let upper_is_inclusive = validity_range.upper_bound.is_inclusive

  when (lower_bound_type, upper_bound_type) is {
    (interval.Finite(init_lower), interval.Finite(init_upper)) -> {
      let lower = resolve_lower(init_lower, lower_is_inclusive)
      let upper = resolve_upper(init_upper, upper_is_inclusive)
      expect upper >= lower
      expect upper - lower <= max_validity_window_ms
      upper
    }
    _ -> fail @"Ban transaction validity interval must be finite"
  }
}

fn ban_duration(base_ban_duration_ms: Int, ban_counter: Int) -> Int {
  base_ban_duration_ms * pow2(ban_counter - 1)
}

fn first_ban_data(
  evidence_hash: ByteArray,
  start_time: Int,
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
) -> spo_bans_types.BanNodeData {
  let ban_counter = 1
  spo_bans_types.BanNodeData {
    ban_counter,
    ban_until_time: start_time + ban_duration(base_ban_duration_ms, ban_counter),
    permanent: ban_counter >= max_faults_before_permanent,
    evidence_hashes: [evidence_hash],
  }
}

fn repeated_ban_data(
  old_ban_data: spo_bans_types.BanNodeData,
  evidence_hash: ByteArray,
  start_time: Int,
  base_ban_duration_ms: Int,
) -> spo_bans_types.BanNodeData {
  let ban_counter = old_ban_data.ban_counter + 1
  spo_bans_types.BanNodeData {
    ban_counter,
    ban_until_time: max_int(old_ban_data.ban_until_time, start_time) + ban_duration(
      base_ban_duration_ms,
      ban_counter,
    ),
    permanent: False,
    evidence_hashes: list.push(old_ban_data.evidence_hashes, evidence_hash),
  }
}

fn first_ban_transition_ok(
  self: Transaction,
  own_hash: PolicyId,
  pool_id: ByteArray,
  evidence_hash: ByteArray,
  ban_anchor_input_index: Int,
  ban_anchor_output_index: Int,
  ban_node_output_index: Int,
  start_time: Int,
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
) -> Bool {
  let ban_anchor_input = utils.safe_list_at(self.inputs, ban_anchor_input_index)
  let continued_ban_anchor_output = utils.safe_list_at(
    self.outputs,
    ban_anchor_output_index,
  )
  let new_ban_node_output = utils.safe_list_at(
    self.outputs,
    ban_node_output_index,
  )

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
        parsed_new_node_data == first_ban_data(
          evidence_hash,
          start_time,
          base_ban_duration_ms,
          max_faults_before_permanent,
        ),
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
  evidence_hash: ByteArray,
  existing_ban_input_index: Int,
  ban_node_output_index: Int,
  start_time: Int,
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
) -> Bool {
  let existing_ban_input = utils.safe_list_at(
    self.inputs,
    existing_ban_input_index,
  )

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
        old_ban_data.ban_counter < max_faults_before_permanent,
        list.length(old_ban_data.evidence_hashes) == old_ban_data.ban_counter,
        !old_ban_data.permanent,
        !list.has(old_ban_data.evidence_hashes, evidence_hash),
        new_ban_data == {
          let temporary_ban_data = repeated_ban_data(
            old_ban_data,
            evidence_hash,
            start_time,
            base_ban_duration_ms,
          )
          let is_permanent = temporary_ban_data.ban_counter >= max_faults_before_permanent
          spo_bans_types.BanNodeData {
            ..temporary_ban_data,
            permanent: is_permanent,
          }
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
  fault_proof_policy_ids: List<PolicyId>,
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
  max_validity_window_ms: Int,
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
        let ban_node_output = utils.find_singleton_asset_output_at_script(
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
    let fault_input_index = redeemer.fault_input_index
    let registration_ref_input_index = redeemer.registration_ref_input_index
    let accused_pool_id = redeemer.accused_pool_id
    let evidence_hash = redeemer.evidence_hash
    let ban_anchor_input_index = redeemer.ban_anchor_input_index
    let ban_anchor_output_index = redeemer.ban_anchor_output_index
    let existing_ban_input_index = redeemer.existing_ban_input_index
    let ban_node_output_index = redeemer.ban_node_output_index

    let registration_ref_input = utils.safe_list_at(
      self.reference_inputs,
      registration_ref_input_index,
    )
    let fault_input = utils.safe_list_at(self.inputs, fault_input_index)
    let fault_asset_name = fault_token_name(accused_pool_id, evidence_hash)
    let fault_proof_policy_id = get_fault_proof_policy_id(
      fault_input,
      fault_proof_policy_ids,
      fault_asset_name,
    )
    let start_time = ban_start_time(self.validity_range, max_validity_window_ms)

    when existing_ban_input_index is {
      Some(index) -> and {
          ban_config_ok(
            fault_proof_policy_ids,
            base_ban_duration_ms,
            max_faults_before_permanent,
            max_validity_window_ms,
          ),
          is_pool_id(accused_pool_id),
          is_evidence_hash(evidence_hash),
          validate_registered_pool_ref(
            registration_ref_input,
            registration_script_hash,
            accused_pool_id,
          ),
          fault_proof_burn_ok(
            self,
            fault_asset_name,
            fault_proof_policy_id,
            fault_proof_policy_ids,
          ),
          utils.quantity_of_policy_id(self.mint, own_hash) == 0,
          repeated_ban_transition_ok(
            self,
            own_hash,
            accused_pool_id,
            evidence_hash,
            index,
            ban_node_output_index,
            start_time,
            base_ban_duration_ms,
            max_faults_before_permanent,
          ),
        }
      None -> {
        let token_name = ban_node_asset_name(accused_pool_id)

        and {
          ban_config_ok(
            fault_proof_policy_ids,
            base_ban_duration_ms,
            max_faults_before_permanent,
            max_validity_window_ms,
          ),
          is_pool_id(accused_pool_id),
          is_evidence_hash(evidence_hash),
          validate_registered_pool_ref(
            registration_ref_input,
            registration_script_hash,
            accused_pool_id,
          ),
          fault_proof_burn_ok(
            self,
            fault_asset_name,
            fault_proof_policy_id,
            fault_proof_policy_ids,
          ),
          quantity_of(self.mint, own_hash, token_name) == 1,
          first_ban_transition_ok(
            self,
            own_hash,
            accused_pool_id,
            evidence_hash,
            ban_anchor_input_index,
            ban_anchor_output_index,
            ban_node_output_index,
            start_time,
            base_ban_duration_ms,
            max_faults_before_permanent,
          ),
        }
      }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_registration_policy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const t_bans_policy: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

const t_fault_policy_1: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_fault_policy_2: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const t_fault_policy_3: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const t_disallowed_fault_policy: ByteArray =
  #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

const t_pool_id: ByteArray =
  #"01010101010101010101010101010101010101010101010101010101"

const t_other_pool_id: ByteArray =
  #"02020202020202020202020202020202020202020202020202020202"

const t_bifrost_id_pk: ByteArray =
  #"0303030303030303030303030303030303030303030303030303030303030303"

const t_evidence_hash: ByteArray =
  #"0404040404040404040404040404040404040404040404040404040404040404"

const t_old_evidence_hash: ByteArray =
  #"0505050505050505050505050505050505050505050505050505050505050505"

const t_extra_evidence_hash: ByteArray =
  #"0606060606060606060606060606060606060606060606060606060606060606"

const t_base_ban_duration_ms: Int = 10_000

const t_max_faults_before_permanent: Int = 3

const t_max_validity_window_ms: Int = 1_000

const t_ban_start_time: Int = 1_100

const t_old_ban_until_time: Int = 15_000

fn t_fault_policy_ids() -> List<PolicyId> {
  [t_fault_policy_1, t_fault_policy_2, t_fault_policy_3]
}

fn t_ref(index: Int) -> OutputReference {
  OutputReference(
    #"1111111111111111111111111111111111111111111111111111111111111111",
    index,
  )
}

fn t_address(policy_id: PolicyId) -> Address {
  Address { payment_credential: Script(policy_id), stake_credential: None }
}

fn t_root_datum(link: Option<ByteArray>) -> spo_bans_types.BanListDatum {
  linked_list.Element {
    data: linked_list.Root { data: spo_bans_types.BanListRootData },
    link,
  }
}

fn t_node_datum(
  data: spo_bans_types.BanNodeData,
  link: Option<ByteArray>,
) -> spo_bans_types.BanListDatum {
  linked_list.Element { data: linked_list.Node { data }, link }
}

fn t_ban_root_input(link: Option<ByteArray>) -> Input {
  Input {
    output_reference: t_ref(10),
    output: Output {
      address: t_address(t_bans_policy),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_bans_policy, ban_root_key, 1),
      datum: InlineDatum(t_root_datum(link)),
      reference_script: None,
    },
  }
}

fn t_ban_root_output(link: Option<ByteArray>) -> Output {
  Output {
    address: t_address(t_bans_policy),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_bans_policy, ban_root_key, 1),
    datum: InlineDatum(t_root_datum(link)),
    reference_script: None,
  }
}

fn t_ban_node_input(
  pool_id: ByteArray,
  data: spo_bans_types.BanNodeData,
  link: Option<ByteArray>,
) -> Input {
  Input {
    output_reference: t_ref(11),
    output: Output {
      address: t_address(t_bans_policy),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_bans_policy, ban_node_asset_name(pool_id), 1),
      datum: InlineDatum(t_node_datum(data, link)),
      reference_script: None,
    },
  }
}

fn t_ban_node_output(
  pool_id: ByteArray,
  data: spo_bans_types.BanNodeData,
  link: Option<ByteArray>,
) -> Output {
  Output {
    address: t_address(t_bans_policy),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_bans_policy, ban_node_asset_name(pool_id), 1),
    datum: InlineDatum(t_node_datum(data, link)),
    reference_script: None,
  }
}

fn t_registration_input(pool_id: ByteArray) -> Input {
  let datum: RegistrationListDatum = linked_list.Element {
    data: linked_list.Node {
      data: RegistrationNodeData {
        bifrost_id_pk: t_bifrost_id_pk,
        bifrost_url: "",
      },
    },
    link: None,
  }

  Input {
    output_reference: t_ref(12),
    output: Output {
      address: t_address(t_registration_policy),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_registration_policy, pool_id, 1),
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

fn t_fault_input(
  policy_id: PolicyId,
  pool_id: ByteArray,
  evidence_hash: ByteArray,
) -> Input {
  Input {
    output_reference: t_ref(13),
    output: Output {
      address: t_address(
        #"999999999999999999999999999999999999999999999999999999",
      ),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(policy_id, fault_token_name(pool_id, evidence_hash), 1),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn t_old_ban_data() -> spo_bans_types.BanNodeData {
  spo_bans_types.BanNodeData {
    ban_counter: 1,
    ban_until_time: t_old_ban_until_time,
    permanent: False,
    evidence_hashes: [t_old_evidence_hash],
  }
}

fn t_expected_first_ban_data() -> spo_bans_types.BanNodeData {
  first_ban_data(
    t_evidence_hash,
    t_ban_start_time,
    t_base_ban_duration_ms,
    t_max_faults_before_permanent,
  )
}

fn t_expected_repeated_ban_data(
  evidence_hash: ByteArray,
) -> spo_bans_types.BanNodeData {
  spo_bans_types.BanNodeData {
    ban_counter: 2,
    ban_until_time: t_old_ban_until_time + 2 * t_base_ban_duration_ms,
    permanent: False,
    evidence_hashes: [evidence_hash, t_old_evidence_hash],
  }
}

fn t_first_ban_redeemer(
  evidence_hash: ByteArray,
) -> spo_bans_types.SpoBansWithdrawRedeemer {
  spo_bans_types.ApplyBan {
    fault_input_index: 0,
    registration_ref_input_index: 0,
    accused_pool_id: t_pool_id,
    evidence_hash,
    ban_anchor_input_index: 1,
    ban_anchor_output_index: 0,
    existing_ban_input_index: None,
    ban_node_output_index: 1,
  }
}

fn t_repeated_ban_redeemer(
  evidence_hash: ByteArray,
) -> spo_bans_types.SpoBansWithdrawRedeemer {
  spo_bans_types.ApplyBan {
    fault_input_index: 0,
    registration_ref_input_index: 0,
    accused_pool_id: t_pool_id,
    evidence_hash,
    ban_anchor_input_index: 0,
    ban_anchor_output_index: 0,
    existing_ban_input_index: Some(1),
    ban_node_output_index: 0,
  }
}

fn t_apply_ban_tx(
  inputs: List<Input>,
  reference_inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs,
    reference_inputs,
    outputs,
    mint,
    validity_range: interval.between(1_000, t_ban_start_time),
  }
}

fn t_first_ban_tx() -> Transaction {
  t_apply_ban_tx(
    [
      t_fault_input(t_fault_policy_1, t_pool_id, t_evidence_hash),
      t_ban_root_input(None),
    ],
    [t_registration_input(t_pool_id)],
    [
      t_ban_root_output(Some(t_pool_id)),
      t_ban_node_output(t_pool_id, t_expected_first_ban_data(), None),
    ],
    assets.from_asset(
      t_fault_policy_1,
      fault_token_name(t_pool_id, t_evidence_hash),
      -1,
    )
      |> assets.add(t_bans_policy, ban_node_asset_name(t_pool_id), 1),
  )
}

fn t_repeated_ban_tx(evidence_hash: ByteArray) -> Transaction {
  t_apply_ban_tx(
    [
      t_fault_input(t_fault_policy_2, t_pool_id, evidence_hash),
      t_ban_node_input(t_pool_id, t_old_ban_data(), None),
    ],
    [t_registration_input(t_pool_id)],
    [
      t_ban_node_output(
        t_pool_id,
        t_expected_repeated_ban_data(evidence_hash),
        None,
      ),
    ],
    assets.from_asset(
      t_fault_policy_2,
      fault_token_name(t_pool_id, evidence_hash),
      -1,
    ),
  )
}

fn t_apply_ban(
  redeemer: spo_bans_types.SpoBansWithdrawRedeemer,
  tx: Transaction,
) -> Bool {
  spo_bans.withdraw(
    t_registration_policy,
    t_fault_policy_ids(),
    t_base_ban_duration_ms,
    t_max_faults_before_permanent,
    t_max_validity_window_ms,
    #"0000000000000000000000000000000000000000000000000000000000000000",
    0,
    redeemer,
    Script(t_bans_policy),
    tx,
  )
}

test apply_ban_accepts_first_ban() {
  let tx = t_first_ban_tx()

  first_ban_transition_ok(
    tx,
    t_bans_policy,
    t_pool_id,
    t_evidence_hash,
    1,
    0,
    1,
    t_ban_start_time,
    t_base_ban_duration_ms,
    t_max_faults_before_permanent,
  )
}

test apply_ban_accepts_repeated_ban_with_new_evidence() {
  let tx = t_repeated_ban_tx(t_evidence_hash)

  repeated_ban_transition_ok(
    tx,
    t_bans_policy,
    t_pool_id,
    t_evidence_hash,
    1,
    0,
    t_ban_start_time,
    t_base_ban_duration_ms,
    t_max_faults_before_permanent,
  )
}

test apply_ban_rejects_repeated_ban_with_same_evidence() fail {
  t_apply_ban(
    t_repeated_ban_redeemer(t_old_evidence_hash),
    t_repeated_ban_tx(t_old_evidence_hash),
  )
}

test apply_ban_rejects_disallowed_fault_policy() fail {
  let tx = Transaction {
    ..t_first_ban_tx(),
    inputs: [
      t_fault_input(t_disallowed_fault_policy, t_pool_id, t_evidence_hash),
      t_ban_root_input(None),
    ],
    mint: assets.from_asset(
      t_disallowed_fault_policy,
      fault_token_name(t_pool_id, t_evidence_hash),
      -1,
    )
      |> assets.add(t_bans_policy, ban_node_asset_name(t_pool_id), 1),
  }
  t_apply_ban(t_first_ban_redeemer(t_evidence_hash), tx)
}

test apply_ban_rejects_wrong_registration_reference() fail {
  let tx = Transaction {
    ..t_first_ban_tx(),
    reference_inputs: [t_registration_input(t_other_pool_id)],
  }
  t_apply_ban(t_first_ban_redeemer(t_evidence_hash), tx)
}

test apply_ban_rejects_extra_fault_token_in_input() fail {
  let extra_fault_input = Input {
    ..t_fault_input(t_fault_policy_1, t_pool_id, t_evidence_hash),
    output: Output {
      ..t_fault_input(t_fault_policy_1, t_pool_id, t_evidence_hash).output,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_fault_policy_1,
            fault_token_name(t_pool_id, t_evidence_hash),
            1,
          )
        |> assets.add(
            t_fault_policy_1,
            fault_token_name(t_pool_id, t_extra_evidence_hash),
            1,
          ),
    },
  }
  let tx = Transaction {
    ..t_first_ban_tx(),
    inputs: [extra_fault_input, t_ban_root_input(None)],
  }
  t_apply_ban(t_first_ban_redeemer(t_evidence_hash), tx)
}

test apply_ban_rejects_extra_fault_token_burn() fail {
  let tx = Transaction {
    ..t_first_ban_tx(),
    mint: assets.from_asset(
      t_fault_policy_1,
      fault_token_name(t_pool_id, t_evidence_hash),
      -1,
    )
      |> assets.add(
          t_fault_policy_1,
          fault_token_name(t_pool_id, t_extra_evidence_hash),
          -1,
        )
      |> assets.add(t_bans_policy, ban_node_asset_name(t_pool_id), 1),
  }
  t_apply_ban(t_first_ban_redeemer(t_evidence_hash), tx)
}
