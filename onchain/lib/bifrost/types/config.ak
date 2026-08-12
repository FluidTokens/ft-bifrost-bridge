use aiken/builtin
use bifrost/types/general.{AuthorizationMethod, CardanoSignature}
use bifrost/utils.{safe_list_at}
use cardano/assets.{AssetName, PolicyId}

pub type ConfigSpendRedeemer {
  Update
  Retire
}

//The rev-5.4 Config datum, seventeen fields (spec §Config datum). update_auth
//comes first, because it is the field that governs every other one.
//
//`params` is the nested record at index 14, and everything since has been
//appended AFTER it — which is what this note has asked for since rev 5.4, and
//what [LIB-3] means in practice. Every field before it is a scalar at a frozen
//index; a nested record in the middle would have to be renumbered past each
//time the datum grows, and the record never moving means no reader that
//already found it has to be rebuilt.
//
//Removed from the rev-5.1 layout (spec §Config datum, "Rev 5.1's fields ...
//are all GONE"):
//- bridged_token_asset_name: now the [CFG-1] constant "fSAT" in
//  bifrost/constants.
//- peg_in_close_verifier_script_hash: the SPI trie removes the close
//  verifier for good; both close reasons become MPF proofs in peg-in.ak.
//- both legit_treasury_movement_* hashes: vestigial, dummy on the deployed
//  instance.
//- min_stake: it was off-chain-only (the heimdall R2 registration gate had
//  no on-chain reader), so it leaves the datum with the other unread fields.
//- initial_btc_treasury_utxo: [BSS-4] takes the anchor from the bootstrap
//  redeemer.
//- leader_reward: no on-chain reader in this tree.
pub type ConfigDatum {
  //Authority allowed to Update/Retire the config UTxO. None = frozen.
  update_auth: Option<AuthorizationMethod>,
  //fBTC policy id
  bridged_token_policy: PolicyId,
  //CPI trie NFT policy
  completed_peg_ins_policy: PolicyId,
  //Bridge state singleton NFT policy
  bridge_state_policy: PolicyId,
  //spec [CFG-2]: the TM validator hash (= TM NFT policy id). NO on-chain
  //reader; published so off-chain readers can locate the TM address without
  //a build-time constant. Changing it alone does NOT swap the TM validator:
  //the singleton is compile-parameterized by this hash.
  tm_script_hash: ByteArray,
  peg_in_script_hash: ByteArray,
  peg_out_script_hash: ByteArray,
  //-- Federation identity (ban policy + SPO registry). Off-chain readers only,
  //-- like the params below; no Aiken validator reads a current value here.
  //--
  //-- Published rather than derived, and that is the whole point. Every value
  //-- an SPO would otherwise hand-copy to locate these is an INPUT to the
  //-- policy id it identifies, so no node can derive the address it would read
  //-- them from — and one wrong input yields a well-formed address holding
  //-- NOTHING rather than an error. Since the eligible DKG roster is the
  //-- registry MINUS active bans, either half of that silently splits the
  //-- roster with nothing in any node's log.
  //The DEPLOYED spo_bans policy id; the ban script address follows from it.
  spo_bans_policy_id: PolicyId,
  //Ban schedule, mirroring what spo_bans was parameterized with. Read by the
  //ApplyBan builder, which computes a ban's end time from the first two and
  //bounds its validity interval by the third. Already baked into the id above;
  //publishing them means they are read rather than typed.
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
  max_validity_window_ms: Int,
  //The DEPLOYED spos_registry policy id; the registry address follows from it.
  spos_registry_policy_id: PolicyId,
  //The DEPLOYED treasury_info policy id. Worth publishing even though it is a
  //pure function of the spos_registry policy alone (rev 5.4 dropped
  //treasury_info's TM-NFT-policy parameter with the FederationReset branch
  //that was its only reader): a reader must still apply that parameter to the
  //same blueprint, and drift yields a different hash, a different address and
  //an unfindable state UTxO rather than an error.
  treasury_info_policy_id: PolicyId,
  //Asset name of the treasury_info state NFT. Unlike every other field here it
  //is derivable from nothing at all — a name chosen at bootstrap — so
  //publishing it is the only way an SPO can avoid typing it.
  treasury_info_asset_name: AssetName,
  //Operational parameters, one nested record so governance can replace it
  //wholesale without renumbering its neighbours. The NESTING is what buys that,
  //not the position: ConfigParams' fields are indexed inside its own constr, so
  //it can grow wherever it sits. See the note above the record.
  params: ConfigParams,
  //-- Federation identity. Appended AFTER params rather than grouped with the
  //-- identity fields it belongs with, because the getter indexes are a frozen
  //-- contract and an existing Config UTxO may be migrated IN PLACE to this
  //-- shape (config's Update redeemer accepts any datum) — under a peg_out or
  //-- CPI validator that is already deployed and still reads index 14 for
  //-- params.
  //--
  //-- These two determine the Bitcoin TREASURY ADDRESS. Y_51 rotates each epoch
  //-- with the DKG and reaches every SPO over the wire, but the federation leaf
  //-- does not rotate: each SPO rebuilds the treasury Taproot tree from these,
  //-- so a node holding a different value derives a different scriptPubKey,
  //-- signs a different sighash, and produces a FROST share over a message no
  //-- other signer produced. Nothing errors — the address is well-formed, it
  //-- just is not the one holding the BTC.
  //The x-only (32-byte, BIP-340) federation public key. NOT the seed it is
  //derived from: whoever holds that seed can spend the treasury through the
  //federation leaf, and a reader only ever needs the public half to build the
  //tree. Publishing the seed would hand the treasury to anyone who can read a
  //UTxO.
  y_federation_pubkey: ByteArray,
  //Relative-timelock delay (blocks) of the federation recovery leaf. It is both
  //an input to the address above and the recovery path's timelock, so a wrong
  //value moves the treasury AND silently changes how long recovery waits.
  federation_csv_blocks: Int,
}

//The tunable operational parameters (spec §Operational parameters).
pub type ConfigParams {
  //Exact miner fee rate (sat/vB) for deterministic TM construction.
  fee_rate_sat_per_vb: Int,
  //Floor (satoshi) for the per-peg-out protocol fee; the effective fee pins
  //into each PegOutDatum at lock time.
  per_pegout_fee: Int,
  //Minimum bridged-token amount (satoshi) a PegOut may lock.
  min_peg_out_fbtc: Int,
  //Epoch/TM schedule. Off-chain readers only.
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

pub fn get_update_auth(
  config_fields: List<Data>,
) -> Option<AuthorizationMethod> {
  expect update_auth: Option<AuthorizationMethod> =
    safe_list_at(config_fields, 0)
  update_auth
}

pub fn get_bridged_token_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 1))
}

pub fn get_completed_peg_ins_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 2))
}

pub fn get_bridge_state_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 3))
}

//spec [CFG-2]: NO on-chain reader. Off-chain/test use only; it exists so the
//config_getters_match_datum_fields test pins index 4, and so an off-chain
//Aiken consumer never hard-codes the index.
pub fn get_tm_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 4))
}

pub fn get_peg_in_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 5))
}

pub fn get_peg_out_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 6))
}

pub fn get_spo_bans_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 7))
}

pub fn get_base_ban_duration_ms(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 8))
}

pub fn get_max_faults_before_permanent(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 9))
}

pub fn get_max_validity_window_ms(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 10))
}

pub fn get_spos_registry_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 11))
}

pub fn get_treasury_info_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 12))
}

pub fn get_treasury_info_asset_name(config_fields: List<Data>) -> AssetName {
  builtin.un_b_data(safe_list_at(config_fields, 13))
}

//The nested params record (ConfigDatum field 14, the last one) as its raw
//fields list. Indexes inside it live only in the getters below.
fn get_params_fields(config_fields: List<Data>) -> List<Data> {
  builtin.unconstr_fields(safe_list_at(config_fields, 14))
}

pub fn get_fee_rate_sat_per_vb(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 0))
}

pub fn get_per_pegout_fee(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 1))
}

pub fn get_min_peg_out_fbtc(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 2))
}

//Off-chain/test use only. Unlike the other getters this is a FULL cast of
//the nested record, so any on-chain reader adopting it would freeze
//ScheduleParams' inner shape (defeating the point of nesting it). No Aiken
//validator reads the schedule; keep it that way.
pub fn get_schedule(config_fields: List<Data>) -> ScheduleParams {
  expect schedule: ScheduleParams =
    safe_list_at(get_params_fields(config_fields), 3)
  schedule
}

//NO on-chain reader, like the identity fields above — Bitcoin's Taproot tree is
//not something a Cardano validator can check. Published so an SPO reads the
//treasury's federation leaf instead of typing it, and so an off-chain Aiken
//consumer never hard-codes the index.
pub fn get_y_federation_pubkey(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 15))
}

pub fn get_federation_csv_blocks(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(config_fields, 16))
}

//Pins every getter index to its ConfigDatum record field. The fixture is a
//real ConfigDatum record, serialized with builtin.unconstr_fields, and each
//getter's result is compared against the record field it must read. Every
//field carries a distinct value, so a reordering of the record definition
//relative to the getter indexes fails this test even when the swapped
//fields share a type.
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
  let params =
    ConfigParams {
      fee_rate_sat_per_vb: 12,
      per_pegout_fee: 13,
      min_peg_out_fbtc: 14,
      schedule,
    }
  let datum =
    ConfigDatum {
      update_auth: Some(CardanoSignature { hash: #"aa10" }),
      bridged_token_policy: #"aa01",
      completed_peg_ins_policy: #"aa02",
      bridge_state_policy: #"aa03",
      tm_script_hash: #"aa04",
      peg_in_script_hash: #"aa05",
      peg_out_script_hash: #"aa06",
      spo_bans_policy_id: #"aa07",
      base_ban_duration_ms: 8,
      max_faults_before_permanent: 9,
      max_validity_window_ms: 10,
      spos_registry_policy_id: #"aa11",
      treasury_info_policy_id: #"aa12",
      treasury_info_asset_name: "aa13",
      params,
      y_federation_pubkey: #"aa15",
      federation_csv_blocks: 16,
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  and {
    //index 0
    get_update_auth(fields) == datum.update_auth,
    //index 1
    get_bridged_token_policy(fields) == datum.bridged_token_policy,
    //index 2
    get_completed_peg_ins_policy(fields) == datum.completed_peg_ins_policy,
    //index 3
    get_bridge_state_policy(fields) == datum.bridge_state_policy,
    //index 4, spec [CFG-2]
    get_tm_script_hash(fields) == datum.tm_script_hash,
    //index 5
    get_peg_in_script_hash(fields) == datum.peg_in_script_hash,
    //index 6
    get_peg_out_script_hash(fields) == datum.peg_out_script_hash,
    //index 7
    get_spo_bans_policy_id(fields) == datum.spo_bans_policy_id,
    //index 8
    get_base_ban_duration_ms(fields) == datum.base_ban_duration_ms,
    //index 9
    get_max_faults_before_permanent(fields) == datum.max_faults_before_permanent,
    //index 10
    get_max_validity_window_ms(fields) == datum.max_validity_window_ms,
    //index 11
    get_spos_registry_policy_id(fields) == datum.spos_registry_policy_id,
    //index 12
    get_treasury_info_policy_id(fields) == datum.treasury_info_policy_id,
    //index 13
    get_treasury_info_asset_name(fields) == datum.treasury_info_asset_name,
    //index 14, nested params record
    get_fee_rate_sat_per_vb(fields) == params.fee_rate_sat_per_vb,
    get_per_pegout_fee(fields) == params.per_pegout_fee,
    get_min_peg_out_fbtc(fields) == params.min_peg_out_fbtc,
    get_schedule(fields) == params.schedule,
    //index 15
    get_y_federation_pubkey(fields) == datum.y_federation_pubkey,
    //index 16
    get_federation_csv_blocks(fields) == datum.federation_csv_blocks,
  }
}

//The federation fields sit AFTER the nested params record, so params' index is
//unchanged by their arrival. That is the whole reason they were appended rather
//than grouped with the identity fields they belong with: a Config UTxO migrated
//in place to this shape must still read correctly under an ALREADY-DEPLOYED
//validator compiled against the fifteen-field datum, which would otherwise find
//a ByteArray at index 14 where it expects the params constr. This test fails if
//anyone "tidies" the record by moving params back to the end.
test params_index_survives_the_federation_fields() {
  let schedule =
    ScheduleParams {
      dkg_r1_deadline: 1,
      dkg_r2_deadline: 2,
      update_y_deadline: 3,
      tm_batch_interval: 4,
      sign_r1_window: 5,
      sign_r2_window: 6,
      leader_slot_t: 7,
      tm_recovery_window: 8,
      final_tm_cutoff: 9,
      stability_window: 10,
    }
  let params =
    ConfigParams {
      fee_rate_sat_per_vb: 12,
      per_pegout_fee: 13,
      min_peg_out_fbtc: 14,
      schedule,
    }
  let datum =
    ConfigDatum {
      update_auth: None,
      bridged_token_policy: #"aa01",
      completed_peg_ins_policy: #"aa02",
      bridge_state_policy: #"aa03",
      tm_script_hash: #"aa04",
      peg_in_script_hash: #"aa05",
      peg_out_script_hash: #"aa06",
      spo_bans_policy_id: #"aa07",
      base_ban_duration_ms: 8,
      max_faults_before_permanent: 9,
      max_validity_window_ms: 10,
      spos_registry_policy_id: #"aa11",
      treasury_info_policy_id: #"aa12",
      treasury_info_asset_name: "aa13",
      params,
      y_federation_pubkey: #"aa15",
      federation_csv_blocks: 16,
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  //Read index 14 as the params constr, exactly as a validator deployed before
  //this change does.
  and {
    get_fee_rate_sat_per_vb(fields) == 12,
    get_per_pegout_fee(fields) == 13,
    get_min_peg_out_fbtc(fields) == 14,
  }
}
