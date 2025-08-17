use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use bifrost/constants
use bifrost/types/bitcoin_oracle.{OracleState}
use cardano/address.{Address, VerificationKey}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference}

pub fn hash_output_ref(outputRef: OutputReference) -> ByteArray {
  outputRef |> builtin.serialise_data |> crypto.blake2b_224
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
