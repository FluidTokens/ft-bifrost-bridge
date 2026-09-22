use aiken/builtin
use bifrost/types/general.{AuthorizationMethod, CardanoSignature}
use bifrost/utils.{safe_list_at}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference}

pub type ConfigSpendRedeemer {
  Update
  Retire
}

//The Config datum (spec §Config datum): thirteen fields in rev 5.5, fourteen
//since rev 5.6 appended `previous_spos_registry_policy_id`. update_auth comes
//first, because it is the field that governs every other one.
//
//Two rules decide where a field goes.
//
//spec [CFG-6]: an identity or a key is a TOP-LEVEL field; a tunable number
//lives inside `params`. That is why `y_federation` (a key) sits at index 11
//while `federation_csv_blocks` (a block count) sits inside `params`.
//
//spec [CFG-5]: a new field is APPENDED at the tail, never inserted, and
//`params` sits at index 1 and never moves. The rev-5.4 layout put `params`
//last and told the reader to append after it, which invites exactly the edit
//that breaks every index: insert before `params` to keep it last. At index 1
//there is no "last" property left to preserve.
//
//Removed in rev 5.5:
//- treasury_info_asset_name: the Treasury state NFT name is the "BFRTRY"
//  constant in bifrost/constants, so the field had nothing left to say.
//
//Removed earlier, from the rev-5.1 layout:
//- bridged_token_asset_name: now the [CFG-1] constant "fSAT".
//- peg_in_close_verifier_script_hash: the SPI trie removes the close
//  verifier for good; both close reasons become MPF proofs in peg-in.ak.
//- both legit_treasury_movement_* hashes: vestigial.
//- min_stake, leader_reward: no on-chain reader.
//- initial_btc_treasury_utxo: [BSS-4] takes the anchor from the bootstrap
//  redeemer.
pub type ConfigDatum {
  //Authority allowed to Update/Retire the config UTxO. None = frozen.
  update_auth: Option<AuthorizationMethod>,
  //Every value with no on-chain reader. Index 1, and frozen there.
  params: ConfigParams,
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
  //-- Federation identity. Published rather than derived, and that is the whole
  //-- point. Every value an SPO would otherwise hand-copy to locate these is an
  //-- INPUT to the policy id it identifies, so no node can derive the address
  //-- it would read them from — and one wrong input yields a well-formed
  //-- address holding NOTHING rather than an error. Since the eligible DKG
  //-- roster is the registry MINUS active bans, either half of that silently
  //-- splits the roster with nothing in any node's log.
  //The DEPLOYED spo_bans policy id; the ban script address follows from it.
  spo_bans_policy_id: PolicyId,
  //The DEPLOYED spos_registry policy id. spec [PRE-4]: treasury.ak reads this
  //to gate its RegistryUpdate branch, so this field has an on-chain reader for
  //the first time. treasury.ak cannot take it as a parameter without
  //recreating the dependency cycle that made the registry-side pin impossible.
  spos_registry_policy_id: PolicyId,
  //The DEPLOYED treasury_info policy id. Off-chain discovery only: the pin is a
  //compile parameter of spos_registry, not this field.
  treasury_info_policy_id: PolicyId,
  //The federation fallback key (script-leaf key of both Taproot trees). Moved
  //here from TreasuryDatum in rev 5.5: nothing rotated it there, and here an
  //ordinary Config Update rotates it, which is the federation-key rotation the
  //field-permission matrix always promised. spec [UY-5] reads it on-chain.
  y_federation: ByteArray,
  //The one-shot outpoint every federation script is compile-parameterized by:
  //spos_registry, spo_bans and the three DKG fault verifiers all take it, so
  //the three policy ids above are FUNCTIONS of this value.
  //
  //It finishes the argument the federation block above makes. Those fields
  //publish the policy ids so no node hand-copies the INPUTS that produce them —
  //but rebuilding a script still needs those inputs, and a hash cannot be
  //inverted back to them. An operator who only READS the bridge is served by the
  //ids; anyone who must PRODUCE script bytes — deploying a reference script, or
  //spending treasury_info, which is embedded rather than referenced — was still
  //copying this outpoint out of the deployer's terminal. Published here that
  //copy disappears, and a node either derives bytes matching the ids above or
  //fails loudly against them.
  //
  //NO on-chain reader; off-chain build input, published for the same reason
  //tm_script_hash is. The UTxO itself was consumed at genesis and is long gone —
  //only its identity matters, and only as a compile parameter.
  federation_one_shot: OutputReference,
  //spec [CFG-10]: the registry policy a migration is FROM — zero-length when
  //none is in progress. The governance Update that moves #9 sets this to the
  //value #9 held, and while it is set `spos-registry.ak`'s Migrate branch will
  //carry a registration across from that policy ([MIG-1]).
  //
  //On chain rather than compiled in, for the reason the block above gives about
  //every other id here: a compile parameter naming the previous registry would
  //make each revision's script hash a function of the last one's, and heimdall
  //cannot recover a parameter from script bytes. This is also the whole of how
  //the SPO program knows a migration is in progress: the node is absent from
  //the list #9 names and present in the list this one names.
  previous_spos_registry_policy_id: PolicyId,
}

//Every value with no on-chain reader (spec [CFG-6]). Governance replaces the
//record wholesale. `schedule` sits at index 0 and never moves, for the same
//reason `params` sits at index 1.
pub type ConfigParams {
  //Epoch/TM schedule.
  schedule: ScheduleParams,
  //Exact miner fee rate (sat/vB) for deterministic TM construction.
  fee_rate_sat_per_vb: Int,
  //Floor (satoshi) for the per-peg-out protocol fee; the effective fee pins
  //into each PegOutDatum at lock time.
  per_pegout_fee: Int,
  //Minimum bridged-token amount (satoshi) a PegOut may lock.
  min_peg_out_fbtc: Int,
  //Ban schedule, mirroring what spo_bans was parameterized with. Read by the
  //ApplyBan builder, which computes a ban's end time from the first two and
  //bounds its validity interval by the third.
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
  max_validity_window_ms: Int,
  //The CSV timeout baked into the federation Taproot leaves. A block count, so
  //[CFG-6] puts it here and not next to y_federation.
  federation_csv_blocks: Int,
  //The CSV timeout of the peg-in tree's DEPOSITOR REFUND leaf, appended per
  //[CFG-5]. It sits beside federation_csv_blocks because the two do the same
  //job: both are block counts hashed into the peg-in Taproot, so both decide
  //the deposit ADDRESS.
  //
  //Published because it must be UNANIMOUS ([CFG-9]). It was the last of the
  //peg-in tree's four inputs left to each operator's own config, and the
  //failure was silent: two SPOs on different values reconstruct different
  //addresses from the same PegInRequest, freeze different peg-in sets, build
  //different Treasury Movements, and never reach a signing threshold — with
  //nothing in any log naming the cause. A default made it worse, since a node
  //that simply never set the key diverged from one that did.
  //
  //Constraint, checked by every deriver rather than assumed: this must EXCEED
  //federation_csv_blocks, so the federation's recovery window opens before the
  //depositor can take the deposit back.
  pegin_refund_timeout_blocks: Int,
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

//The nested params record (ConfigDatum field 1) as its raw fields list.
//Indexes inside it live only in the getters below.
fn get_params_fields(config_fields: List<Data>) -> List<Data> {
  builtin.unconstr_fields(safe_list_at(config_fields, 1))
}

pub fn get_bridged_token_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 2))
}

pub fn get_completed_peg_ins_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 3))
}

pub fn get_bridge_state_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 4))
}

//spec [CFG-2]: NO on-chain reader. Off-chain/test use only; it exists so the
//config_getters_match_datum_fields test pins index 5, and so an off-chain
//Aiken consumer never hard-codes the index.
pub fn get_tm_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 5))
}

pub fn get_peg_in_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 6))
}

pub fn get_peg_out_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 7))
}

pub fn get_spo_bans_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 8))
}

//spec [PRE-4]: read on-chain by treasury.ak's RegistryUpdate branch.
pub fn get_spos_registry_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 9))
}

pub fn get_treasury_info_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 10))
}

//spec [UY-5]: read on-chain by treasury.ak's UpdateY branch, which accepts a
//BIP340 signature under this key as the federation's standing co-authority.
pub fn get_y_federation(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 11))
}

//The federation one-shot outpoint. NO on-chain reader; it exists so an
//off-chain consumer reads the index from here rather than hard-coding 12, and
//so config_getters_match_datum_fields pins it.
pub fn get_federation_one_shot(config_fields: List<Data>) -> OutputReference {
  expect one_shot: OutputReference = safe_list_at(config_fields, 12)
  one_shot
}

//spec [MIG-1]: read on-chain by `spos-registry.ak`'s Migrate branch, and
//off-chain by the SPO program to classify its own membership. Zero-length means
//no migration is in progress, which the Migrate branch rejects.
pub fn get_previous_spos_registry_policy_id(
  config_fields: List<Data>,
) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 13))
}

//Off-chain/test use only. Unlike the other getters this is a FULL cast of
//the nested record, so any on-chain reader adopting it would freeze
//ScheduleParams' inner shape (defeating the point of nesting it). No Aiken
//validator reads the schedule; keep it that way.
pub fn get_schedule(config_fields: List<Data>) -> ScheduleParams {
  expect schedule: ScheduleParams =
    safe_list_at(get_params_fields(config_fields), 0)
  schedule
}

pub fn get_fee_rate_sat_per_vb(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 1))
}

pub fn get_per_pegout_fee(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 2))
}

pub fn get_min_peg_out_fbtc(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 3))
}

pub fn get_base_ban_duration_ms(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 4))
}

pub fn get_max_faults_before_permanent(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 5))
}

pub fn get_max_validity_window_ms(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 6))
}

pub fn get_federation_csv_blocks(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 7))
}

pub fn get_pegin_refund_timeout_blocks(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 8))
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
      schedule,
      fee_rate_sat_per_vb: 21,
      per_pegout_fee: 22,
      min_peg_out_fbtc: 23,
      base_ban_duration_ms: 24,
      max_faults_before_permanent: 25,
      max_validity_window_ms: 26,
      federation_csv_blocks: 27,
      pegin_refund_timeout_blocks: 28,
    }
  let datum =
    ConfigDatum {
      update_auth: Some(CardanoSignature { hash: #"aa00" }),
      params,
      bridged_token_policy: #"aa02",
      completed_peg_ins_policy: #"aa03",
      bridge_state_policy: #"aa04",
      tm_script_hash: #"aa05",
      peg_in_script_hash: #"aa06",
      peg_out_script_hash: #"aa07",
      spo_bans_policy_id: #"aa08",
      spos_registry_policy_id: #"aa09",
      treasury_info_policy_id: #"aa10",
      y_federation: #"aa11",
      federation_one_shot: OutputReference(#"aa12", 12),
      previous_spos_registry_policy_id: #"aa13",
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  and {
    //index 0
    get_update_auth(fields) == datum.update_auth,
    //index 2
    get_bridged_token_policy(fields) == datum.bridged_token_policy,
    //index 3
    get_completed_peg_ins_policy(fields) == datum.completed_peg_ins_policy,
    //index 4
    get_bridge_state_policy(fields) == datum.bridge_state_policy,
    //index 5, spec [CFG-2]
    get_tm_script_hash(fields) == datum.tm_script_hash,
    //index 6
    get_peg_in_script_hash(fields) == datum.peg_in_script_hash,
    //index 7
    get_peg_out_script_hash(fields) == datum.peg_out_script_hash,
    //index 8
    get_spo_bans_policy_id(fields) == datum.spo_bans_policy_id,
    //index 9, spec [PRE-4]
    get_spos_registry_policy_id(fields) == datum.spos_registry_policy_id,
    //index 10
    get_treasury_info_policy_id(fields) == datum.treasury_info_policy_id,
    //index 11, spec [UY-5]
    get_y_federation(fields) == datum.y_federation,
    //index 12
    get_federation_one_shot(fields) == datum.federation_one_shot,
    //index 13, spec [CFG-10]/[MIG-1]
    get_previous_spos_registry_policy_id(fields) == datum.previous_spos_registry_policy_id,
    //index 1, the nested params record
    get_schedule(fields) == params.schedule,
    get_fee_rate_sat_per_vb(fields) == params.fee_rate_sat_per_vb,
    get_per_pegout_fee(fields) == params.per_pegout_fee,
    get_min_peg_out_fbtc(fields) == params.min_peg_out_fbtc,
    get_base_ban_duration_ms(fields) == params.base_ban_duration_ms,
    get_max_faults_before_permanent(fields) == params.max_faults_before_permanent,
    get_max_validity_window_ms(fields) == params.max_validity_window_ms,
    get_federation_csv_blocks(fields) == params.federation_csv_blocks,
    get_pegin_refund_timeout_blocks(fields) == params.pegin_refund_timeout_blocks,
  }
}
