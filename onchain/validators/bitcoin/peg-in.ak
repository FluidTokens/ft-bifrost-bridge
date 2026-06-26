use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use aiken/primitive/bytearray
use bifrost/bip322
use bifrost/bitcoin
use bifrost/types/general.{ChainState}
use bifrost/types/peg_in.{
  Cancel, CompletePegIn, PegInDatum, PegInMintRedeemer, PegInRequest,
  PegInWithdrawRedeemer,
}
use bifrost/types/treasury_movement.{Confirmed}
use bifrost/utils
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, PolicyId, quantity_of, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, find_input,
}

// Domain-separation tag "BFR-mint-v1" for the depositor completion-signing message (BIP340
// practice; technical_documentation.md §"Complete peg-in"). Must equal binocular
// BifrostMessages.mintTag.
const mint_tag: ByteArray = #"4246522d6d696e742d7631"

validator peg_in_validator(
  oracle_policy_id: PolicyId,
  config_nft_policy_id: PolicyId,
  config_nft_asset_name: AssetName,
  // Policy id of the TM NFT = the binocular `TreasuryMovementValidator` script hash. The Confirmed
  // TM UTxO referenced at completion must carry this NFT (empty asset name); it is the trust anchor
  // for `btc_txid` + `swept_peg_in_utxo_ids`. Stable (the TM validator is parameterized only by the
  // oracle hash + control NFT, never a participant key), so it does not churn on roster rotation.
  tm_nft_policy_id: PolicyId,
) {
  mint(redeemer: PegInMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent = option.is_some(
      find_input(self.inputs, redeemer.input_ref),
    )

    let minted_positive = list.filter(
      dict.to_pairs(tokens(self.mint, policy_id)),
      fn(Pair(_asset_name, quantity)) { quantity > 0 },
    )
    when minted_positive is {
      // Burn-only (Cancel close): no positive mint under this policy. Permitted — the PIR being
      // burned can only be spent via this script's spend handler, which forces a peg_in withdrawal,
      // and withdraw(Cancel) gates the burn on the config[12] close-verifier delegation. A close tx
      // references no oracle / deposit, so it must not be forced through the mint-time checks below.
      [] -> True
      [Pair(minted_asset_name, 1)] -> {
        //Oracle reference input
        expect Some(oracle_ref_input) = list.find(
          self.reference_inputs,
          fn(input) {
            assets.quantity_of(input.output.value, oracle_policy_id, #"") == 1
          },
        )
        expect InlineDatum(oracle_raw) = oracle_ref_input.output.datum
        expect ChainState { confirmed_blocks_root, .. } = oracle_raw

        expect [peg_in_output] = list.filter(
          self.outputs,
          fn(output) { output.address.payment_credential == Script(policy_id) },
        )

        let peg_in_request = redeemer.new_peg_in_request
        //The PegIn amount must be always > 0
        let peg_in_amount_positive = builtin.un_i_data(
          peg_in_request.expected_datum.peg_in_amount,
        ) > 0

        //AssetName must be input_ref_hash
        let correct_asset_name = minted_asset_name == input_ref_hash

        //Output must have 1 token with quantity 1
        let output_has_unique_token = assets.quantity_of(
          peg_in_output.value,
          policy_id,
          minted_asset_name,
        ) == 1
        //Output must contain proper InlineDatum
        let output_has_correct_datum = peg_in_output.datum == InlineDatum(
          peg_in_request.expected_datum,
        )

        let block_hash = utils.bitcoin_hash(peg_in_request.block_header)
        //Block header must belong to the official source chain
        let block_header_included_in_source_chain = mpf.has(
          mpf.from_root(confirmed_blocks_root),
          block_hash,
          block_hash,
          peg_in_request.block_header_in_source_chain_inclusion_proof,
        )
        let peg_in_request_tx_hash = utils.bitcoin_hash(
          peg_in_request.expected_datum.source_chain_peg_in_raw_tx,
        )
        //Tx must belong to the block
        let peg_in_request_tx_included_in_block_header = bitcoin.verify_tx_merkle_proof(
          peg_in_request_tx_hash,
          peg_in_request.expected_datum.source_chain_peg_in_raw_tx_index,
          peg_in_request.tx_in_block_header_inclusion_proof,
          bitcoin.block_merkle_root(peg_in_request.block_header),
        )

        // Bind the PegInDatum to the (now block-confirmed) deposit tx. Minting is permissionless, so
        // without this an attacker could mint a PIR claiming an arbitrary outpoint / amount / pubkey
        // and then (since B1 embeds the depositor Schnorr auth at completion) sign with THEIR OWN
        // key. The completion's "only the depositor can submit" guarantee is only real if the datum's
        // peg_in_utxo_id / peg_in_amount / user_source_chain_pub_key describe Alice's actual deposit.
        // peg_in_request_tx_hash is the deposit txid (sha256d of the witness-stripped tx — the merkle
        // proof above already forces the stripped serialization). The binding is extracted into
        // bitcoin.deposit_binding_ok (unit-tested there). Closes review findings #1–#4.
        let deposit_bound =
          bitcoin.deposit_binding_ok(
            peg_in_request.expected_datum.source_chain_peg_in_raw_tx,
            peg_in_request_tx_hash,
            peg_in_request.expected_datum.peg_in_utxo_id,
            peg_in_request.expected_datum.peg_in_amount,
            peg_in_request.expected_datum.user_source_chain_pub_key,
          )
        and {
          is_input_ref_spent,
          peg_in_amount_positive,
          correct_asset_name,
          output_has_unique_token,
          output_has_correct_datum,
          block_header_included_in_source_chain,
          peg_in_request_tx_included_in_block_header,
          deposit_bound,
        }
      }
      _ -> False
    }
  }

  withdraw(
    redeemer: PegInWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let config = utils.get_config_as_data_list(
      utils.safe_list_at(self.reference_inputs, redeemer.config_ref_input_index),
      config_nft_policy_id,
      config_nft_asset_name,
    )
    let bridged_token_policy_id = builtin.un_b_data(
      utils.safe_list_at(config, 0),
    )
    let bridged_token_asset_name = builtin.un_b_data(
      utils.safe_list_at(config, 1),
    )
    let completed_peg_ins_merkle_tree_policy_id = builtin.un_b_data(
      utils.safe_list_at(config, 6),
    )
    let completed_peg_ins_merkle_tree_asset_name = builtin.un_b_data(
      utils.safe_list_at(config, 7),
    )
    // config[12] = the peg-in CLOSE verifier script hash (the slot vacated by the retired
    // legit_TM_verifier). The Cancel path delegates the F4/F5 close checks to it (see below). It is
    // a config-NFT field (runtime), so the close verifier can be deployed + wired via a config update
    // with no peg_in recompile / PIR re-mint. Dummy until the F1–F6 failure-mode milestone ships.
    let peg_in_close_verifier_script_hash = builtin.un_b_data(
      utils.safe_list_at(config, 12),
    )
    expect [peg_in_input] = list.filter(
      self.inputs,
      fn(input) { input.output.address.payment_credential == credential },
    )
    when redeemer.action_type is {
      Cancel { burnt_peg_in_nft_asset_name } -> {
        expect Script(peg_in_policy_id) = credential
        //PegIn close authorized by the peg-in CLOSE verifier (config[12]) — the stake-validator
        //delegation pattern. The separate close verifier owns the spec's F4/F5 logic (F4: the
        //depositor reclaimed the BTC on the Bitcoin side via the Taproot CSV refund leaf, proven by
        //a refund-script witness; F5: this PIR is a duplicate, proven by a completed-peg-ins trie
        //inclusion proof). peg_in.ak only requires the verifier's withdrawal is present and burns the
        //PIR NFT; it stays agnostic to the verifier's redeemer. Until that verifier is deployed and
        //wired into config[12] (F1–F6 milestone), config[12] is a dummy hash with no reward account,
        //so this Cancel path is cleanly unsatisfiable.
        let close_authorized = list.any(
          self.withdrawals,
          fn(withdrawal) {
            when withdrawal is {
              Pair(Script(script_hash), _amnt) ->
                script_hash == peg_in_close_verifier_script_hash
              _ -> False
            }
          },
        )
        //Input must contain a PegIn nft
        let peg_in_nft_in_input = quantity_of(
          peg_in_input.output.value,
          peg_in_policy_id,
          burnt_peg_in_nft_asset_name,
        ) == 1
        //The input PegIn nft must be burnt
        let peg_in_nft_burnt = quantity_of(
          self.mint,
          peg_in_policy_id,
          burnt_peg_in_nft_asset_name,
        ) == -1
        and {
          close_authorized,
          peg_in_nft_in_input,
          peg_in_nft_burnt,
        }
      }
      CompletePegIn {
        recipient,
        fbtc_output_index,
        depositor_signature,
        completed_peg_in_utxos_input_index,
        completed_peg_in_utxos_output_index,
        added_peg_in_to_completed_peg_ins_inclusion_proof,
        peg_in_in_completed_peg_ins_exclusion_proof,
      } -> {
        expect InlineDatum(input_datum) = peg_in_input.output.datum
        expect datum: PegInDatum = input_datum

        // 1. Reference the Confirmed TM UTxO, authenticated by the TM NFT (policy = the binocular
        //    TreasuryMovementValidator script hash, empty asset name). The NFT — not the address —
        //    is the trust anchor: it can only be minted under the gated TM policy. We read
        //    `btc_txid` + `swept_peg_in_utxo_ids` straight from its Confirmed datum, which binocular
        //    `confirm-tmtx` populated by parsing the oracle-proven Bitcoin TM. No inline block /
        //    tx-merkle proof is re-run here — that lives only in `confirm-tmtx` now.
        expect Some(confirmed_tm_ref_input) = list.find(
          self.reference_inputs,
          fn(input) {
            quantity_of(input.output.value, tm_nft_policy_id, #"") == 1
          },
        )
        expect InlineDatum(tm_raw) = confirmed_tm_ref_input.output.datum
        expect Confirmed { btc_txid, swept_peg_in_utxo_ids, .. } = tm_raw

        // 2. This peg-in must be among the inputs the confirmed TM swept.
        let peg_in_swept = list.has(swept_peg_in_utxo_ids, datum.peg_in_utxo_id)

        // 3. Depositor authorization (embedded; replaces the owner_auth withdraw delegation):
        //    BIP340 Schnorr over sha2_256("BFR-mint-v1" ‖ btc_txid ‖ peg_in_utxo_id ‖ recipient),
        //    with the datum's user_source_chain_pub_key. `btc_txid` comes from the referenced
        //    Confirmed datum, so the signed TM is provably the confirmed one. Binding `recipient`
        //    into the message + the fBTC output (step 4) makes a leaked signature non-replayable.
        // Depositor authorization via BIP-322 (taproot key-path), so a normal Bitcoin wallet's
        // signMessage(msg,"bip322-simple") suffices — no raw-key access. The depositor signs the
        // ASCII text  "BFR-mint-v1:" ++ hex(binding_digest)  where binding_digest is the same
        // sha256(mint_tag ‖ btc_txid ‖ peg_in_utxo_id ‖ recipient) as before; binding recipient +
        // the confirmed-TM btc_txid + the deposit outpoint keeps a leaked signature non-replayable.
        // user_source_chain_pub_key is the depositor wallet's taproot OUTPUT key (the address's
        // witness program); deposit_binding_ok ties it to the deposit's OP_RETURN beacon.
        let binding_digest = crypto.sha2_256(
          bytearray.concat(
            mint_tag,
            bytearray.concat(
              btc_txid,
              bytearray.concat(
                datum.peg_in_utxo_id,
                builtin.serialise_data(recipient),
              ),
            ),
          ),
        )
        let signed_message =
          mint_tag
            |> bytearray.concat(#"3a")
            |> bytearray.concat(bip322.hex_lower(binding_digest))
        let depositor_authorized =
          bip322.verify_keypath(
            datum.user_source_chain_pub_key,
            signed_message,
            depositor_signature,
          )

        // 4. Recipient-binding: the minted fBTC goes to `recipient` in exactly peg_in_amount.
        let fbtc_output = utils.safe_list_at(self.outputs, fbtc_output_index)
        let fbtc_to_recipient = fbtc_output.address == recipient
        let fbtc_amount_to_recipient = quantity_of(
          fbtc_output.value,
          bridged_token_policy_id,
          bridged_token_asset_name,
        ) == datum.peg_in_amount

        // 5. Completed-peg-ins MPF bookkeeping (unchanged): the peg-in is inserted, was absent
        //    before, and the MPF UTxO keeps its value + address.
        let completed_peg_in_utxos_input = utils.safe_list_at(
          self.inputs,
          completed_peg_in_utxos_input_index,
        )
        //Complete PegIns merkle tree input must have the unique NFT
        expect
          quantity_of(
            completed_peg_in_utxos_input.output.value,
            completed_peg_ins_merkle_tree_policy_id,
            completed_peg_ins_merkle_tree_asset_name,
          ) == 1
        let input_completed_peg_in_merkle_tree = utils.get_mpf_from_output(
          completed_peg_in_utxos_input.output,
        )
        let completed_peg_in_utxos_output = utils.safe_list_at(
          self.outputs,
          completed_peg_in_utxos_output_index,
        )
        //Complete PegIns merkle tree output must have the unique NFT
        expect
          quantity_of(
            completed_peg_in_utxos_output.value,
            completed_peg_ins_merkle_tree_policy_id,
            completed_peg_ins_merkle_tree_asset_name,
          ) == 1
        let output_completed_peg_in_merkle_tree = utils.get_mpf_from_output(
          completed_peg_in_utxos_output,
        )
        //Completed PegIn have been added to the completed PegIns merkle tree
        let added_completed_peg_ins_to_merkle_tree = mpf.insert(
          input_completed_peg_in_merkle_tree,
          datum.peg_in_utxo_id,
          datum.peg_in_utxo_id,
          added_peg_in_to_completed_peg_ins_inclusion_proof,
        ) == output_completed_peg_in_merkle_tree
        //The completed_peg_in_utxos must not change in value
        let same_completed_peg_in_utxos_value = without_lovelace(
          completed_peg_in_utxos_input.output.value,
        ) == without_lovelace(completed_peg_in_utxos_output.value)
        //The completed_peg_in_utxos must not change address
        let same_completed_peg_in_utxos_address = completed_peg_in_utxos_input.output.address == completed_peg_in_utxos_output.address
        //The PegIn must not yet be in the completed_peg_in merkle tree
        let completed_peg_in_exclusion_proven = mpf.miss(
          input_completed_peg_in_merkle_tree,
          datum.peg_in_utxo_id,
          peg_in_in_completed_peg_ins_exclusion_proof,
        )

        let bridged_tokens_minted = quantity_of(
          self.mint,
          bridged_token_policy_id,
          bridged_token_asset_name,
        ) == datum.peg_in_amount
        and {
          peg_in_swept,
          depositor_authorized,
          fbtc_to_recipient,
          fbtc_amount_to_recipient,
          completed_peg_in_exclusion_proven,
          added_completed_peg_ins_to_merkle_tree,
          same_completed_peg_in_utxos_value,
          same_completed_peg_in_utxos_address,
          bridged_tokens_minted,
        }
      }
    }
  }

  spend(
    _datumOpt: Option<Data>,
    _redeemer: Data,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = list.find(
      self.inputs,
      fn(input) { input.output_reference == own_ref },
    )
    expect Script(own_script_hash) = own_input.output.address.payment_credential
    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(script_hash), _amnt) -> script_hash == own_script_hash
          _ -> False
        }
      },
    )
  }

  else(_ctx: ScriptContext) {
    False
  }
}
