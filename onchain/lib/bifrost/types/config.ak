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
  completed_peg_ins_merkle_tree_policy_id: PolicyId,
  completed_peg_outs_merkle_tree_policy_id: PolicyId,
  peg_in_withdraw_script_hash: ByteArray,
  peg_out_withdraw_script_hash: ByteArray,
  //Peg-in CLOSE verifier (F4/F5). Dormant until the F1-F6 milestone; a dummy
  //hash has no reward account, so Cancel is cleanly unsatisfiable.
  peg_in_close_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_produced_verifier_script_hash: ByteArray,
  legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: ByteArray,
  //Off-chain-only (heimdall R2 registration gate); no on-chain reader.
  min_stake: Int,
  //Authority allowed to Update/Retire the config UTxO. None = frozen.
  update_auth: Option<AuthorizationMethod>,
  //The initial (anchor) Bitcoin treasury outpoint the first Treasury Movement
  //must spend: 36 bytes = txid (internal byte order) ++ vout (4-byte LE).
  //Subsequent TMs chain from the previous Confirmed TM record instead.
  //Re-pointable via config Update (e.g. after an emergency federation sweep).
  initial_btc_treasury_utxo: ByteArray,
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

pub fn get_completed_peg_ins_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 2))
}

pub fn get_completed_peg_outs_merkle_tree_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 3))
}

pub fn get_peg_in_withdraw_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 4))
}

pub fn get_peg_out_withdraw_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 5))
}

pub fn get_peg_in_close_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 6))
}

pub fn get_legit_treasury_movement_and_peg_out_produced_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 7))
}

pub fn get_legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash(
  config_fields: List<Data>,
) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 8))
}

pub fn get_min_stake(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 9))
}

pub fn get_update_auth(
  config_fields: List<Data>,
) -> Option<AuthorizationMethod> {
  expect update_auth: Option<AuthorizationMethod> =
    safe_list_at(config_fields, 10)
  update_auth
}

pub fn get_initial_btc_treasury_utxo(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 11))
}

//Pins every getter index to its ConfigDatum record field: reordering record
//fields or getter indexes independently makes this fail.
test config_getters_match_datum_fields() {
  let datum =
    ConfigDatum {
      bridged_token_policy_id: #"aa00",
      bridged_token_asset_name: #"aa01",
      completed_peg_ins_merkle_tree_policy_id: #"aa02",
      completed_peg_outs_merkle_tree_policy_id: #"aa03",
      peg_in_withdraw_script_hash: #"aa04",
      peg_out_withdraw_script_hash: #"aa05",
      peg_in_close_verifier_script_hash: #"aa06",
      legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa07",
      legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aa08",
      min_stake: 9,
      update_auth: Some(CardanoSignature { hash: #"aa10" }),
      initial_btc_treasury_utxo: #"aa11",
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  and {
    get_bridged_token_policy_id(fields) == datum.bridged_token_policy_id,
    get_bridged_token_asset_name(fields) == datum.bridged_token_asset_name,
    get_completed_peg_ins_merkle_tree_policy_id(fields) == datum.completed_peg_ins_merkle_tree_policy_id,
    get_completed_peg_outs_merkle_tree_policy_id(fields) == datum.completed_peg_outs_merkle_tree_policy_id,
    get_peg_in_withdraw_script_hash(fields) == datum.peg_in_withdraw_script_hash,
    get_peg_out_withdraw_script_hash(fields) == datum.peg_out_withdraw_script_hash,
    get_peg_in_close_verifier_script_hash(fields) == datum.peg_in_close_verifier_script_hash,
    get_legit_treasury_movement_and_peg_out_produced_verifier_script_hash(fields) == datum.legit_treasury_movement_and_peg_out_produced_verifier_script_hash,
    get_legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash(fields) == datum.legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash,
    get_min_stake(fields) == datum.min_stake,
    get_update_auth(fields) == datum.update_auth,
    get_initial_btc_treasury_utxo(fields) == datum.initial_btc_treasury_utxo,
  }
}
