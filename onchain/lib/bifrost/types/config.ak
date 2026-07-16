use aiken/builtin
use bifrost/types/general.{AuthorizationMethod, CardanoSignature}
use bifrost/utils.{safe_list_at}
use cardano/assets.{AssetName, PolicyId}

pub type ConfigSpendRedeemer {
  Update
  Retire
}

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
  //Slot vacated by the retired legit_TM_and_peg_in_spent verifier. Holds the
  //peg-in CLOSE verifier wired in via a config update (dummy hash until the
  //F1–F6 failure-mode milestone ships).
  peg_in_close_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_produced_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: ByteArray,
  treasury_nft_policy_id: ByteArray,
  treasury_nft_asset_name: ByteArray,
  //Variables used offchain that must be unquestionable
  min_stake: Int,
  //Authority allowed to update or retire the config UTxO.
  //None = permanently frozen (unspendable), the pre-governance behavior.
  update_auth: Option<AuthorizationMethod>,
  //Withdraw script carrying ALL fBTC mint/burn rules; the immutable
  //bridged_token policy only requires this script to run in the tx. Swapped
  //via an authorized config Update (see the delegated-mint design spec).
  bridged_token_mint_checker_script_hash: ByteArray,
}

//----------------------------------------------------------------------------
// Positional getters over the raw config fields list, as returned by
// utils.get_config_as_data_list. Field indexes live ONLY here.
//
// Readers deliberately do NOT cast the datum to ConfigDatum. An
// `expect datum: ConfigDatum` compiles to a full runtime shape check that
// enforces the constructor tag, the exact field count, and every field's
// type (verified by experiment on aiken v1.1.19: an appended extra field, a
// retyped field, or a changed constructor tag all make the cast fail). Since
// several readers are immutable once deployed (notably the fBTC minting
// policy), a full cast would make any future ConfigDatum shape change
// impossible without breaking them. The getters validate only the fields a
// reader actually accesses, so fields can be appended (and unread fields
// changed) without redeploying existing readers. The trade-off: existing
// field positions and types are a frozen contract; evolve the datum by
// appending only.
//
// Keep the getters in the exact order of the ConfigDatum definition above;
// the config_getters_match_datum_fields test pins each index to its record
// field.
//----------------------------------------------------------------------------

pub fn get_bridged_token_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 0))
}

pub fn get_bridged_token_asset_name(config_fields: List<Data>) -> AssetName {
  builtin.un_b_data(safe_list_at(config_fields, 1))
}

pub fn get_source_chain_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 2))
}

pub fn get_source_chain_merkle_tree_asset_name(
  config_fields: List<Data>,
) -> AssetName {
  builtin.un_b_data(safe_list_at(config_fields, 3))
}

pub fn get_block_header_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 4))
}

pub fn get_block_header_merkle_tree_asset_name(
  config_fields: List<Data>,
) -> AssetName {
  builtin.un_b_data(safe_list_at(config_fields, 5))
}

pub fn get_completed_peg_ins_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 6))
}

pub fn get_completed_peg_ins_merkle_tree_asset_name(
  config_fields: List<Data>,
) -> AssetName {
  builtin.un_b_data(safe_list_at(config_fields, 7))
}

pub fn get_completed_peg_outs_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 8))
}

pub fn get_completed_peg_outs_merkle_tree_asset_name(
  config_fields: List<Data>,
) -> AssetName {
  builtin.un_b_data(safe_list_at(config_fields, 9))
}

pub fn get_peg_in_withdraw_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 10))
}

pub fn get_peg_out_withdraw_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 11))
}

pub fn get_peg_in_close_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 12))
}

pub fn get_legit_treasury_movement_and_peg_out_produced_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 13))
}

pub fn get_legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 14))
}

pub fn get_treasury_nft_policy_id(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 15))
}

pub fn get_treasury_nft_asset_name(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 16))
}

pub fn get_min_stake(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 17))
}

pub fn get_update_auth(
  config_fields: List<Data>,
) -> Option<AuthorizationMethod> {
  expect update_auth: Option<AuthorizationMethod> =
    safe_list_at(config_fields, 18)
  update_auth
}

pub fn get_bridged_token_mint_checker_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 19))
}

//Pins every getter index to its ConfigDatum record field: reordering record
//fields or getter indexes independently makes this fail.
test config_getters_match_datum_fields() {
  let datum =
    ConfigDatum {
      bridged_token_policy_id: #"aa00",
      bridged_token_asset_name: #"aa01",
      source_chain_merkle_tree_policy_id: #"aa02",
      source_chain_merkle_tree_asset_name: #"aa03",
      block_header_merkle_tree_policy_id: #"aa04",
      block_header_merkle_tree_asset_name: #"aa05",
      completed_peg_ins_merkle_tree_policy_id: #"aa06",
      completed_peg_ins_merkle_tree_asset_name: #"aa07",
      completed_peg_outs_merkle_tree_policy_id: #"aa08",
      completed_peg_outs_merkle_tree_asset_name: #"aa09",
      peg_in_withdraw_script_hash: #"aa10",
      peg_out_withdraw_script_hash: #"aa11",
      peg_in_close_verifier_script_hash: #"aa12",
      legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa13",
      legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aa14",
      treasury_nft_policy_id: #"aa15",
      treasury_nft_asset_name: #"aa16",
      min_stake: 17,
      update_auth: Some(CardanoSignature { hash: #"aa18" }),
      bridged_token_mint_checker_script_hash: #"aa19",
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  and {
    get_bridged_token_policy_id(fields) == datum.bridged_token_policy_id,
    get_bridged_token_asset_name(fields) == datum.bridged_token_asset_name,
    get_source_chain_merkle_tree_policy_id(fields) == datum.source_chain_merkle_tree_policy_id,
    get_source_chain_merkle_tree_asset_name(fields) == datum.source_chain_merkle_tree_asset_name,
    get_block_header_merkle_tree_policy_id(fields) == datum.block_header_merkle_tree_policy_id,
    get_block_header_merkle_tree_asset_name(fields) == datum.block_header_merkle_tree_asset_name,
    get_completed_peg_ins_merkle_tree_policy_id(fields) == datum.completed_peg_ins_merkle_tree_policy_id,
    get_completed_peg_ins_merkle_tree_asset_name(fields) == datum.completed_peg_ins_merkle_tree_asset_name,
    get_completed_peg_outs_merkle_tree_policy_id(fields) == datum.completed_peg_outs_merkle_tree_policy_id,
    get_completed_peg_outs_merkle_tree_asset_name(fields) == datum.completed_peg_outs_merkle_tree_asset_name,
    get_peg_in_withdraw_script_hash(fields) == datum.peg_in_withdraw_script_hash,
    get_peg_out_withdraw_script_hash(fields) == datum.peg_out_withdraw_script_hash,
    get_peg_in_close_verifier_script_hash(fields) == datum.peg_in_close_verifier_script_hash,
    get_legit_treasury_movement_and_peg_out_produced_verifier_script_hash(
      fields,
    ) == datum.legit_treasury_movement_and_peg_out_produced_verifier_script_hash,
    get_legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash(
      fields,
    ) == datum.legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash,
    get_treasury_nft_policy_id(fields) == datum.treasury_nft_policy_id,
    get_treasury_nft_asset_name(fields) == datum.treasury_nft_asset_name,
    get_min_stake(fields) == datum.min_stake,
    get_update_auth(fields) == datum.update_auth,
    get_bridged_token_mint_checker_script_hash(fields) == datum.bridged_token_mint_checker_script_hash,
  }
}
