use aiken/collection/dict
use aiken/crypto
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use bifrost/types/spos_registry.{RegistrationListDatum, RegistrationNodeData}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, placeholder,
}

pub const pool_id_length = 28

pub const evidence_hash_length = 32

pub const bifrost_id_pk_length = 32

pub fn is_pool_id(pool_id: ByteArray) -> Bool {
  bytearray.length(pool_id) == pool_id_length
}

pub fn is_evidence_hash(evidence_hash: ByteArray) -> Bool {
  bytearray.length(evidence_hash) == evidence_hash_length
}

pub fn fault_token_name(
  accused_pool_id: ByteArray,
  evidence_hash: ByteArray,
) -> ByteArray {
  crypto.blake2b_256(bytearray.concat(accused_pool_id, evidence_hash))
}

pub fn read_registered_pool_ref(
  input: Input,
  registration_script_hash: PolicyId,
  pool_id: ByteArray,
) -> ByteArray {
  expect Script(script_hash) = input.output.address.payment_credential
  expect Pair(asset_name, 1) = utils.get_singleton_asset_with_policy(
    input.output.value,
    registration_script_hash,
  )
  expect InlineDatum(raw_datum) = input.output.datum
  expect datum: RegistrationListDatum = raw_datum
  expect linked_list.Node { data: registration_data } = datum.data
  expect script_hash == registration_script_hash
  expect asset_name == pool_id
  expect
    bytearray.length(registration_data.bifrost_id_pk) == bifrost_id_pk_length
  registration_data.bifrost_id_pk
}

pub fn verify_bifrost_signature(
  bifrost_id_pk: ByteArray,
  canonical_payload_bytes: ByteArray,
  payload_signature: ByteArray,
) -> Bool {
  and {
    bytearray.length(bifrost_id_pk) == bifrost_id_pk_length,
    bytearray.length(payload_signature) == 64,
    crypto.verify_schnorr_signature(
      bifrost_id_pk,
      crypto.sha2_256(canonical_payload_bytes),
      payload_signature,
    ),
  }
}

pub fn mint_single_fault_token(
  self: Transaction,
  policy_id: PolicyId,
  accused_pool_id: ByteArray,
  evidence_hash: ByteArray,
) -> Bool {
  let token_name = fault_token_name(accused_pool_id, evidence_hash)
  and {
    utils.quantity_of_policy_id(self.mint, policy_id) == 1,
    quantity_of(self.mint, policy_id, token_name) == 1,
    is_pool_id(accused_pool_id),
    is_evidence_hash(evidence_hash),
  }
}

pub fn burn_single_fault_token(self: Transaction, policy_id: PolicyId) -> Bool {
  expect [Pair(token_name, -1)] = dict.to_pairs(tokens(self.mint, policy_id))
  and {
    utils.quantity_of_policy_id(self.mint, policy_id) == -1,
    bytearray.length(token_name) == evidence_hash_length,
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_registration_policy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const t_fault_policy: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

const t_pool_id: ByteArray =
  #"01010101010101010101010101010101010101010101010101010101"

const t_other_pool_id: ByteArray =
  #"02020202020202020202020202020202020202020202020202020202"

const t_bifrost_id_pk: ByteArray =
  #"0303030303030303030303030303030303030303030303030303030303030303"

const t_evidence_hash: ByteArray =
  #"0404040404040404040404040404040404040404040404040404040404040404"

fn t_registration_input(pool_id: ByteArray, bifrost_id_pk: ByteArray) -> Input {
  let datum: RegistrationListDatum = linked_list.Element {
    data: linked_list.Node {
      data: RegistrationNodeData {
        bifrost_id_pk,
        bifrost_url: "https://spo.example",
      },
    },
    link: None,
  }

  Input {
    output_reference: OutputReference(
      #"1111111111111111111111111111111111111111111111111111111111111111",
      0,
    ),
    output: Output {
      address: Address {
        payment_credential: Script(t_registration_policy),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_registration_policy, pool_id, 1),
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

test read_registered_pool_ref_returns_bifrost_key() {
  read_registered_pool_ref(
    t_registration_input(t_pool_id, t_bifrost_id_pk),
    t_registration_policy,
    t_pool_id,
  ) == t_bifrost_id_pk
}

test read_registered_pool_ref_rejects_wrong_pool() fail {
  let bifrost_id_pk = read_registered_pool_ref(
    t_registration_input(t_pool_id, t_bifrost_id_pk),
    t_registration_policy,
    t_other_pool_id,
  )
  bifrost_id_pk == t_bifrost_id_pk
}

test burn_single_fault_token_accepts_single_burn() {
  let tx = Transaction {
    ..placeholder,
    mint: assets.from_asset(t_fault_policy, t_evidence_hash, -1),
  }
  burn_single_fault_token(tx, t_fault_policy)
}

test burn_single_fault_token_rejects_extra_asset() fail {
  let tx = Transaction {
    ..placeholder,
    mint: assets.from_asset(t_fault_policy, t_evidence_hash, -1)
      |> assets.add(t_fault_policy, "extra", -1),
  }
  expect burn_single_fault_token(tx, t_fault_policy)
}
