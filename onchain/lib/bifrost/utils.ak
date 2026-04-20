use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use bifrost/constants
use bifrost/types/watchtower.{OracleState}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference}

pub fn hash_output_ref(outputRef: OutputReference) -> ByteArray {
  outputRef |> builtin.serialise_data |> crypto.sha2_256
}

pub fn safe_list_at(self: List<a>, index: Int) -> a {
  expect index >= 0
  do_list_at(self, index)
}

fn do_list_at(self: List<a>, index: Int) -> a {
  if index == 0 {
    builtin.head_list(self)
  } else {
    do_list_at(builtin.tail_list(self), index - 1)
  }
}

pub fn get_config_as_data_list(
  configRefInput: Input,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  expect
    quantity_of(
      configRefInput.output.value,
      configNFTPolicyId,
      configNFTAssetName,
    ) > 0
  expect InlineDatum(outputDatum) = configRefInput.output.datum
  builtin.unconstr_fields(outputDatum)
}

pub fn is_signed_by(
  wallet_address: Address,
  tx_extra_signatories: List<ByteArray>,
) {
  expect VerificationKey(key_hash) = wallet_address.payment_credential
  list.any(tx_extra_signatories, fn(es) { es == key_hash })
}

/// Returns the quantity of all tokens with the policyId
pub fn quantity_of_policy_id(value: Value, policyId: PolicyId) {
  dict.foldl(tokens(value, policyId), 0, fn(_k, v, result) { v + result })
}

// Used to retrieve a singleton asset from a value with a specific policy id
pub fn get_singleton_asset_with_policy(
  value: Value,
  policy_id: PolicyId,
) -> Pair<AssetName, Int> {
  expect [p] =
    value
      |> assets.tokens(policy_id)
      //return dict of policy id to asset name and quantity
      |> dict.to_pairs

  p
}

pub fn find_singleton_asset_output_at_script(
  outputs: List<Output>,
  script_hash: ByteArray,
  policy_id: PolicyId,
  asset_name: AssetName,
) -> Output {
  expect Some(output) =
    list.find(
      outputs,
      fn(output) {
        output.address.payment_credential == Script(script_hash) && quantity_of(
          output.value,
          policy_id,
          asset_name,
        ) == 1
      },
    )

  output
}

pub fn get_oracle_state(
  oracle_state_ref_input: Input,
  btc_oracle_policy_id: ByteArray,
) {
  expect
    quantity_of(
      oracle_state_ref_input.output.value,
      btc_oracle_policy_id,
      constants.btc_oracle_asset_name,
    ) > 0
  expect InlineDatum(outputDatum) = oracle_state_ref_input.output.datum
  expect parsed_oracle_state: OracleState = outputDatum
  parsed_oracle_state
}

pub fn get_treasury_info_as_data_list(
  treasury_info_ref_input: Input,
  treasury_info_nft_policy_id: ByteArray,
) {
  get_config_as_data_list(
    treasury_info_ref_input,
    treasury_info_nft_policy_id,
    constants.treasury_info_nft_asset_name,
  )
}

/// Returns `True` if `predicate(index, element)` holds for every element of the list.
/// Returns `False` as soon as any predicate fails.
pub fn indexed_all(self: List<a>, predicate: fn(Int, a) -> Bool) -> Bool {
  list.indexed_foldr(
    self,
    True,
    fn(index, element, acc) { predicate(index, element) && acc },
  )
}

/// Variant of `indexed_all` that also threads a state through the predicate.
/// Processes the list from right to left.
/// Returns `True` iff every predicate call returns `True`.
/// Does not short-circuit: the predicate is still called for all elements.
pub fn indexed_all_with_state(
  self: List<a>,
  state: s,
  predicate: fn(Int, a, s) -> (Bool, s),
) -> Bool {
  let (finalResult, _finalState) =
    list.indexed_foldr(
      self,
      (True, state),
      fn(index, element, (acc, state)) {
        let (result, newState) = predicate(index, element, state)
        (result && acc, newState)
      },
    )
  finalResult
}

pub fn indexed_all_with_state_with_return_value(
  self: List<a>,
  state: s,
  predicate: fn(Int, a, s) -> (Bool, s),
) -> (Bool, s) {
  list.indexed_foldr(
    self,
    (True, state),
    fn(index, element, (acc, state)) {
      let (result, newState) = predicate(index, element, state)
      (result && acc, newState)
    },
  )
}

//Expects the merkle root to be the first field of the InlineDatum
pub fn get_mpf_from_output(output: Output) -> mpf.MerklePatriciaForestry {
  expect InlineDatum(datum) = output.datum
  datum
    |> builtin.unconstr_fields
    |> builtin.head_list
    |> builtin.un_b_data
    |> mpf.from_root
}

//Insert many successive elements in the merkle tree in one tx
pub fn mpf_multiple_inserts(
  initial_merkle_tree: mpf.MerklePatriciaForestry,
  keys_values_and_inclusion_proofs: List<(ByteArray, ByteArray, mpf.Proof)>,
) -> mpf.MerklePatriciaForestry {
  list.foldr(
    keys_values_and_inclusion_proofs,
    initial_merkle_tree,
    fn((key, value, proof), result) { mpf.insert(result, key, value, proof) },
  )
}

pub fn bitcoin_hash(bytes: ByteArray) -> ByteArray {
  crypto.sha2_256(crypto.sha2_256(bytes))
}
