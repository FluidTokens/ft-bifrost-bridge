use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
use bifrost/constants
use bifrost/types/completed_peg_ins.{CompletedPegInsTrieDatum}
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference}

pub fn hash_output_ref(outputRef: OutputReference) -> ByteArray {
  outputRef |> builtin.serialise_data |> crypto.sha2_256
}

/// An `OutputReference` as the 36 bytes a signed message commits to:
/// `transaction_id` (32 B) followed by `output_index` as a 4-byte
/// little-endian integer.
///
/// ONE encoding, shared by every message in this tree that names an outpoint:
/// `treasury.ak`'s Update-Y rotation preimage ([UY-3]) and
/// `spos-registry.ak`'s registration and revocation nonces ([REG-10],
/// [DRG-6]). It is a separate function because two copies of an endianness
/// choice is one copy too many: an off-chain signer that matched the first and
/// not the second would produce signatures this tree rejects with nothing to
/// point at.
///
/// The fixed 36-byte width is also what keeps the registration message
/// unambiguous. That message ends with a variable-length URL followed by this,
/// so a suffix of known length is the only thing that stops the two from being
/// re-split.
pub fn serialise_output_reference(output_ref: OutputReference) -> ByteArray {
  output_ref.transaction_id
    |> bytearray.concat(
        bytearray.from_int_little_endian(output_ref.output_index, 4),
      )
}

pub fn safe_list_at(self: List<a>, index: Int) -> a {
  expect index >= 0
  do_list_at(self, index)
}

fn do_list_at(self: List<a>, index: Int) -> a {
  if index == 0 {
    builtin.head_list(self)
  } else {
    do_list_at(builtin.tail_list(self), index - 1)
  }
}

pub fn get_config_as_data_list(
  configRefInput: Input,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  expect
    quantity_of(
      configRefInput.output.value,
      configNFTPolicyId,
      configNFTAssetName,
    ) > 0
  expect InlineDatum(outputDatum) = configRefInput.output.datum
  builtin.unconstr_fields(outputDatum)
}

/// Returns the quantity of all tokens with the policyId
pub fn quantity_of_policy_id(value: Value, policyId: PolicyId) {
  dict.foldl(tokens(value, policyId), 0, fn(_k, v, result) { v + result })
}

// Used to retrieve a singleton asset from a value with a specific policy id
pub fn get_singleton_asset_with_policy(
  value: Value,
  policy_id: PolicyId,
) -> Pair<AssetName, Int> {
  expect [p] =
    value
      |> assets.tokens(policy_id)
      //return dict of policy id to asset name and quantity
      |> dict.to_pairs

  p
}

pub fn find_singleton_asset_output_at_script(
  outputs: List<Output>,
  script_hash: ByteArray,
  policy_id: PolicyId,
  asset_name: AssetName,
) -> Output {
  expect Some(output) =
    list.find(
      outputs,
      fn(output) {
        output.address.payment_credential == Script(script_hash) && quantity_of(
          output.value,
          policy_id,
          asset_name,
        ) == 1
      },
    )

  output
}

//Expects the merkle root to be the first field of the InlineDatum
/// The completed-peg-ins trie from a CPI-trie UTxO's inline datum.
///
/// A TYPED decode, not a blind field-0 read. The rule is the one [LIB-1]
/// states for the singleton and [CTM-27] states for Confirm, and it applies to
/// every datum in this tree EXCEPT `ConfigDatum`: only the Config UTxO must
/// stay append-extensible, because every contract is parameterized by its NFT
/// and so the Config alone cannot be swapped. Every other datum sits behind a
/// Config-updatable script hash, so pinning its exact shape costs nothing —
/// a datum change ships as a new validator plus a Config Update.
///
/// The blind form this replaces (`unconstr_fields |> head_list |> un_b_data`)
/// accepted ANY constructor tag and ANY arity. That is not academic here: the
/// CONTINUING output's datum is chosen by whoever builds the completion, so
/// `Constr 5 [root, junk]` would have been accepted at the trie address and
/// every stricter reader downstream — on-chain or off — would then fail on a
/// datum the protocol never describes.
pub fn get_mpf_from_output(output: Output) -> mpf.MerklePatriciaForestry {
  expect InlineDatum(datum) = output.datum
  expect trie: CompletedPegInsTrieDatum = datum
  mpf.from_root(trie.root)
}

pub fn bitcoin_hash(bytes: ByteArray) -> ByteArray {
  crypto.sha2_256(crypto.sha2_256(bytes))
}

/// The check that a UTxO presented as the Treasury state UTxO really is it.
///
/// spec [REG-6], [REG-7], [REG-8]. Before this existed `spos-registry.ak`
/// located the Treasury state UTxO by redeemer index alone, so a registrant
/// could point the index at a wallet UTxO carrying a `TreasuryDatum`-shaped
/// datum, satisfy the [REG-5] absence proof against a trie it chose, and
/// register a duplicate `bifrost_id_pk` while the real identity root stood
/// still.
///
/// The address equality is not redundant with the NFT checks. The NFT proves
/// which token is present; the address is what keeps the continuing UTxO under
/// `treasury.ak`'s control.
pub fn treasury_state_pinned(
  treasury_input: Input,
  treasury_output: Output,
  treasury_policy_id: PolicyId,
) -> Bool {
  and {
    holds_treasury_state_nft(treasury_input.output, treasury_policy_id),
    holds_treasury_state_nft(treasury_output, treasury_policy_id),
    treasury_output.address == treasury_input.output.address,
  }
}

/// The input half of [treasury_state_pinned](#treasury_state_pinned), for a
/// branch that READS the Treasury state without moving it.
///
/// spec [MIG-5]: `spos-registry.ak`'s `Migrate` takes the Treasury state as a
/// REFERENCE input, because the binding it proves is already the treasury's
/// truth and the root does not change. There is no continuing output to pin,
/// but the [REG-6] reason is unchanged: the reference is located by redeemer
/// index, so without this check the membership proof would run against a trie
/// the submitter chose.
pub fn holds_treasury_state_nft(
  output: Output,
  treasury_policy_id: PolicyId,
) -> Bool {
  quantity_of(
    output.value,
    treasury_policy_id,
    constants.treasury_info_nft_asset_name,
  ) == 1
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_treasury_policy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const t_other_policy: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

fn t_treasury_address() -> Address {
  Address {
    payment_credential: Script(t_treasury_policy),
    stake_credential: None,
  }
}

fn t_pin_value(policy: ByteArray, name: ByteArray, qty: Int) -> Value {
  assets.from_lovelace(2_000_000) |> assets.add(policy, name, qty)
}

fn t_pin_output(value: Value, address: Address) -> Output {
  Output {
    address: address,
    value: value,
    datum: NoDatum,
    reference_script: None,
  }
}

fn t_pin_input(value: Value, address: Address) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111",
      output_index: 0,
    },
    output: t_pin_output(value, address),
  }
}

fn t_good_value() -> Value {
  t_pin_value(t_treasury_policy, constants.treasury_info_nft_asset_name, 1)
}

// spec [REG-6], [REG-7], [REG-8]: a real Treasury state UTxO passes.
test treasury_state_pinned_happy() {
  treasury_state_pinned(
    t_pin_input(t_good_value(), t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-6]: an input with no Treasury state NFT is rejected. This is the
// decoy the registry accepted before the pin existed.
test treasury_state_pinned_rejects_input_without_nft() {
  !treasury_state_pinned(
    t_pin_input(assets.from_lovelace(2_000_000), t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-6]: the right name under a foreign policy is not the NFT.
test treasury_state_pinned_rejects_foreign_policy() {
  let forged =
    t_pin_value(t_other_policy, constants.treasury_info_nft_asset_name, 1)
  !treasury_state_pinned(
    t_pin_input(forged, t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-6]: the right policy under a wrong name is not the NFT.
test treasury_state_pinned_rejects_wrong_name() {
  let forged = t_pin_value(t_treasury_policy, "NOTBFR", 1)
  !treasury_state_pinned(
    t_pin_input(forged, t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-7]: the NFT must continue into the output.
test treasury_state_pinned_rejects_output_without_nft() {
  !treasury_state_pinned(
    t_pin_input(t_good_value(), t_treasury_address()),
    t_pin_output(assets.from_lovelace(2_000_000), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-8]: the output must stay at the same address.
test treasury_state_pinned_rejects_moved_output() {
  let elsewhere =
    Address {
      payment_credential: Script(t_other_policy),
      stake_credential: None,
    }
  !treasury_state_pinned(
    t_pin_input(t_good_value(), t_treasury_address()),
    t_pin_output(t_good_value(), elsewhere),
    t_treasury_policy,
  )
}

// spec [REG-6]: two copies is not one.
test treasury_state_pinned_rejects_quantity_two() {
  let doubled =
    t_pin_value(t_treasury_policy, constants.treasury_info_nft_asset_name, 2)
  !treasury_state_pinned(
    t_pin_input(doubled, t_treasury_address()),
    t_pin_output(doubled, t_treasury_address()),
    t_treasury_policy,
  )
}
