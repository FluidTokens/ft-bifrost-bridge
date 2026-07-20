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
  //-- Operational parameters (tunables; spec §Operational parameters). These
  //-- are OFF-CHAIN consensus anchors / pinned-copy sources / skip-rule
  //-- floors — no Aiken validator reads a current value here (the TM
  //-- validator is the Scalus contract in binocular; the leader_reward pin,
  //-- when enforced, is read there). Appended after upstream's #11 anchor.
  //Exact miner fee rate (sat/vB) for deterministic TM construction.
  fee_rate_sat_per_vb: Int,
  //Floor (satoshi) for the per-peg-out protocol fee; the effective fee pins
  //into each PegOutDatum at lock time.
  per_pegout_fee: Int,
  //Minimum bridged-token amount (satoshi) a PegOut may lock.
  min_peg_out_fbtc: Int,
  //TM poster's reward (lovelace); pinned into the TM record at post time and
  //paid by each fBTC mint that claims against the Confirmed record.
  leader_reward: Int,
  //Epoch/TM schedule (all Int slots; spec §TM batches and the protocol
  //schedule). Off-chain readers only, so it is one structured field rather
  //than ten top-level slots; governance updates replace it wholesale,
  //effective from the next epoch boundary.
  schedule: ScheduleParams,
}

//The tunable protocol schedule, E-relative slot values (spec §TM batches and
//the protocol schedule; constraints there — notably stability_window = 3k/f,
//tunable only upward). Off-chain readers only.
pub type ScheduleParams {
  dkg_r1_deadline: Int,
  dkg_r2_deadline: Int,
  update_y_deadline: Int,
  tm_batch_interval: Int,
  sign_r1_window: Int,
  sign_r2_window: Int,
  leader_slot_t: Int,
  tm_recovery_window: Int,
  final_tm_cutoff: Int,
  stability_window: Int,
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

pub fn get_fee_rate_sat_per_vb(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 12))
}

pub fn get_per_pegout_fee(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 13))
}

pub fn get_min_peg_out_fbtc(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 14))
}

pub fn get_leader_reward(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 15))
}

//Off-chain/test use only. Unlike the other getters this is a FULL cast of
//the nested record, so any on-chain reader adopting it would freeze
//ScheduleParams' inner shape (defeating the point of nesting it). No Aiken
//validator reads the schedule; keep it that way.
pub fn get_schedule(config_fields: List<Data>) -> ScheduleParams {
  expect schedule: ScheduleParams = safe_list_at(config_fields, 16)
  schedule
}

//Pins every getter index to its ConfigDatum record field: reordering record
//fields or getter indexes independently makes this fail.
test config_getters_match_datum_fields() {
  let schedule =
    ScheduleParams {
      dkg_r1_deadline: 3600,
      dkg_r2_deadline: 7200,
      update_y_deadline: 10800,
      tm_batch_interval: 21600,
      sign_r1_window: 1800,
      sign_r2_window: 1800,
      leader_slot_t: 600,
      tm_recovery_window: 129600,
      final_tm_cutoff: 345600,
      stability_window: 129600,
    }
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
      fee_rate_sat_per_vb: 12,
      per_pegout_fee: 13,
      min_peg_out_fbtc: 14,
      leader_reward: 15,
      schedule,
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
    get_fee_rate_sat_per_vb(fields) == datum.fee_rate_sat_per_vb,
    get_per_pegout_fee(fields) == datum.per_pegout_fee,
    get_min_peg_out_fbtc(fields) == datum.min_peg_out_fbtc,
    get_leader_reward(fields) == datum.leader_reward,
    get_schedule(fields) == datum.schedule,
  }
}
