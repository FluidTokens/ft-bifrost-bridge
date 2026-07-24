use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use aiken/primitive/bytearray
use bifrost/types/treasury.{
  FederationReset, RegistryUpdate, TreasuryDatum, TreasuryMintRedeemer,
  TreasurySpendRedeemer, UpdateY,
}
use bifrost/types/treasury_movement.{Confirmed}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, flatten, quantity_of, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input, placeholder,
}

// The domain-separated preimage a key rotation signs. `tag` separates the two
// governance actions ("bifrost-update-y" for the roster hand-off, N10a, and
// "bifrost-update-y-reset" for the emergency federation reset, N10b); the layout
// is identical so heimdall's signer and this verifier agree byte-for-byte (see
// technical_documentation.md §Update-Y).
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

// tm_nft_policy_id = the binocular TreasuryMovementValidator script hash (the TM
// NFT policy). The FederationReset branch authenticates the Confirmed TM it reads
// its dead-roster flag from by requiring that NFT — same trust anchor peg-in.ak
// uses.
validator treasury_info(
  registry_policy_id: PolicyId,
  tm_nft_policy_id: PolicyId,
) {
  mint(redeemer: TreasuryMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent =
      option.is_some(find_input(self.inputs, redeemer.input_ref))

    expect [treasury_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    //Minted tokens from this policy id must be only 1 and with quantity 1
    expect [Pair(_this_token_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))

    //AssetName must be correct
    expect [(this_token_policy_id, this_token_asset_name, 1)] =
      flatten(without_lovelace(treasury_output.value))
    let only_minted_token_is_correctly_in_output = and {
        this_token_policy_id == policy_id,
        this_token_asset_name == input_ref_hash,
      }

    //Output must contain proper InlineDatum
    let output_has_correct_datum =
      treasury_output.datum == InlineDatum(
        TreasuryDatum {
          bifrost_identity_root: mpf.root(mpf.empty),
          current_spos_frost_key: redeemer.current_spos_frost_key,
          y_federation: redeemer.y_federation,
          federation_csv_blocks: redeemer.federation_csv_blocks,
          // No reset has happened at bootstrap; empty until the first FederationReset.
          last_reset_tm_txid: #"",
        },
      )

    //Output with the minted token must go to this script
    let output_goes_to_this_script =
      treasury_output.address == Address {
        payment_credential: Script(policy_id),
        stake_credential: None,
      }

    and {
      is_input_ref_spent,
      only_minted_token_is_correctly_in_output,
      output_has_correct_datum,
      output_goes_to_this_script,
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
    expect Pair(own_asset_name, 1) =
      utils.get_singleton_asset_with_policy(own_input.output.value, own_hash)

    let continued_treasury_output =
      utils.find_singleton_asset_output_at_script(
        self.outputs,
        own_hash,
        own_hash,
        own_asset_name,
      )

    expect Some(in_datum) = datum

    // The Treasury state NFT, the whole value, and the script address always
    // carry over unchanged; only the datum differs per branch. Every branch
    // rewrites the datum with a record-update spread off `in_datum`, so any
    // field it does not name is preserved verbatim (this is what enforces the
    // field-permission matrix — see technical_documentation.md §Treasury state
    // UTxO).
    let carries_over = and {
        own_input.output.value == continued_treasury_output.value,
        own_input.output.address == continued_treasury_output.address,
      }

    when redeemer is {
      RegistryUpdate { new_bifrost_identity_root } -> and {
          carries_over,
          // A registry token must move in the same tx (Register / Deregister).
          utils.quantity_of_policy_id(self.mint, registry_policy_id) != 0,
          // Only bifrost_identity_root changes; current_spos_frost_key and the
          // rest are preserved here, no longer relying on spos-registry.ak's pin.
          continued_treasury_output.datum == InlineDatum(
            TreasuryDatum {
              ..in_datum,
              bifrost_identity_root: new_bifrost_identity_root,
            },
          ),
        }
      UpdateY { new_spos_frost_key, epoch, signature } -> and {
          carries_over,
          // The new key is a 32-byte x-only point (point-validity is the roster's
          // responsibility — it can only harm the roster that signed it).
          bytearray.length(new_spos_frost_key) == 32,
          // Only current_spos_frost_key changes.
          continued_treasury_output.datum == InlineDatum(
            TreasuryDatum {
              ..in_datum,
              current_spos_frost_key: new_spos_frost_key,
            },
          ),
          // The OUTGOING key authorizes its own succession. In Phase 1 the spent
          // datum holds Y_federation, so the federation signs the first rotation;
          // thereafter each outgoing roster hands off to the next.
          crypto.verify_schnorr_signature(
            in_datum.current_spos_frost_key,
            rotation_sig_msg(
              "bifrost-update-y",
              own_ref,
              epoch,
              new_spos_frost_key,
            ),
            signature,
          ),
        }
      FederationReset { tm_ref_input_index, epoch, signature } -> {
        // The referenced Confirmed TM (authenticated by the TM NFT) is Binocular's
        // objective dead-roster evidence: it carries spent_via_federation_leaf, set
        // at confirm time iff the treasury tip was swept via the federation CSV leaf
        // — which can only happen after the tip aged federation_csv_blocks unmoved.
        let tm_ref = utils.safe_list_at(self.reference_inputs, tm_ref_input_index)
        expect InlineDatum(tm_raw) = tm_ref.output.datum
        expect Confirmed { btc_txid, spent_via_federation_leaf, .. } = tm_raw
        and {
          carries_over,
          // The TM record is authentic (carries the TM NFT, empty asset name).
          quantity_of(tm_ref.output.value, tm_nft_policy_id, #"") == 1,
          // Objective deadness: this TM swept the treasury via the federation leaf.
          spent_via_federation_leaf,
          // Freshness / anti-replay: a NEW federation sweep, not the one that last
          // reset (which is preserved across the recovering roster's Update-Y). This
          // is what stops a compromised federation replaying a stale sweep to demote
          // a roster that already recovered (see §Update-Y federation reset).
          btc_txid != in_datum.last_reset_tm_txid,
          // Only current_spos_frost_key changes — and ONLY to y_federation — plus the
          // reset anchor advances to the consumed sweep's txid.
          continued_treasury_output.datum == InlineDatum(
            TreasuryDatum {
              ..in_datum,
              current_spos_frost_key: in_datum.y_federation,
              last_reset_tm_txid: btc_txid,
            },
          ),
          // The FEDERATION authorizes the reset (BIP340 under y_federation).
          crypto.verify_schnorr_signature(
            in_datum.y_federation,
            rotation_sig_msg(
              "bifrost-update-y-reset",
              own_ref,
              epoch,
              in_datum.y_federation,
            ),
            signature,
          ),
        }
      }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests (spend branches — N10a: contradiction fix + Update-Y key rotation)
//----------------------------------------------------------------------------

const t_own_hash: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_registry_policy: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const t_tm_policy: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const t_asset_name: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// Federation fields (preserved by the RegistryUpdate / UpdateY branches).
// t_yfed = x-only of secret 3, so the FederationReset test can sign under it.
const t_yfed: ByteArray =
  #"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

const t_csv: Int = 144

// FederationReset BIP340 vector: sha2_256("bifrost-update-y-reset" ++ t_own_ref
// ++ epoch BE(8) ++ t_yfed), signed by y_fed's secret (3).
const t_reset_epoch: Int = 9

const t_reset_sig: ByteArray =
  #"0d9b091cd7f55b5966a838c754268f0b3471ac6bd9d9173f76a6fc91af1b67b8b536e557fdf65cbd31430292ba1ba72389da471e4cc7c35f851aec679d96ffa2"

// The federation-sweep TM's btc_txid the reset consumes (any 32 bytes).
const t_reset_btc_txid: ByteArray =
  #"3333333333333333333333333333333333333333333333333333333333333333"

const t_root0: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

const t_root1: ByteArray =
  #"1111111111111111111111111111111111111111111111111111111111111111"

// Update-Y BIP340 vector (generated by the BIP340 reference impl; the signed
// message is sha2_256("bifrost-update-y" ++ txid ++ vout LE(4) ++ epoch BE(8)
// ++ new_key) with the values below). t_cur_key is the x-only generator point
// (secret key = 1), which signs the rotation to t_new_key.
const t_cur_key: ByteArray =
  #"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

const t_new_key: ByteArray =
  #"abababababababababababababababababababababababababababababababab"

const t_updatey_txid: ByteArray =
  #"2222222222222222222222222222222222222222222222222222222222222222"

const t_updatey_epoch: Int = 7

const t_updatey_sig: ByteArray =
  #"21e3f8a17eac410867d72aea6a9089001153682a481861188527008e698c8d857e3454db7e2e413f0ae8a2aadedcc4d5f33934b6f5e066d9202cb78a591dcd21"

fn t_datum(root: ByteArray, key: ByteArray) -> TreasuryDatum {
  t_datum_reset(root, key, #"")
}

// Same, but with an explicit last_reset_tm_txid (for the reset freshness test).
fn t_datum_reset(
  root: ByteArray,
  key: ByteArray,
  last_reset_tm_txid: ByteArray,
) -> TreasuryDatum {
  TreasuryDatum {
    bifrost_identity_root: root,
    current_spos_frost_key: key,
    y_federation: t_yfed,
    federation_csv_blocks: t_csv,
    last_reset_tm_txid,
  }
}

// The outpoint the Update-Y signature commits to; reused as the spent treasury
// input for every test so find_input resolves and the message matches.
fn t_own_ref() -> OutputReference {
  OutputReference { transaction_id: t_updatey_txid, output_index: 0 }
}

fn t_treasury_value() -> assets.Value {
  assets.from_lovelace(2_000_000) |> assets.add(t_own_hash, t_asset_name, 1)
}

fn t_input(d: TreasuryDatum) -> Input {
  Input {
    output_reference: t_own_ref(),
    output: Output {
      address: Address {
        payment_credential: Script(t_own_hash),
        stake_credential: None,
      },
      value: t_treasury_value(),
      datum: InlineDatum(d),
      reference_script: None,
    },
  }
}

fn t_output(d: TreasuryDatum) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_own_hash),
      stake_credential: None,
    },
    value: t_treasury_value(),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

// A registry token moves — the Register/Deregister marker RegistryUpdate needs.
fn t_registry_mint() -> assets.Value {
  assets.from_asset(t_registry_policy, "reg-root", 1)
}

// RegistryUpdate: only bifrost_identity_root changes; key preserved. Passes.
test spend_registry_update_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      outputs: [t_output(d1)],
      mint: t_registry_mint(),
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    RegistryUpdate { new_bifrost_identity_root: t_root1 },
    t_own_ref(),
    tx,
  )
}

// RegistryUpdate must NOT be able to rotate the key (the resolved contradiction):
// changing current_spos_frost_key on this branch is rejected.
test spend_registry_update_rejects_key_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      outputs: [t_output(d1)],
      mint: t_registry_mint(),
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    RegistryUpdate { new_bifrost_identity_root: t_root1 },
    t_own_ref(),
    tx,
  )
}

// RegistryUpdate requires a registry-policy mint in the same tx.
test spend_registry_update_rejects_no_registry_mint() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    RegistryUpdate { new_bifrost_identity_root: t_root1 },
    t_own_ref(),
    tx,
  )
}

// Update-Y: the outgoing key signs the rotation; only the key changes. Passes.
test spend_update_y_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_new_key,
      epoch: t_updatey_epoch,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// Update-Y with a valid signature but ALSO mutating bifrost_identity_root is
// rejected — only the key may change on this branch.
test spend_update_y_rejects_extra_field_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_new_key,
      epoch: t_updatey_epoch,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// Update-Y with the wrong epoch breaks the signed message → signature fails.
test spend_update_y_rejects_wrong_epoch() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_new_key,
      epoch: t_updatey_epoch + 1,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// Update-Y signed by a key OTHER than the outgoing datum key is rejected.
test spend_update_y_rejects_wrong_signer() fail {
  let d0 = t_datum(t_root0, t_new_key)
  let d1 = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_cur_key,
      epoch: t_updatey_epoch,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// A Confirmed TM reference input carrying the TM NFT (unless `with_nft` is False),
// with the given dead-roster flag + btc_txid.
fn t_tm_ref(with_nft: Bool, flag: Bool, btc_txid: ByteArray) -> Input {
  let base = assets.from_lovelace(2_000_000)
  let value =
    if with_nft {
      base |> assets.add(t_tm_policy, #"", 1)
    } else {
      base
    }
  Input {
    output_reference: OutputReference {
      transaction_id: #"9999999999999999999999999999999999999999999999999999999999999999",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_tm_policy),
        stake_credential: None,
      },
      value: value,
      datum: InlineDatum(
        // Full 8-field shape, matching binocular's real TmDatum.Confirmed (incl. the N7
        // provenance fields). The mirror must decode this exact field count on-chain.
        Confirmed {
          btc_txid,
          swept_peg_in_utxo_ids: [],
          fulfilled_peg_outs: [],
          spent_via_federation_leaf: flag,
          creator: #"9493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e",
          created: 1784900811000,
          epoch: 61,
          leader_reward: 2000000,
        },
      ),
      reference_script: None,
    },
  }
}

fn t_reset_redeemer() -> TreasurySpendRedeemer {
  FederationReset {
    tm_ref_input_index: 0,
    epoch: t_reset_epoch,
    signature: t_reset_sig,
  }
}

// FederationReset: a flagged, authentic, fresh Confirmed TM + the y_fed signature
// rotate the key to y_federation and record the consumed txid. Passes.
test spend_federation_reset_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum_reset(t_root0, t_yfed, t_reset_btc_txid)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_tm_ref(True, True, t_reset_btc_txid)],
      outputs: [t_output(d1)],
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    t_reset_redeemer(),
    t_own_ref(),
    tx,
  )
}

// Reset with the TM flag UNSET (no proof of a federation-leaf sweep) is rejected.
test spend_federation_reset_rejects_flag_false() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum_reset(t_root0, t_yfed, t_reset_btc_txid)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_tm_ref(True, False, t_reset_btc_txid)],
      outputs: [t_output(d1)],
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    t_reset_redeemer(),
    t_own_ref(),
    tx,
  )
}

// Freshness: replaying the SAME sweep that last reset (btc_txid ==
// last_reset_tm_txid) is rejected — a stale federation TM can't reset again.
test spend_federation_reset_rejects_stale_txid() fail {
  let d0 = t_datum_reset(t_root0, t_cur_key, t_reset_btc_txid)
  let d1 = t_datum_reset(t_root0, t_yfed, t_reset_btc_txid)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_tm_ref(True, True, t_reset_btc_txid)],
      outputs: [t_output(d1)],
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    t_reset_redeemer(),
    t_own_ref(),
    tx,
  )
}

// A referenced record WITHOUT the TM NFT is not a trustworthy TM — rejected.
test spend_federation_reset_rejects_no_tm_nft() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum_reset(t_root0, t_yfed, t_reset_btc_txid)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_tm_ref(False, True, t_reset_btc_txid)],
      outputs: [t_output(d1)],
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    t_reset_redeemer(),
    t_own_ref(),
    tx,
  )
}

// The reset may set the key ONLY to y_federation — an arbitrary target is rejected.
test spend_federation_reset_rejects_wrong_target() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum_reset(t_root0, t_new_key, t_reset_btc_txid)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_tm_ref(True, True, t_reset_btc_txid)],
      outputs: [t_output(d1)],
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    t_reset_redeemer(),
    t_own_ref(),
    tx,
  )
}

// A reset with the wrong epoch breaks the signed message → federation sig fails.
test spend_federation_reset_rejects_wrong_epoch() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum_reset(t_root0, t_yfed, t_reset_btc_txid)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_tm_ref(True, True, t_reset_btc_txid)],
      outputs: [t_output(d1)],
    }
  treasury_info.spend(
    t_registry_policy,
    t_tm_policy,
    Some(d0),
    FederationReset {
      tm_ref_input_index: 0,
      epoch: t_reset_epoch + 1,
      signature: t_reset_sig,
    },
    t_own_ref(),
    tx,
  )
}
