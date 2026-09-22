use aiken/collection/list
use aiken/crypto
use aiken/primitive/bytearray
use bifrost/constants
use bifrost/types/config as config_types
use bifrost/types/treasury.{
  RegistryUpdate, Retire, TreasuryDatum, TreasurySpendRedeemer, UpdateY,
}
use bifrost/utils
use cardano/address.{Address, Inline, Script}
use cardano/assets.{PolicyId, flatten, quantity_of, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, find_input,
  placeholder,
}

// The domain-separated preimage a key rotation signs. UNCHANGED in rev 5.5, so
// every BIP340 vector below and in heimdall stays valid. One governance action
// remains ("bifrost-update-y", the Update-Y rotation; the reset tag died with
// the FederationReset branch, spec [UY-7]/[UY-8] WITHDRAWN). `tag` stays a
// parameter so heimdall's signer and this verifier agree byte-for-byte (see
// technical_documentation.md §Update-Y).
//
// The outpoint encoding here is byte-for-byte utils.serialise_output_reference,
// which spos-registry.ak's registration and revocation nonces use ([REG-10],
// [DRG-6]) — and it is spelled out rather than CALLED, deliberately.
//
// Calling it would be better style, and it was written that way first. But this
// validator's hash is the Treasury state NFT's policy id, fixed by a one-shot
// outpoint consumed at genesis: a changed hash is not a redeploy, it is a
// different bridge, and the existing state UTxO could never be spent again.
// Aiken does not promise that extracting a helper leaves the compiled code
// identical, and measured here it does not — the hash moved.
//
// So the two stay in sync by TEST instead: `rotation_sig_msg_matches_the_shared
// _outpoint_encoding` below asserts these bytes equal the helper's, and fails
// if either side's endianness is ever touched.
fn rotation_sig_msg(
  tag: ByteArray,
  own_ref: OutputReference,
  epoch: Int,
  new_key: ByteArray,
) -> ByteArray {
  crypto.sha2_256(
    tag
      |> bytearray.concat(own_ref.transaction_id)
      |> bytearray.concat(bytearray.from_int_little_endian(own_ref.output_index, 4))
      |> bytearray.concat(bytearray.from_int_big_endian(epoch, 8))
      |> bytearray.concat(new_key),
  )
}

// spec [TSY-14]: the single continuing output at this script, with its address
// and its whole value unchanged. The NFT rides along inside the value equality,
// so no separate NFT check is needed on the output.
//
// spec [TSY-1]: the datum comes back decoded as a type. The decode checks the
// constructor tag and the exact arity, so neither branch can be handed a datum
// the protocol never describes.
//
// Every branch that keeps the UTxO alive goes through here, and that is what
// makes the field-permission matrix enforceable: with two fields, each branch
// names the one it owns and asserts the other is unchanged.
fn continuing_datum(
  self: Transaction,
  own_hash: ByteArray,
  own_input: Input,
) -> TreasuryDatum {
  expect [out] =
    list.filter(
      self.outputs,
      fn(output) { output.address.payment_credential == Script(own_hash) },
    )
  expect out.address == own_input.output.address
  expect out.value == own_input.output.value
  expect InlineDatum(out_raw) = out.datum
  expect out_datum: TreasuryDatum = out_raw
  out_datum
}

// The Config datum's raw fields, authenticated by the parameterized NFT.
// spec [TSY-2]: located by redeemer index, never by scanning reference_inputs.
// A scan costs O(reference_inputs), and a scan that finds nothing picks a wrong
// UTxO instead of failing. peg-in.ak states the same rule for the singleton.
fn config_fields_at(
  self: Transaction,
  config_policy_id: PolicyId,
  index: Int,
) -> List<Data> {
  utils.get_config_as_data_list(
    utils.safe_list_at(self.reference_inputs, index),
    config_policy_id,
    constants.config_nft_asset_name,
  )
}

// spec [PRE-1] REVISED: treasury.ak takes neither tm_nft_policy_id nor
// registry_policy_id. A compile parameter naming another bridge script breaks
// permanently on that script's redeploy, and this script's state UTxO can never
// move. spec [PRE-3]: the Config NFT policy id is the one identity safe to bake
// in — the Config UTxO is the root of the identity graph, and its policy id
// depends only on its own one-shot outpoint. spec [PRE-4]: the registry policy
// id and y_federation are read from the Config datum at run time.
validator treasury_info(tx0: ByteArray, index0: Int, config_policy_id: PolicyId) {
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    let own_policy_mint = utils.quantity_of_policy_id(self.mint, policy_id)
    if own_policy_mint > 0 {
      // spec [TSY-3]: the one-shot outpoint is what makes this NFT a singleton.
      // It is baked into policy_id, so only the deployer can ever reach here.
      let one_time_utxo = OutputReference(tx0, index0)
      expect Some(_input_present) = find_input(self.inputs, one_time_utxo)
      // spec [TSY-5]: exactly one output at this script.
      expect [treasury_output] =
        list.filter(
          self.outputs,
          fn(output) { output.address.payment_credential == Script(policy_id) },
        )
      // spec [TSY-6]: it holds the NFT and no other non-ADA asset.
      expect [(out_policy, out_name, 1)] =
        flatten(without_lovelace(treasury_output.value))
      // spec [TSY-7]: the datum decodes as TreasuryDatum.
      expect InlineDatum(datum_raw) = treasury_output.datum
      expect genesis: TreasuryDatum = datum_raw
      and {
        // spec [TSY-4]
        own_policy_mint == 1,
        quantity_of(
          self.mint,
          policy_id,
          constants.treasury_info_nft_asset_name,
        ) == 1,
        out_policy == policy_id,
        out_name == constants.treasury_info_nft_asset_name,
        // spec [TSY-5]: no stake credential. A drifting address would leave a
        // reader that pins the bare script address unable to find the UTxO.
        treasury_output.address == Address {
          payment_credential: Script(policy_id),
          stake_credential: None,
        },
        // spec [TSY-8]. The VALUES are free: spec [PRE-2] lets a replacement
        // deployment seed a non-empty root and carry a registered roster
        // forward. Only the deployer can mint, so a value check here would be a
        // self-check, not a boundary.
        bytearray.length(genesis.bifrost_identity_root) == 32,
        bytearray.length(genesis.current_spos_frost_key) == 32,
      }
    } else {
      // spec [TSY-9], [TSY-10]: burn. No authorization here. The NFT only ever
      // sits at this script, so burning it requires spending the state UTxO,
      // which runs the Retire branch. config.ak makes the same argument.
      and {
        own_policy_mint == -1,
        quantity_of(
          self.mint,
          policy_id,
          constants.treasury_info_nft_asset_name,
        ) == -1,
      }
    }
  }

  spend(
    datum: Option<TreasuryDatum>,
    redeemer: TreasurySpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Some(in_datum) = datum
    // spec [TSY-11]
    expect
      quantity_of(
        own_input.output.value,
        own_hash,
        constants.treasury_info_nft_asset_name,
      ) == 1

    when redeemer is {
      // spec [TSY-19] to [TSY-22]. No signature and no continuing output.
      // Burning the Config NFT requires spending the Config UTxO, which runs
      // config.ak's Retire under update_auth, so governance authorization is
      // inherited. Duplicating it here would add a second thing to keep in sync.
      Retire -> and {
          quantity_of(
            self.mint,
            config_policy_id,
            constants.config_nft_asset_name,
          ) == -1,
          quantity_of(
            self.mint,
            own_hash,
            constants.treasury_info_nft_asset_name,
          ) == -1,
        }
      RegistryUpdate { config_ref_input_index } -> {
        // spec [TSY-12]
        let config_fields =
          config_fields_at(self, config_policy_id, config_ref_input_index)
        let out_datum = continuing_datum(self, own_hash, own_input)
        let registry_policy =
          config_types.get_spos_registry_policy_id(config_fields)
        and {
          // spec [TSY-13]: a Register mints one membership token and a
          // Deregister burns one, so a non-zero sum is the marker. The registry
          // policy is the authority here; this branch only checks that it ran.
          utils.quantity_of_policy_id(self.mint, registry_policy) != 0,
          // spec [TSY-23]: and the mint MUST NOT be the registry's Bootstrap.
          // That branch mints the root node and validates NO treasury
          // transition — it never calls treasury_state_transition_ok — so
          // accepting it as the marker would let one transaction rewrite
          // bifrost_identity_root to anything at all. A `#""` root written
          // there bricks the instance permanently: mpf.from_root demands 32
          // bytes, so every later Register and Deregister aborts, and the only
          // branch that could repair the root is the one now aborting.
          quantity_of(
            self.mint,
            registry_policy,
            constants.registration_root_asset_name,
          ) == 0,
          // spec [TSY-24]: the continuing root is a 32-byte MPF root. Defence
          // in depth behind [TSY-23]: a Register/Deregister necessarily wrote a
          // real root (spos-registry.ak proved it with an MPF proof, which
          // itself requires 32 bytes), so this can only fire if that coupling
          // is ever broken again.
          bytearray.length(out_datum.bifrost_identity_root) == 32,
          // spec [TSY-15]: the key is preserved, so key rotation cannot ride
          // along on a registration. The new root is whatever the registry's
          // own [REG-5] MPF proof forced it to be; this branch never had a say
          // in its value and no longer pretends to.
          out_datum.current_spos_frost_key == in_datum.current_spos_frost_key,
        }
      }
      UpdateY { epoch, signature, config_ref_input_index } -> {
        // spec [TSY-12], [UY-5]: y_federation lives in the Config datum now.
        let config_fields =
          config_fields_at(self, config_policy_id, config_ref_input_index)
        let y_federation = config_types.get_y_federation(config_fields)
        let out_datum = continuing_datum(self, own_hash, own_input)
        // The new key is READ from the continuing datum, not restated in the
        // redeemer. Safe because the signature below commits to it: change the
        // datum's key and the message changes with it.
        let new_spos_frost_key = out_datum.current_spos_frost_key
        let msg =
          rotation_sig_msg(
            "bifrost-update-y",
            own_ref,
            epoch,
            new_spos_frost_key,
          )
        and {
          // spec [TSY-16]: a 32-byte x-only point. Point validity is the
          // roster's own problem — a bad point can only harm the roster that
          // signed for it.
          bytearray.length(new_spos_frost_key) == 32,
          // spec [TSY-17]: only the key changes.
          out_datum.bifrost_identity_root == in_datum.bifrost_identity_root,
          // spec [TSY-18]. Two signers, either alone:
          //  - the OUTGOING key authorizes its own succession. In Phase 1 the
          //    spent datum holds Y_federation, so the federation signs the
          //    first rotation; after that each roster hands off to the next.
          //  - spec [UY-5]: OR the federation, under the Config's
          //    y_federation. That standing co-authority is the dead-roster
          //    recovery, and it replaces the withdrawn FederationReset branch.
          //    spec [UY-6] WITHDRAWN: the federation MAY name any key.
          // Submission is permissionless: the signature IS the authorization,
          // and the message commits to the spent outpoint, so it cannot be
          // replayed.
          or {
            crypto.verify_schnorr_signature(
              in_datum.current_spos_frost_key,
              msg,
              signature,
            ),
            crypto.verify_schnorr_signature(y_federation, msg, signature),
          },
        }
      }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Test fixtures
//----------------------------------------------------------------------------

const t_own_hash: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_config_policy: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const t_registry_policy: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const t_tx0: ByteArray =
  #"0101010101010101010101010101010101010101010101010101010101010101"

const t_index0: Int = 0

// Federation key: x-only of secret 3, so the [UY-5] federation test can sign
// under it. It lives in the CONFIG datum now, not in TreasuryDatum.
const t_yfed: ByteArray =
  #"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

const t_root0: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

const t_root1: ByteArray =
  #"1111111111111111111111111111111111111111111111111111111111111111"

// Update-Y BIP340 vector. t_cur_key is the x-only generator point (secret 1),
// which signs the rotation to t_new_key. rotation_sig_msg is unchanged in rev
// 5.5, so this vector is the rev-5.4 one, reused verbatim.
const t_cur_key: ByteArray =
  #"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

const t_new_key: ByteArray =
  #"abababababababababababababababababababababababababababababababab"

const t_updatey_txid: ByteArray =
  #"2222222222222222222222222222222222222222222222222222222222222222"

const t_updatey_epoch: Int = 7

const t_updatey_sig: ByteArray =
  #"21e3f8a17eac410867d72aea6a9089001153682a481861188527008e698c8d857e3454db7e2e413f0ae8a2aadedcc4d5f33934b6f5e066d9202cb78a591dcd21"

// spec [UY-5]: the SAME Update-Y message, signed by the FEDERATION key
// (t_yfed's secret, 3) instead. Generated by the BIP340 reference impl with
// zeroed aux randomness.
const t_updatey_fed_sig: ByteArray =
  #"c5a6acf9ad7895ef37f63bdca615f21b73d2b08d0bdc244b36d53abb63cab264252a857c22522daebb7deec35b2066d72f5dc678413a1ca7ce7a018340018d53"

fn t_datum(root: ByteArray, key: ByteArray) -> TreasuryDatum {
  TreasuryDatum { bifrost_identity_root: root, current_spos_frost_key: key }
}

// A typed ConfigDatum, on purpose. The treasury reads it positionally through
// the getters, and building the real record here means a ConfigDatum shape
// change surfaces in these tests instead of silently shifting an index.
fn t_config_datum() -> config_types.ConfigDatum {
  config_types.ConfigDatum {
    update_auth: None,
    params: config_types.ConfigParams {
      schedule: config_types.ScheduleParams {
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
      },
      fee_rate_sat_per_vb: 1,
      per_pegout_fee: 1000,
      min_peg_out_fbtc: 10000,
      base_ban_duration_ms: 600_000,
      max_faults_before_permanent: 3,
      max_validity_window_ms: 3_600_000,
      federation_csv_blocks: 144,
      pegin_refund_timeout_blocks: 720,
    },
    bridged_token_policy: #"aa02",
    completed_peg_ins_policy: #"aa03",
    bridge_state_policy: #"aa04",
    tm_script_hash: #"aa05",
    peg_in_script_hash: #"aa06",
    peg_out_script_hash: #"aa07",
    spo_bans_policy_id: #"aa08",
    spos_registry_policy_id: t_registry_policy,
    treasury_info_policy_id: t_own_hash,
    y_federation: t_yfed,
    federation_one_shot: OutputReference(#"aa12", 12),
    previous_spos_registry_policy_id: "",
  }
}

// `with_nft = False` is the [TSY-12] negative: a reference input that carries
// the datum but not the Config NFT must not be trusted.
fn t_config_ref_input(with_nft: Bool) -> Input {
  let base = assets.from_lovelace(2_000_000)
  let value =
    if with_nft {
      base |> assets.add(t_config_policy, constants.config_nft_asset_name, 1)
    } else {
      base
    }
  let datum_data: Data = t_config_datum()
  Input {
    output_reference: OutputReference {
      transaction_id: #"3333333333333333333333333333333333333333333333333333333333333333",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_config_policy),
        stake_credential: None,
      },
      value: value,
      datum: InlineDatum(datum_data),
      reference_script: None,
    },
  }
}

fn t_treasury_value() -> assets.Value {
  assets.from_lovelace(2_000_000)
    |> assets.add(t_own_hash, constants.treasury_info_nft_asset_name, 1)
}

fn t_script_address() -> Address {
  Address { payment_credential: Script(t_own_hash), stake_credential: None }
}

fn t_output(d: TreasuryDatum) -> Output {
  Output {
    address: t_script_address(),
    value: t_treasury_value(),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

// The outpoint the Update-Y signature commits to; reused as the spent treasury
// input for every spend test so find_input resolves and the message matches.
fn t_own_ref() -> OutputReference {
  OutputReference { transaction_id: t_updatey_txid, output_index: 0 }
}

fn t_input(d: TreasuryDatum) -> Input {
  Input { output_reference: t_own_ref(), output: t_output(d) }
}

// The one-shot outpoint the bootstrap consumes.
fn t_one_shot_input() -> Input {
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

fn t_mint_tx(
  inputs: List<Input>,
  outputs: List<Output>,
  mint: assets.Value,
) -> Transaction {
  Transaction { ..placeholder, inputs: inputs, outputs: outputs, mint: mint }
}

fn t_bootstrap_mint(qty: Int) -> assets.Value {
  assets.from_asset(t_own_hash, constants.treasury_info_nft_asset_name, qty)
}

fn t_spend(
  d: TreasuryDatum,
  redeemer: TreasurySpendRedeemer,
  tx: Transaction,
) -> Bool {
  treasury_info.spend(
    t_tx0,
    t_index0,
    t_config_policy,
    Some(d),
    redeemer,
    t_own_ref(),
    tx,
  )
}

//----------------------------------------------------------------------------
// Tests: bootstrap mint
//----------------------------------------------------------------------------

test mint_bootstrap_happy() {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root0, t_cur_key))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [PRE-2]: a replacement deployment MAY seed a non-empty identity root and
// carry its registered roster forward.
test mint_bootstrap_accepts_seeded_identity_root() {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root1, t_cur_key))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-3]: without the one-shot outpoint the policy is not mintable.
test mint_bootstrap_rejects_missing_one_shot() fail {
  let tx =
    t_mint_tx([], [t_output(t_datum(t_root0, t_cur_key))], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-4]
test mint_bootstrap_rejects_wrong_asset_name() fail {
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_own_hash, "NOTBFR", 1),
    }
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [output],
      assets.from_asset(t_own_hash, "NOTBFR", 1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-4]
test mint_bootstrap_rejects_quantity_two() fail {
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_own_hash, constants.treasury_info_nft_asset_name, 2),
    }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(2))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-6]: the state UTxO carries the NFT and nothing else.
test mint_bootstrap_rejects_extra_token() fail {
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: t_treasury_value()
        |> assets.add(
            #"ff444444444444444444444444444444444444444444444444444444",
            "junk",
            1,
          ),
    }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-5]: exactly one output at this script.
test mint_bootstrap_rejects_two_script_outputs() fail {
  let decoy =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: assets.from_lovelace(2_000_000),
    }
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root0, t_cur_key)), decoy],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-7]
test mint_bootstrap_rejects_undecodable_datum() fail {
  let output =
    Output { ..t_output(t_datum(t_root0, t_cur_key)), datum: InlineDatum(42) }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-8]: a short key is a typo, and it would brick Update-Y forever.
test mint_bootstrap_rejects_short_key() fail {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root0, #"abab"))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-8]
test mint_bootstrap_rejects_short_root() fail {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(#"0000", t_cur_key))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-5]: a stake credential would change the address, so a reader
// pinning the bare script address would not find the UTxO.
test mint_bootstrap_rejects_stake_credential() fail {
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      address: Address {
        payment_credential: Script(t_own_hash),
        stake_credential: Some(
          Inline(Script(#"ff333333333333333333333333333333333333333333333333333333")),
        ),
      },
    }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

//----------------------------------------------------------------------------
// Tests: burn and Retire
//----------------------------------------------------------------------------

fn t_config_burn() -> assets.Value {
  assets.from_asset(t_config_policy, constants.config_nft_asset_name, -1)
}

fn t_treasury_burn() -> assets.Value {
  assets.from_asset(t_own_hash, constants.treasury_info_nft_asset_name, -1)
}

// spec [TSY-9]: the mint handler accepts the burn on its own. Authorization
// lives in the Retire branch, which the burn cannot avoid running.
test mint_burn_accepts_minus_one() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(t_datum(t_root0, t_cur_key))],
      mint: t_treasury_burn(),
    }
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-9]
test mint_burn_rejects_mixed_mint_and_burn() fail {
  let tx =
    Transaction {
      ..placeholder,
      mint: t_treasury_burn() |> assets.add(t_own_hash, "other", 1),
    }
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-19], [TSY-20], [TSY-21]: both NFTs burn, no continuing output.
test spend_retire_happy() {
  let d = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d)],
      outputs: [],
      mint: t_treasury_burn() |> assets.merge(t_config_burn()),
    }
  t_spend(d, Retire, tx)
}

// spec [TSY-19]: without the Config burn there is no inherited authorization,
// so anyone could tear the instance down.
test spend_retire_rejects_without_config_burn() fail {
  let d = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d)],
      outputs: [],
      mint: t_treasury_burn(),
    }
  t_spend(d, Retire, tx)
}

// spec [TSY-20]: Retire must not become a way to move the NFT somewhere else.
test spend_retire_rejects_without_treasury_burn() fail {
  let d = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d)],
      outputs: [t_output(d)],
      mint: t_config_burn(),
    }
  t_spend(d, Retire, tx)
}

// spec [TSY-11]: an input with no Treasury state NFT is not the state UTxO.
test spend_rejects_input_without_nft() fail {
  let d = t_datum(t_root0, t_cur_key)
  let bare =
    Input {
      output_reference: t_own_ref(),
      output: Output {
        ..t_output(d),
        value: assets.from_lovelace(2_000_000),
      },
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [bare],
      outputs: [],
      mint: t_treasury_burn() |> assets.merge(t_config_burn()),
    }
  t_spend(d, Retire, tx)
}

//----------------------------------------------------------------------------
// Tests: RegistryUpdate
//----------------------------------------------------------------------------

// A registry token moves: the Register/Deregister marker RegistryUpdate needs.
fn t_registry_mint(qty: Int) -> assets.Value {
  assets.from_asset(t_registry_policy, "pool-id-bytes", qty)
}

fn t_registry_tx(
  d0: TreasuryDatum,
  d1: TreasuryDatum,
  mint: assets.Value,
  with_config_nft: Bool,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [t_input(d0)],
    reference_inputs: [t_config_ref_input(with_config_nft)],
    outputs: [t_output(d1)],
    mint: mint,
  }
}

fn t_registry_update() -> TreasurySpendRedeemer {
  RegistryUpdate { config_ref_input_index: 0 }
}

// spec [TSY-15]: only bifrost_identity_root changes.
test spend_registry_update_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(
    d0,
    t_registry_update(),
    t_registry_tx(d0, d1, t_registry_mint(1), True),
  )
}

// A Deregister burns instead of minting. spec [TSY-13] sums the quantity, so a
// burn is just as good a marker as a mint.
test spend_registry_update_accepts_registry_burn() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(
    d0,
    t_registry_update(),
    t_registry_tx(d0, d1, t_registry_mint(-1), True),
  )
}

// spec [TSY-15]: this branch must not rotate the key. Key rotation is UpdateY,
// and it is the only path with a signature check.
test spend_registry_update_rejects_key_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  t_spend(
    d0,
    t_registry_update(),
    t_registry_tx(d0, d1, t_registry_mint(1), True),
  )
}

// spec [TSY-13]: without a registry token moving, anyone could rewrite the
// identity root.
test spend_registry_update_rejects_no_registry_mint() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(
    d0,
    t_registry_update(),
    t_registry_tx(d0, d1, assets.zero, True),
  )
}

// spec [TSY-12]: the reference input must be the real Config UTxO. Without the
// NFT check an attacker supplies their own datum naming a policy they control.
test spend_registry_update_rejects_unauthenticated_config() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(
    d0,
    t_registry_update(),
    t_registry_tx(d0, d1, t_registry_mint(1), False),
  )
}

// spec [TSY-23]: the registry BOOTSTRAP mint is not a Register/Deregister. It
// validates no treasury transition, so accepting it as the marker would let one
// transaction write any bifrost_identity_root — including a short one, which
// bricks every later registration because mpf.from_root demands 32 bytes.
test spend_registry_update_rejects_registry_bootstrap_mint() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let bootstrap_mint =
    assets.from_asset(
      t_registry_policy,
      constants.registration_root_asset_name,
      1,
    )
  t_spend(d0, t_registry_update(), t_registry_tx(d0, d1, bootstrap_mint, True))
}

// spec [TSY-24]: a short root can never continue, whatever the registry minted.
test spend_registry_update_rejects_short_root() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(#"0000", t_cur_key)
  t_spend(
    d0,
    t_registry_update(),
    t_registry_tx(d0, d1, t_registry_mint(1), True),
  )
}

// A membership token under the SAME policy still passes: [TSY-23] excludes the
// root asset name, not the policy.
test spend_registry_update_accepts_membership_token_mint() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let member_mint = assets.from_asset(t_registry_policy, "pool-id-bytes", 1)
  t_spend(d0, t_registry_update(), t_registry_tx(d0, d1, member_mint, True))
}

// spec [TSY-14]: the value must carry over untouched.
test spend_registry_update_rejects_value_drift() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let drained =
    Output { ..t_output(d1), value: assets.from_lovelace(1_000_000) }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_config_ref_input(True)],
      outputs: [drained],
      mint: t_registry_mint(1),
    }
  t_spend(d0, t_registry_update(), tx)
}

// spec [TSY-14]: and the UTxO must stay at this script.
test spend_registry_update_rejects_moved_output() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let moved =
    Output {
      ..t_output(d1),
      address: Address {
        payment_credential: Script(
          #"ff111111111111111111111111111111111111111111111111111111",
        ),
        stake_credential: None,
      },
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_config_ref_input(True)],
      outputs: [moved],
      mint: t_registry_mint(1),
    }
  t_spend(d0, t_registry_update(), tx)
}

//----------------------------------------------------------------------------
// Tests: UpdateY
//----------------------------------------------------------------------------

fn t_update_y(epoch: Int, sig: ByteArray) -> TreasurySpendRedeemer {
  UpdateY { epoch: epoch, signature: sig, config_ref_input_index: 0 }
}

fn t_update_y_tx(
  d0: TreasuryDatum,
  d1: TreasuryDatum,
  with_config_nft: Bool,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [t_input(d0)],
    reference_inputs: [t_config_ref_input(with_config_nft)],
    outputs: [t_output(d1)],
  }
}

// spec [TSY-18]: the outgoing key authorizes its own succession.
test spend_update_y_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [UY-5]: the federation signs the SAME message under the Config's
// y_federation, and the rotation passes without the outgoing roster. This
// standing co-authority is the whole dead-roster recovery, and [UY-6] is
// withdrawn, so the named key is arbitrary.
test spend_update_y_federation_signed() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_updatey_epoch, t_updatey_fed_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-18]: the epoch is inside the signed message.
test spend_update_y_rejects_wrong_epoch() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_updatey_epoch + 1, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-18]: a signature by a key that is neither the outgoing one nor the
// federation is worthless.
test spend_update_y_rejects_wrong_signer() fail {
  let d0 = t_datum(t_root0, t_new_key)
  let d1 = t_datum(t_root0, t_cur_key)
  t_spend(
    d0,
    t_update_y(t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-17]: only the key changes on this branch.
test spend_update_y_rejects_extra_field_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  t_spend(
    d0,
    t_update_y(t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-16]: a short key would be unusable and unrecoverable.
test spend_update_y_rejects_short_key() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, #"abab")
  t_spend(
    d0,
    t_update_y(t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-12]: a forged Config reference input names a y_federation the
// attacker controls, which would make [UY-5] a free rotation for anyone.
test spend_update_y_rejects_unauthenticated_config() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_updatey_epoch, t_updatey_fed_sig),
    t_update_y_tx(d0, d1, False),
  )
}

// spec [UY-3], [REG-10], [DRG-6]: the one place the two spellings of the
// outpoint encoding are compared.
//
// rotation_sig_msg cannot call utils.serialise_output_reference without moving
// this validator's hash, and this validator's hash is the Treasury state NFT's
// policy id — see the comment above it. This test is what that comment trades
// against: a change to either endianness, or to the field order, fails here
// rather than at an SPO's first Update-Y on a live bridge.
test rotation_sig_msg_matches_the_shared_outpoint_encoding() {
  let own_ref =
    OutputReference {
      transaction_id: #"7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a",
      output_index: 3,
    }
  let inline =
    own_ref.transaction_id
      |> bytearray.concat(
          bytearray.from_int_little_endian(own_ref.output_index, 4),
        )
  and {
    inline == utils.serialise_output_reference(own_ref),
    bytearray.length(inline) == 36,
  }
}
