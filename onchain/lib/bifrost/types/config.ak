use cardano/address.{Credential}
use cardano/assets.{AssetName, PolicyId, quantity_of, tokens}

pub type ConfigDatum {
  bridged_token_policy_id: PolicyId,
  bridged_token_asset_name: AssetName,
  source_chain_merkle_tree_policy_id: PolicyId,
  source_chain_merkle_tree_asset_name: AssetName,
  block_header_merkle_tree_policy_id: PolicyId,
  block_header_merkle_tree_asset_name: AssetName,
  completed_peg_ins_merkle_tree_policy_id: PolicyId,
  completed_peg_ins_merkle_tree_asset_name: AssetName,
  completed_peg_outs_merkle_tree_policy_id: PolicyId,
  completed_peg_outs_merkle_tree_asset_name: AssetName,
  peg_in_withdraw_script_hash: ByteArray,
  peg_out_withdraw_script_hash: ByteArray,
  legit_treasury_movement_and_peg_in_spent_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_produced_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: ByteArray,
  treasury_nft_policy_id: ByteArray,
  treasury_nft_asset_name: ByteArray,
  //Variables used offchain that must be unquestionable
  min_stake: Int,
}
