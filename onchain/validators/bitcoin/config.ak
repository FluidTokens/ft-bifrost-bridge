use aiken/builtin
use aiken/collection/list
use bifrost/authorizer
use bifrost/types/config.{
  ConfigDatum, ConfigSpendRedeemer, Retire, ScheduleParams, Update,
} as configType
use bifrost/types/general.{
  AuthorizationMethod, CardanoSignature, CardanoSpendScript,
  CardanoWithdrawScript,
}
use bifrost/utils.{quantity_of_policy_id}
use cardano/address.{Address, Inline, Script}
use cardano/assets.{PolicyId, quantity_of, without_lovelace}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Redeemer, Transaction,
  find_input, placeholder,
}

//Contains all SC params
validator config(tx0: ByteArray, index0: Int, config_asset_name: ByteArray) {
  mint(_redeemer: Redeemer, policy_id: PolicyId, self: Transaction) {
    let own_policy_mint = quantity_of_policy_id(self.mint, policy_id)
    if own_policy_mint > 0 {
      //Bootstrap: one-shot mint of the config NFT
      let contract_credential = Script(policy_id)

      let one_time_utxo = OutputReference(tx0, index0)
      //we won't use input_present, we just need it to be there, otherwise error
      expect Some(_input_present) = find_input(self.inputs, one_time_utxo)
      let output_parameters = utils.safe_list_at(self.outputs, 0)
      //Genesis datum must parse, so the spend handler's assumptions hold
      //from the start
      expect InlineDatum(datum_raw) = output_parameters.datum
      expect _genesis_datum: ConfigDatum = datum_raw

      and {
        //First output goes to this address
        output_parameters.address.payment_credential == contract_credential,
        //Only 1 token of same policy
        own_policy_mint == 1,
        //I am minting only 1 token (NFT)
        quantity_of(self.mint, policy_id, config_asset_name) == 1,
        //NFT goes to the output
        quantity_of(output_parameters.value, policy_id, config_asset_name) == 1,
      }
    } else {
      //Retire: burn exactly the config NFT. No authorization here: the NFT
      //only ever sits at the config script address, so burning necessarily
      //spends the config UTxO, which runs the spend handler's Retire
      //authorization.
      and {
        own_policy_mint == -1,
        quantity_of(self.mint, policy_id, config_asset_name) == -1,
      }
    }
  }

  spend(
    //Raw on purpose: a typed ConfigDatum here would make the config UTxO
    //unspendable after any datum shape evolution (see the getters section in
    //bifrost/types/config)
    datum_opt: Option<Data>,
    redeemer: ConfigSpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(datum_raw) = datum_opt
    let old_fields = builtin.unconstr_fields(datum_raw)
    //None = permanently frozen: unspendable, the pre-governance behavior
    expect Some(update_auth) = configType.get_update_auth(old_fields)
    let authorized =
      authorizer.authorize_action(
        authorizer.create_auth(
          update_auth,
          self.inputs,
          self.reference_inputs,
          self.withdrawals,
          self.extra_signatories,
          self.mint,
        ),
      )
    //Mint policy and spend script share this hash, so the own payment
    //credential is also the config NFT policy id
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential
    when redeemer is {
      Update -> {
        //Exactly one continuing output at the config credential
        expect [config_output] =
          list.filter(
            self.outputs,
            fn(output) {
              output.address.payment_credential == Script(own_hash)
            },
          )
        //ANY inline datum is allowed: the authority is the root of trust and
        //datum shape evolution is an explicit goal (readers use positional
        //getters, see bifrost/types/config). The authority is responsible
        //for writing a datum that (a) current readers can parse and (b)
        //keeps field 0 parseable as Option<AuthorizationMethod> - anything
        //else halts the bridge or freezes the config until/unless a later
        //Update can fix it.
        expect InlineDatum(_new_datum_raw) = config_output.datum
        and {
          authorized,
          //Full address (stake credential included) must not drift
          config_output.address == own_input.output.address,
          //Non-ADA value is frozen: the NFT continues and no other token can
          //be stuffed into the config UTxO (it is a reference input of every
          //bridge tx, so junk assets would bloat all of them)
          without_lovelace(config_output.value) == without_lovelace(
            own_input.output.value,
          ),
          //The config NFT continues, and is the only own-policy token
          quantity_of(config_output.value, own_hash, config_asset_name) == 1,
          quantity_of_policy_id(config_output.value, own_hash) == 1,
        }
      }
      Retire ->
        //The tx burns exactly the config NFT; no continuing output required.
        //The min-ADA goes wherever the authority directs it.
        and {
          authorized,
          quantity_of_policy_id(self.mint, own_hash) == -1,
          quantity_of(self.mint, own_hash, config_asset_name) == -1,
        }
    }
  }

  else(_) {
    fail
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_tx0: ByteArray =
  #"0101010101010101010101010101010101010101010101010101010101010101"

const t_index0: Int = 0

const t_asset_name: ByteArray = "BifrostConfig"

const t_own_hash: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_dev_pkh: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const t_own_ref: OutputReference =
  OutputReference {
    transaction_id: #"2222222222222222222222222222222222222222222222222222222222222222",
    output_index: 0,
  }

//The rev-5.4 fifteen-field Config datum (spec §Config datum), built as raw
//Data: 0 update_auth, 1 bridged_token_policy, 2 completed_peg_ins_policy,
//3 bridge_state_policy, 4 tm_script_hash [CFG-2], 5 peg_in_script_hash,
//6 peg_out_script_hash, 7 spo_bans_policy_id, 8 base_ban_duration_ms,
//9 max_faults_before_permanent, 10 max_validity_window_ms,
//11 spos_registry_policy_id, 12 treasury_info_policy_id,
//13 treasury_info_asset_name,
//14 params (fee_rate_sat_per_vb, per_pegout_fee, min_peg_out_fbtc, schedule).
//Raw on purpose: the spend handler itself takes the datum raw, so the
//fixture mirrors the wire encoding, and it stays valid across a future datum
//shape evolution.
fn t_datum_data(update_auth: Option<AuthorizationMethod>) -> Data {
  let update_auth_data: Data = update_auth
  let schedule_data: Data =
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
  let params_data: Data =
    builtin.constr_data(
      0,
      [
        builtin.i_data(1),
        builtin.i_data(1000),
        builtin.i_data(10000),
        schedule_data,
      ],
    )
  builtin.constr_data(
    0,
    [
      update_auth_data,
      builtin.b_data(#"aa111111111111111111111111111111111111111111111111111111"),
      builtin.b_data(#"aa444444444444444444444444444444444444444444444444444444"),
      builtin.b_data(#"aa555555555555555555555555555555555555555555555555555555"),
      //tm_script_hash, spec [CFG-2]: no on-chain reader
      builtin.b_data(#"aa888888888888888888888888888888888888888888888888888888"),
      builtin.b_data(#"aa666666666666666666666666666666666666666666666666666666"),
      builtin.b_data(#"aa777777777777777777777777777777777777777777777777777777"),
      //Federation identity, indexes 7-13 (spec §Config datum). Off-chain
      //readers only; no validator in this tree reads a current value.
      builtin.b_data(#"aabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
      builtin.i_data(600_000),
      builtin.i_data(3),
      builtin.i_data(3_600_000),
      builtin.b_data(#"aacccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
      builtin.b_data(#"aadddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
      builtin.b_data("TMTx"),
      params_data,
      //Federation identity, indexes 15-16: the x-only Y_federation key and the
      //recovery leaf's CSV delay, appended AFTER params so index 14 still holds
      //the params constr. The genesis mint FULL-CASTS this datum, so a fixture
      //missing them fails the cast — which is exactly what that cast is for.
      builtin.b_data(
        #"aa999999999999999999999999999999999999999999999999999999999999ff",
      ),
      builtin.i_data(144),
    ],
  )
}

//Replace one positional field of a raw config datum (update fixtures).
fn t_set_field(datum_data: Data, index: Int, value: Data) -> Data {
  builtin.constr_data(
    0,
    list.indexed_map(
      builtin.unconstr_fields(datum_data),
      fn(i, field) {
        if i == index {
          value
        } else {
          field
        }
      },
    ),
  )
}

//The generic "some field changed" edit the Update tests apply: rewrite
//field 5 (peg_in_script_hash) to a value the old datum did not carry. Which
//field changes is irrelevant to these tests - the Update handler accepts any
//datum content and they exercise the address, value and authorization rules.
const t_edited_peg_in_hash: ByteArray =
  #"bb666666666666666666666666666666666666666666666666666666"

fn t_edited_datum(datum_data: Data) -> Data {
  t_set_field(datum_data, 5, builtin.b_data(t_edited_peg_in_hash))
}

fn t_config_output(datum_data: Data) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_own_hash),
      stake_credential: None,
    },
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_own_hash, t_asset_name, 1),
    datum: InlineDatum(datum_data),
    reference_script: None,
  }
}

fn t_own_input(datum_data: Data) -> Input {
  Input { output_reference: t_own_ref, output: t_config_output(datum_data) }
}

fn t_spend(
  old_datum_data: Data,
  redeemer: ConfigSpendRedeemer,
  tx: Transaction,
) {
  config.spend(
    t_tx0,
    t_index0,
    t_asset_name,
    Some(old_datum_data),
    redeemer,
    t_own_ref,
    tx,
  )
}

fn t_update_tx(old_datum_data: Data, config_outputs: List<Output>) {
  Transaction {
    ..placeholder,
    inputs: [t_own_input(old_datum_data)],
    outputs: config_outputs,
    extra_signatories: [t_dev_pkh],
  }
}

test update_happy_path_signature_auth() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  let tx = t_update_tx(old_datum, [t_config_output(new_datum)])
  t_spend(old_datum, Update, tx)
}

test update_happy_path_withdraw_script_auth() {
  let gov_hash = #"ee111111111111111111111111111111111111111111111111111111"
  let old_datum = t_datum_data(Some(CardanoWithdrawScript { hash: gov_hash }))
  let new_datum = t_edited_datum(old_datum)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_own_input(old_datum)],
      outputs: [t_config_output(new_datum)],
      withdrawals: [Pair(Script(gov_hash), 0)],
    }
  t_spend(old_datum, Update, tx)
}

test update_rotates_update_auth() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_auth: Option<AuthorizationMethod> =
    Some(
      CardanoWithdrawScript {
        hash: #"ee111111111111111111111111111111111111111111111111111111",
      },
    )
  let new_auth_data: Data = new_auth
  let new_datum = t_set_field(old_datum, 0, new_auth_data)
  let tx = t_update_tx(old_datum, [t_config_output(new_datum)])
  t_spend(old_datum, Update, tx)
}

test update_renounces_to_none() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let none_auth: Option<AuthorizationMethod> = None
  let none_auth_data: Data = none_auth
  let new_datum = t_set_field(old_datum, 0, none_auth_data)
  let tx = t_update_tx(old_datum, [t_config_output(new_datum)])
  t_spend(old_datum, Update, tx)
}

test update_rejects_missing_signature() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_own_input(old_datum)],
      outputs: [t_config_output(new_datum)],
      extra_signatories: [],
    }
  t_spend(old_datum, Update, tx)
}

test update_rejects_frozen_config() fail {
  let old_datum = t_datum_data(None)
  let new_datum = t_edited_datum(old_datum)
  let tx = t_update_tx(old_datum, [t_config_output(new_datum)])
  t_spend(old_datum, Update, tx)
}

test update_rejects_nft_not_returned() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  //Continuing output goes to a foreign credential instead of the config script
  let stolen_output =
    Output {
      ..t_config_output(new_datum),
      address: Address {
        payment_credential: Script(
          #"ff111111111111111111111111111111111111111111111111111111",
        ),
        stake_credential: None,
      },
    }
  let tx = t_update_tx(old_datum, [stolen_output])
  t_spend(old_datum, Update, tx)
}

test update_rejects_nft_quantity_not_one() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  let doubled_nft_output =
    Output {
      ..t_config_output(new_datum),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_own_hash, t_asset_name, 2),
    }
  let tx = t_update_tx(old_datum, [doubled_nft_output])
  t_spend(old_datum, Update, tx)
}

//The authority is the root of trust: it may change ANY datum content,
//including the bridged-token policy. (The asset name is a [CFG-1] constant
//now, so only the policy is governance data.)
test update_allows_changing_bridged_token_identity() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum =
    t_set_field(
      old_datum,
      1,
      builtin.b_data(#"ff222222222222222222222222222222222222222222222222222222"),
    )
  let tx = t_update_tx(old_datum, [t_config_output(new_datum)])
  t_spend(old_datum, Update, tx)
}

//Shape evolution: appending a 9th field to the datum is a legal update
test update_allows_appending_datum_fields() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let extended_datum =
    builtin.constr_data(
      0,
      list.concat(builtin.unconstr_fields(old_datum), [builtin.i_data(99)]),
    )
  let tx = t_update_tx(old_datum, [t_config_output(extended_datum)])
  t_spend(old_datum, Update, tx)
}

test update_rejects_changed_stake_credential() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  let drifted_output =
    Output {
      ..t_config_output(new_datum),
      address: Address {
        payment_credential: Script(t_own_hash),
        stake_credential: Some(
          Inline(
            Script(#"ff333333333333333333333333333333333333333333333333333333"),
          ),
        ),
      },
    }
  let tx = t_update_tx(old_datum, [drifted_output])
  t_spend(old_datum, Update, tx)
}

test update_rejects_added_foreign_tokens() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  let stuffed_output =
    Output {
      ..t_config_output(new_datum),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_own_hash, t_asset_name, 1)
        |> assets.add(
            #"ff444444444444444444444444444444444444444444444444444444",
            "junk",
            1,
          ),
    }
  let tx = t_update_tx(old_datum, [stuffed_output])
  t_spend(old_datum, Update, tx)
}

test update_rejects_smuggled_own_policy_token() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  let smuggled_output =
    Output {
      ..t_config_output(new_datum),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_own_hash, t_asset_name, 1)
        |> assets.add(t_own_hash, "fake-config-marker", 1),
    }
  let tx = t_update_tx(old_datum, [smuggled_output])
  t_spend(old_datum, Update, tx)
}

test update_rejects_two_config_outputs() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum = t_edited_datum(old_datum)
  let decoy_output =
    Output {
      ..t_config_output(new_datum),
      value: assets.from_lovelace(2_000_000),
    }
  let tx = t_update_tx(old_datum, [t_config_output(new_datum), decoy_output])
  t_spend(old_datum, Update, tx)
}

//Rotating update_auth is unrestricted; the authority owns the consequences
//(a self-referential CardanoSpendScript(own_hash) makes the config
//permissionlessly spendable, a garbage hash freezes it)
test update_allows_any_update_auth_rotation() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let rotated_auth: Option<AuthorizationMethod> =
    Some(CardanoSpendScript { hash: t_own_hash })
  let rotated_auth_data: Data = rotated_auth
  let new_datum = t_set_field(old_datum, 0, rotated_auth_data)
  let tx = t_update_tx(old_datum, [t_config_output(new_datum)])
  t_spend(old_datum, Update, tx)
}

//Any inline datum is accepted, even one no current reader can parse. The
//authority is responsible for writing a datum whose field 0 still parses
//as Option<AuthorizationMethod>, otherwise the config freezes.
test update_allows_arbitrary_datum_shape() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let arbitrary_output =
    Output { ..t_config_output(old_datum), datum: InlineDatum(42) }
  let tx = t_update_tx(old_datum, [arbitrary_output])
  t_spend(old_datum, Update, tx)
}

fn t_retire_tx(old_datum: Data, mint: assets.Value) {
  Transaction {
    ..placeholder,
    inputs: [t_own_input(old_datum)],
    outputs: [],
    mint: mint,
    extra_signatories: [t_dev_pkh],
  }
}

test retire_happy_path() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let tx = t_retire_tx(old_datum, assets.from_asset(t_own_hash, t_asset_name, -1))
  t_spend(old_datum, Retire, tx)
}

test retire_rejects_unauthorized() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let tx =
    Transaction {
      ..t_retire_tx(old_datum, assets.from_asset(t_own_hash, t_asset_name, -1)),
      extra_signatories: [],
    }
  t_spend(old_datum, Retire, tx)
}

test retire_rejects_wrong_burn_quantity() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let tx = t_retire_tx(old_datum, assets.from_asset(t_own_hash, t_asset_name, -2))
  t_spend(old_datum, Retire, tx)
}

test retire_rejects_wrong_asset_name_burn() fail {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let tx = t_retire_tx(old_datum, assets.from_asset(t_own_hash, "other", -1))
  t_spend(old_datum, Retire, tx)
}

fn t_one_time_input() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: t_tx0,
      output_index: t_index0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(
          #"ff999999999999999999999999999999999999999999999999999999",
        ),
        stake_credential: None,
      },
      value: assets.from_lovelace(5_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

test mint_bootstrap_happy_path() {
  let datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_time_input()],
      outputs: [t_config_output(datum)],
      mint: assets.from_asset(t_own_hash, t_asset_name, 1),
    }
  config.mint(t_tx0, t_index0, t_asset_name, Void, t_own_hash, tx)
}

test mint_bootstrap_rejects_bad_datum() fail {
  let bad_datum_output =
    Output {
      ..t_config_output(t_datum_data(None)),
      datum: InlineDatum(42),
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_time_input()],
      outputs: [bad_datum_output],
      mint: assets.from_asset(t_own_hash, t_asset_name, 1),
    }
  config.mint(t_tx0, t_index0, t_asset_name, Void, t_own_hash, tx)
}

test mint_burn_accepts_minus_one() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_own_input(t_datum_data(Some(CardanoSignature { hash: t_dev_pkh })))],
      mint: assets.from_asset(t_own_hash, t_asset_name, -1),
      extra_signatories: [t_dev_pkh],
    }
  config.mint(t_tx0, t_index0, t_asset_name, Void, t_own_hash, tx)
}

test mint_burn_rejects_wrong_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      mint: assets.from_asset(t_own_hash, "other", -1),
    }
  config.mint(t_tx0, t_index0, t_asset_name, Void, t_own_hash, tx)
}

test mint_burn_rejects_mixed_mint_and_burn() fail {
  let tx =
    Transaction {
      ..placeholder,
      mint: assets.from_asset(t_own_hash, t_asset_name, -1)
        |> assets.add(t_own_hash, "other", 1),
    }
  config.mint(t_tx0, t_index0, t_asset_name, Void, t_own_hash, tx)
}

