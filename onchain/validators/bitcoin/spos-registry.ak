use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use bifrost/types/spos_registry.{
  ListRootData, RegistrationListDatum, RegistrationNodeData,
  SposRegistryMintRedeemer, SposRegistrySpendRedeemer,
}
use bifrost/constants
use bifrost/types/config as config_types
use bifrost/types/treasury.{TreasuryDatum}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, Value, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, find_input,
  placeholder,
}

const registration_root_key = constants.registration_root_asset_name

const registration_node_key_prefix = ""

const registration_node_key_prefix_length = 0

const registration_domain_separator = "bifrost-spo"

const revocation_domain_separator = "bifrost-revoke"

// spec [REG-10], [DRG-6]: both messages end with a 36-byte nonce outpoint, and
// that suffix is the whole of what makes the signatures single-use.
//
// Everything else either message commits to is the same for every registration
// of a pool: the domain separator, the pool id (blake2b_224 of a cold key that
// does not change), and for registration the identity key and URL the operator
// declares. The signatures ride in the redeemer, so they are public from the
// first transaction that carries them. Before the nonce, a published exit
// signature therefore stayed valid against every later registration of the
// same pool — postable by anyone, from any wallet, with the freed node lovelace
// landing in the poster's change — and a published registration signature could
// put a pool that had left back into the registry, where the roster faults it
// and the ban list records that against the real pool.
//
// The nonce is an outpoint the registrant chooses among UTxOs under its own
// payment key, which the transaction must spend. An outpoint is spendable once,
// so the signatures fit one transaction; the spend needs the registrant's
// payment witness, so a leaked signature file is useless from any other wallet;
// and a failed attempt spends nothing, so a retry needs no second trip to the
// air-gapped cold key. Deliberately NOT the Treasury state outpoint, which
// every other pool's activity consumes, nor the anchor, which any neighbour
// rewrites: a cold signature bound to either dies at a stranger's choice.
fn registration_message(
  pool_id: ByteArray,
  bifrost_id_pk: ByteArray,
  bifrost_url: ByteArray,
  nonce_outpoint: ByteArray,
) -> ByteArray {
  registration_domain_separator
    |> bytearray.concat(pool_id)
    |> bytearray.concat(bifrost_id_pk)
    |> bytearray.concat(bifrost_url)
    |> bytearray.concat(nonce_outpoint)
}

fn revocation_message(
  pool_id: ByteArray,
  nonce_outpoint: ByteArray,
) -> ByteArray {
  revocation_domain_separator
    |> bytearray.concat(pool_id)
    |> bytearray.concat(nonce_outpoint)
}

// The outpoint of the input the redeemer names, in the encoding both messages
// commit to. Shared with treasury.ak's Update-Y preimage, so there is one
// definition of the little-endian index and an off-chain signer cannot match
// one and miss the other.
fn nonce_outpoint_of(self: Transaction, nonce_input_index: Int) -> ByteArray {
  utils.safe_list_at(self.inputs, nonce_input_index).output_reference
    |> utils.serialise_output_reference
}

fn get_treasury_datum(output: Output) -> TreasuryDatum {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: TreasuryDatum = raw_datum
  datum
}

fn get_registration_node_data(output: Output) -> RegistrationNodeData {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: RegistrationListDatum = raw_datum
  when datum.data is {
    linked_list.Node { data } -> data
    linked_list.Root { .. } -> fail @"Registration output must be a node"
  }
}

fn validate_registration_anchor_data(
  anchor_key: Option<ByteArray>,
  anchor_data: Data,
) -> Bool {
  when anchor_key is {
    None -> {
      expect _: ListRootData = anchor_data
      True
    }
    Some(_) -> {
      expect _: RegistrationNodeData = anchor_data
      True
    }
  }
}

fn validate_root_data(_root_lovelace: Int, root_data: Data) -> Bool {
  validate_registration_anchor_data(None, root_data)
}

fn validate_bootstrap_root(
  outputs: List<Output>,
  tx_mint: Value,
  policy_id: PolicyId,
  root_key: ByteArray,
) -> Bool {
  let root_output =
    utils.find_singleton_asset_output_at_script(
      outputs,
      policy_id,
      policy_id,
      root_key,
    )

  linked_list.init(True, root_output, tx_mint, validate_root_data)
    |> linked_list.run_root_with(policy_id, root_key)
}

fn updated_treasury_datum(
  treasury_input_datum: TreasuryDatum,
  new_bifrost_identity_root: ByteArray,
) -> TreasuryDatum {
  // Registration/deregistration changes ONLY the identity root; the frost key
  // and the federation fields are preserved (record-update spread — matches
  // treasury.ak's RegistryUpdate branch, and stays correct across datum shape
  // changes).
  TreasuryDatum {
    ..treasury_input_datum,
    bifrost_identity_root: new_bifrost_identity_root,
  }
}

// spec [REG-6], [REG-7], [REG-8]: the treasury input and output are located by
// redeemer index, so they MUST be authenticated before their datums are
// trusted. Without the pin the indexes may name ANY UTxO carrying a datum of
// the right shape, and the [REG-5] absence proof then runs against a trie the
// registrant chose: the registry list gains a real membership token while the
// real identity root never moves, defeating the global uniqueness of
// bifrost_id_pk that [REG-5] and [DRG-4] exist to enforce.
fn treasury_state_transition_ok(
  self: Transaction,
  treasury_input_index: Int,
  treasury_output_index: Int,
  new_bifrost_identity_root: ByteArray,
  treasury_policy_id: PolicyId,
) -> Bool {
  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_output = utils.safe_list_at(self.outputs, treasury_output_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)
  let treasury_output_datum = get_treasury_datum(treasury_output)

  and {
    utils.treasury_state_pinned(
      treasury_input,
      treasury_output,
      treasury_policy_id,
    ),
    treasury_output_datum == updated_treasury_datum(
      treasury_input_datum,
      new_bifrost_identity_root,
    ),
  }
}

fn validate_bootstrap(
  self: Transaction,
  policy_id: PolicyId,
  bootstrap_ref: OutputReference,
) -> Bool {
  expect Some(_bootstrap_input) = find_input(self.inputs, bootstrap_ref)

  and {
    utils.quantity_of_policy_id(self.mint, policy_id) == 1,
    quantity_of(self.mint, policy_id, registration_root_key) == 1,
    // No list exists yet, so nothing may be spent and exactly the root is
    // produced. The same bound the other three branches carry.
    registry_elements_touched(self, policy_id) == (0, 1),
    validate_bootstrap_root(
      self.outputs,
      self.mint,
      policy_id,
      registration_root_key,
    ),
  }
}

fn validate_registration(
  redeemer: SposRegistryMintRedeemer,
  policy_id: PolicyId,
  self: Transaction,
  treasury_policy_id: PolicyId,
) -> Bool {
  expect SposRegistryMintRedeemer.Register {
    cold_vkey,
    cold_sig,
    bifrost_sig,
    nonce_input_index,
    registration_anchor_input_index,
    registration_anchor_output_index,
    treasury_input_index,
    treasury_output_index,
    bifrost_identity_absence_proof,
  } = redeemer

  expect Pair(pool_id, 1) =
    utils.get_singleton_asset_with_policy(self.mint, policy_id)

  // spec [REG-10]: rebuilt from the transaction, never taken from the redeemer.
  let nonce_outpoint = nonce_outpoint_of(self, nonce_input_index)

  let anchor_input =
    utils.safe_list_at(self.inputs, registration_anchor_input_index)
  let continued_anchor_output =
    utils.safe_list_at(self.outputs, registration_anchor_output_index)
  let new_registration_output =
    utils.find_singleton_asset_output_at_script(
      self.outputs,
      policy_id,
      policy_id,
      pool_id,
    )
  let RegistrationNodeData { bifrost_id_pk, bifrost_url } =
    get_registration_node_data(new_registration_output)

  let registration_linked_list_ok =
    linked_list.insert_ascending(
      anchor_input,
      continued_anchor_output,
      new_registration_output,
      self.mint,
      fn(
        anchor_lovelace_change,
        anchor_key,
        anchor_data,
        _new_node_lovelace,
        new_node_key,
        new_node_data,
        _new_node_link,
      ) {
        expect parsed_new_node_data: RegistrationNodeData = new_node_data

        let message =
          registration_message(
            new_node_key,
            parsed_new_node_data.bifrost_id_pk,
            parsed_new_node_data.bifrost_url,
            nonce_outpoint,
          )

        and {
          validate_registration_anchor_data(anchor_key, anchor_data),
          anchor_lovelace_change == 0,
          new_node_key == pool_id,
          parsed_new_node_data == RegistrationNodeData {
            bifrost_id_pk,
            bifrost_url,
          },
          crypto.blake2b_224(cold_vkey) == new_node_key,
          crypto.verify_ed25519_signature(cold_vkey, message, cold_sig),
          crypto.verify_schnorr_signature(
            bifrost_id_pk,
            crypto.sha2_256(message),
            bifrost_sig,
          ),
        }
      },
    )
      |> linked_list.run_eval_with(
          policy_id,
          registration_root_key,
          registration_node_key_prefix,
          registration_node_key_prefix_length,
        )

  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)

  let updated_bifrost_identity_root =
    mpf.insert(
      mpf.from_root(treasury_input_datum.bifrost_identity_root),
      bifrost_id_pk,
      pool_id,
      bifrost_identity_absence_proof,
    )
      |> mpf.root

  and {
    registration_linked_list_ok,
    // spec [REG-11]: the anchor in, the continued anchor and the new node out,
    // and no other list element on either side.
    registry_elements_touched(self, policy_id) == (1, 2),
    treasury_state_transition_ok(
      self,
      treasury_input_index,
      treasury_output_index,
      updated_bifrost_identity_root,
      treasury_policy_id,
    ),
  }
}

fn validate_deregistration(
  redeemer: SposRegistryMintRedeemer,
  policy_id: PolicyId,
  self: Transaction,
  treasury_policy_id: PolicyId,
) -> Bool {
  expect SposRegistryMintRedeemer.Deregister {
    cold_vkey,
    cold_sig,
    nonce_input_index,
    registration_input_index,
    registration_anchor_input_index,
    registration_anchor_output_index,
    treasury_input_index,
    treasury_output_index,
    bifrost_identity_removal_proof,
  } = redeemer

  expect Pair(pool_id, -1) =
    utils.get_singleton_asset_with_policy(self.mint, policy_id)

  // spec [DRG-6]: as [REG-10], rebuilt from the transaction.
  let nonce_outpoint = nonce_outpoint_of(self, nonce_input_index)

  let registration_input =
    utils.safe_list_at(self.inputs, registration_input_index)
  let registration_anchor_input =
    utils.safe_list_at(self.inputs, registration_anchor_input_index)
  let continued_anchor_output =
    utils.safe_list_at(self.outputs, registration_anchor_output_index)
  let RegistrationNodeData { bifrost_id_pk, bifrost_url: _bifrost_url } =
    get_registration_node_data(registration_input.output)

  let deregistration_linked_list_ok =
    linked_list.remove(
      registration_anchor_input,
      registration_input,
      continued_anchor_output,
      self.mint,
      fn(
        anchor_lovelace_change,
        anchor_key,
        anchor_data,
        _removed_node_lovelace,
        removed_node_key,
        removed_node_data,
        _removed_node_link,
      ) {
        expect parsed_removed_node_data: RegistrationNodeData =
          removed_node_data
        let message = revocation_message(removed_node_key, nonce_outpoint)

        and {
          validate_registration_anchor_data(anchor_key, anchor_data),
          anchor_lovelace_change == 0,
          removed_node_key == pool_id,
          parsed_removed_node_data.bifrost_id_pk == bifrost_id_pk,
          crypto.blake2b_224(cold_vkey) == removed_node_key,
          crypto.verify_ed25519_signature(cold_vkey, message, cold_sig),
        }
      },
    )
      |> linked_list.run_eval_with(
          policy_id,
          registration_root_key,
          registration_node_key_prefix,
          registration_node_key_prefix_length,
        )

  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)

  let updated_bifrost_identity_root =
    mpf.delete(
      mpf.from_root(treasury_input_datum.bifrost_identity_root),
      bifrost_id_pk,
      pool_id,
      bifrost_identity_removal_proof,
    )
      |> mpf.root

  and {
    deregistration_linked_list_ok,
    // spec [DRG-7]: the anchor and the node being removed in, the continued
    // anchor out. Nothing else.
    registry_elements_touched(self, policy_id) == (2, 1),
    // spec [DRG-5]: [REG-6] to [REG-8] apply unchanged to Deregister.
    treasury_state_transition_ok(
      self,
      treasury_input_index,
      treasury_output_index,
      updated_bifrost_identity_root,
      treasury_policy_id,
    ),
  }
}

// How many of the transaction's inputs and outputs carry a token of this
// policy — that is, how many registry-list elements the transaction touches.
//
// spec [REG-11], [DRG-7], [MIG-7]. The registry's SPEND handler authorizes
// spending any list element on one condition: that the transaction mints
// something under this policy. That was survivable while every mint carried a
// cold signature, because the only party who could open the door was the pool
// whose door it was. `Migrate` needs no signature at all and anyone may submit
// it, so during a migration window the door would be open to the public: a
// valid migration for some pool, with three other pools' node UTxOs added as
// inputs and their NFTs paid to the submitter's own address. Both handlers
// would accept, and the list would be left dangling — the predecessors still
// link to nodes that no longer exist — which every node reads as a broken list
// and no node can repair.
//
// So each branch declares exactly how many elements it may touch, and nothing
// else can ride along. Reference inputs are not counted and must not be: the
// old node a migration reads sits under the PREVIOUS policy, and is referenced
// rather than spent.
fn registry_elements_touched(
  self: Transaction,
  policy_id: PolicyId,
) -> (Int, Int) {
  let spent =
    list.count(
      self.inputs,
      fn(input) { utils.quantity_of_policy_id(input.output.value, policy_id) > 0 },
    )
  let produced =
    list.count(
      self.outputs,
      fn(output) { utils.quantity_of_policy_id(output.value, policy_id) > 0 },
    )
  (spent, produced)
}

// The Config datum's raw fields, authenticated by the parameterized NFT.
// spec [MIG-5]/[REG-9]: located by redeemer index, never by scanning
// reference_inputs — a scan that finds nothing picks a wrong UTxO instead of
// failing. Same rule, same shape, as treasury.ak's config_fields_at.
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

// spec [MIG-1] to [MIG-6], §SPO Registration section 8.
//
// A registry revision is a new script hash and so a new membership-token
// policy. The registrations under the old policy are still the roster's
// consent, and the identity trie in the Treasury state still commits to every
// one of them, so nothing about them needs re-authorizing. Migration says
// exactly that: reference the old node, prove its binding against the trie,
// mint the same pool_id under this policy with the old datum verbatim.
//
// There is no cold signature and no Bifrost signature here, and that is the
// point rather than an omission. The branch reproduces state the pool already
// consented to and can change nothing else, so anyone may submit it and pay the
// new node's min ADA. That is what lets an operator cross a revision by
// installing a package, and lets the federation carry the stragglers so the
// next boundary snapshot of the new list equals the old roster.
fn validate_migration(
  redeemer: SposRegistryMintRedeemer,
  policy_id: PolicyId,
  self: Transaction,
  treasury_policy_id: PolicyId,
  config_policy_id: PolicyId,
) -> Bool {
  expect SposRegistryMintRedeemer.Migrate {
    old_node_ref_input_index,
    config_ref_input_index,
    treasury_ref_input_index,
    registration_anchor_input_index,
    registration_anchor_output_index,
    bifrost_identity_membership_proof,
  } = redeemer

  expect Pair(pool_id, 1) =
    utils.get_singleton_asset_with_policy(self.mint, policy_id)

  // spec [MIG-1]: the previous policy comes from Config #13, not from a compile
  // parameter. A parameter would make every registry revision cascade into the
  // next one's script hash, and heimdall cannot recover parameters from script
  // bytes — it reads the field the same way this does.
  let config_fields =
    config_fields_at(self, config_policy_id, config_ref_input_index)
  let previous_policy_id =
    config_types.get_previous_spos_registry_policy_id(config_fields)
  // Checked FIRST, and as an expect rather than a conjunct, because everything
  // below reads the old node THROUGH this policy id. A zero-length field means
  // no migration is in progress ([CFG-10]), and then there is no previous
  // registry to carry anything across from.
  expect previous_policy_id != ""

  let old_node_ref =
    utils.safe_list_at(self.reference_inputs, old_node_ref_input_index)
  expect Script(old_node_script_hash) =
    old_node_ref.output.address.payment_credential
  expect Pair(old_node_asset_name, 1) =
    utils.get_singleton_asset_with_policy(
      old_node_ref.output.value,
      previous_policy_id,
    )
  let old_node_data = get_registration_node_data(old_node_ref.output)

  let old_node_pinned = and {
      // The registry address is the policy id: one multi-purpose validator
      // mints the tokens and guards the list.
      old_node_script_hash == previous_policy_id,
      old_node_asset_name == pool_id,
    }

  // spec [MIG-5]: [REG-6] applied to a REFERENCE input. The Treasury state is
  // read, not moved, but it is still located by redeemer index, so without the
  // pin the membership proof would run against a trie the submitter chose.
  let treasury_ref =
    utils.safe_list_at(self.reference_inputs, treasury_ref_input_index)
  let treasury_datum = get_treasury_datum(treasury_ref.output)

  // spec [MIG-6]: the Treasury state must not be an INPUT. This branch
  // validates no treasury transition, and treasury.ak's RegistryUpdate takes
  // any registry mint as its marker ([TSY-13]) without checking the root it
  // writes — so a migration that also spent the Treasury state could rewrite
  // bifrost_identity_root at will. That is the hole [TSY-23] closed for
  // Bootstrap, reopened here unless this check exists.
  let treasury_not_spent =
    list.all(
      self.inputs,
      fn(input) {
        !utils.holds_treasury_state_nft(input.output, treasury_policy_id)
      },
    )

  let anchor_input =
    utils.safe_list_at(self.inputs, registration_anchor_input_index)
  let continued_anchor_output =
    utils.safe_list_at(self.outputs, registration_anchor_output_index)
  let new_registration_output =
    utils.find_singleton_asset_output_at_script(
      self.outputs,
      policy_id,
      policy_id,
      pool_id,
    )

  // spec [MIG-4]: [REG-4] unchanged. Well-formed insertion into the current
  // list is also what rejects a second migration of the same pool: a key
  // already in the list cannot sit strictly between two adjacent keys.
  let migration_linked_list_ok =
    linked_list.insert_ascending(
      anchor_input,
      continued_anchor_output,
      new_registration_output,
      self.mint,
      fn(
        anchor_lovelace_change,
        anchor_key,
        anchor_data,
        _new_node_lovelace,
        new_node_key,
        new_node_data,
        _new_node_link,
      ) {
        expect parsed_new_node_data: RegistrationNodeData = new_node_data

        and {
          validate_registration_anchor_data(anchor_key, anchor_data),
          anchor_lovelace_change == 0,
          // spec [MIG-2]: the old registration, carried across unchanged.
          new_node_key == pool_id,
          parsed_new_node_data == old_node_data,
        }
      },
    )
      |> linked_list.run_eval_with(
          policy_id,
          registration_root_key,
          registration_node_key_prefix,
          registration_node_key_prefix_length,
        )

  and {
    old_node_pinned,
    // spec [MIG-7]: the same bound as [REG-11], and the branch that needs it
    // most — this is the only registry mint that carries no signature, so it is
    // the only one a stranger can build. Without it a valid migration is a
    // licence to spend every other pool's node in the same transaction.
    registry_elements_touched(self, policy_id) == (1, 2),
    utils.holds_treasury_state_nft(treasury_ref.output, treasury_policy_id),
    treasury_not_spent,
    // spec [MIG-3]: the binding is already the treasury's truth, so this is a
    // MEMBERSHIP proof and the root does not move. Register's [REG-5] absence
    // proof would be unsatisfiable here, which is exactly why a revision
    // needed this branch rather than an exit-and-rejoin by every operator.
    mpf.has(
      mpf.from_root(treasury_datum.bifrost_identity_root),
      old_node_data.bifrost_id_pk,
      pool_id,
      bifrost_identity_membership_proof,
    ),
    migration_linked_list_ok,
  }
}

// spec [REG-6]: treasury_policy_id is a COMPILE PARAMETER, and it can be one
// only because rev 5.5 broke the cycle. treasury_info used to take
// registry_policy_id, which made the treasury policy a function of this one, so
// this parameter would have been self-referential. treasury.ak now reads the
// registry policy from the Config datum instead.
// spec [PRE-3]: config_policy_id is the one identity safe to bake in. The
// Config UTxO is the root of the identity graph and its policy id depends only
// on its own one-shot outpoint, so it cannot be redeployed out from under this
// script the way a sibling policy can. The Migrate branch reads Config #13
// through it ([MIG-1]).
validator spo_registry(
  bootstrap_tx_id: ByteArray,
  bootstrap_output_index: Int,
  treasury_policy_id: PolicyId,
  config_policy_id: PolicyId,
) {
  mint(
    redeemer: SposRegistryMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    let bootstrap_ref = OutputReference(bootstrap_tx_id, bootstrap_output_index)

    when redeemer is {
      SposRegistryMintRedeemer.Bootstrap ->
        validate_bootstrap(self, policy_id, bootstrap_ref)
      SposRegistryMintRedeemer.Register { .. } ->
        validate_registration(redeemer, policy_id, self, treasury_policy_id)
      SposRegistryMintRedeemer.Deregister { .. } ->
        validate_deregistration(redeemer, policy_id, self, treasury_policy_id)
      SposRegistryMintRedeemer.Migrate { .. } ->
        validate_migration(
          redeemer,
          policy_id,
          self,
          treasury_policy_id,
          config_policy_id,
        )
    }
  }

  spend(
    _datum: Option<Data>,
    _redeemer: SposRegistrySpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential

    utils.quantity_of_policy_id(self.mint, own_hash) != 0
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests: the Treasury state pin
//
// spec [REG-6], [REG-7], [REG-8]. Before the pin existed,
// treasury_state_transition_ok took the treasury input and output from redeemer
// indexes and checked nothing but the datum transition. A registrant could
// point those indexes at a wallet UTxO carrying a TreasuryDatum-shaped datum,
// satisfy the [REG-5] absence proof against a trie it chose, and register a
// duplicate bifrost_id_pk while the real identity root stood still.
//
// These call treasury_state_transition_ok directly. A full Register fixture
// would need a linked-list anchor, an Ed25519 vector, a BIP340 vector and an
// MPF proof, none of which this change touches.
//----------------------------------------------------------------------------

const t_treasury_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_root0: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

const t_root1: ByteArray =
  #"1111111111111111111111111111111111111111111111111111111111111111"

const t_frost_key: ByteArray =
  #"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

fn t_treasury_address() -> Address {
  Address {
    payment_credential: Script(t_treasury_policy),
    stake_credential: None,
  }
}

fn t_treasury_value(with_nft: Bool) -> Value {
  let base = assets.from_lovelace(2_000_000)
  if with_nft {
    base
      |> assets.add(t_treasury_policy, constants.treasury_info_nft_asset_name, 1)
  } else {
    base
  }
}

fn t_treasury_output(
  root: ByteArray,
  key: ByteArray,
  with_nft: Bool,
  address: Address,
) -> Output {
  Output {
    address: address,
    value: t_treasury_value(with_nft),
    datum: InlineDatum(
      TreasuryDatum { bifrost_identity_root: root, current_spos_frost_key: key },
    ),
    reference_script: None,
  }
}

fn t_treasury_input(root: ByteArray, with_nft: Bool) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"4444444444444444444444444444444444444444444444444444444444444444",
      output_index: 0,
    },
    output: t_treasury_output(root, t_frost_key, with_nft, t_treasury_address()),
  }
}

fn t_transition_tx(
  treasury_input: Input,
  treasury_output: Output,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [treasury_input],
    outputs: [treasury_output],
  }
}

test treasury_transition_happy() {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, t_frost_key, True, t_treasury_address()),
    )
  treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-6]: the decoy attack. A datum-shaped wallet UTxO is not the
// Treasury state UTxO.
test treasury_transition_rejects_decoy_input() {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, False),
      t_treasury_output(t_root1, t_frost_key, False, t_treasury_address()),
    )
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-7]: the NFT must continue into the output.
test treasury_transition_rejects_output_without_nft() {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, t_frost_key, False, t_treasury_address()),
    )
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-8]: and it must stay at treasury.ak.
test treasury_transition_rejects_moved_output() {
  let elsewhere =
    Address {
      payment_credential: Script(
        #"ff111111111111111111111111111111111111111111111111111111",
      ),
      stake_credential: None,
    }
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, t_frost_key, True, elsewhere),
    )
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// The datum rule the pin does not replace: the registry may move the identity
// root and nothing else.
test treasury_transition_rejects_key_change() {
  let other_key =
    #"abababababababababababababababababababababababababababababababab"
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, other_key, True, t_treasury_address()),
    )
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

//----------------------------------------------------------------------------
// Tests: Register, Deregister and Migrate, end to end through the validator
//
// spec [REG-10], [DRG-6], [MIG-1] to [MIG-6]. The comment above used to say a
// full Register fixture "would need a linked-list anchor, an Ed25519 vector, a
// BIP340 vector and an MPF proof, none of which this change touches". The
// nonce touches all four, so here they are.
//
// The signature vectors are real, produced from the same seeds heimdall's own
// register/deregister tests use (cold seed [42; 32], Bifrost seckey [7; 32]),
// over the same fixture pool, URL and nonce outpoint. So the golden bytes in
// heimdall and the vectors here pin ONE message format from both sides: a
// change to either concatenation breaks both suites, not just one.
//
// The MPF proofs are the empty list, which is the honest proof shape for a trie
// holding zero or one entry: excluding(k, []) is the empty root, and
// including(k, v, []) is the root of the one-entry trie. That keeps the
// fixtures free of hand-copied trie internals without weakening what they
// check, since the nonce and the migration are what is under test here, not
// the MPF library.
//----------------------------------------------------------------------------

const t_registry_policy: ByteArray =
  #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

// The policy a migration comes FROM: the registry as it was deployed before
// this revision.
const t_prev_registry_policy: ByteArray =
  #"b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"

// A third registry policy, named by nothing in Config.
const t_stranger_registry_policy: ByteArray =
  #"d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3"

const t_config_policy: ByteArray =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

const t_bootstrap_tx: ByteArray =
  #"0909090909090909090909090909090909090909090909090909090909090909"

// Vectors, generated from cold seed [42; 32] and Bifrost seckey [7; 32].
const t_cold_vkey: ByteArray =
  #"197f6b23e16c8532c6abc838facd5ea789be0c76b2920334039bfa8b3d368d61"

// blake2b_224(t_cold_vkey).
const t_pool_id: ByteArray = #"1dfb74a8cbcda254c65b5dd5d95df89f60b28b11de4da2ded3bc1f9b"

const t_bifrost_id_pk: ByteArray =
  #"989c0b76cb563971fdc9bef31ec06c3560f3249d6ee9e5d83c57625596e05f6f"

const t_bifrost_url: ByteArray = "https://spo.example/bifrost"

// The nonce UTxO: an ordinary wallet outpoint under the registrant's own key.
const t_nonce_txid: ByteArray =
  #"7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a"

const t_nonce_index: Int = 3

// A different outpoint, for the replay negatives.
const t_other_txid: ByteArray =
  #"5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c"

// Ed25519 by the cold key over
// "bifrost-spo" ‖ pool_id ‖ bifrost_id_pk ‖ url ‖ nonce_outpoint.
const t_reg_cold_sig: ByteArray =
  #"29ac35010421fa833005bb99d79a4d74133b87bb8971108153654d51ec69874bffcbe75a98689c8cc861cf5b103318cf950012ab0dbc83d2a5b236fefaa9c90c"

// BIP340 by the Bifrost key over sha2_256 of the same message.
const t_reg_bifrost_sig: ByteArray =
  #"d733690a20a8db055d0a156d1b68049447b548b97331619ae6b0860c285100151f8aad2c644f54a68fa9eeb362951c62e4dba26aa2a0492587af26dfcf8c5510"

// Ed25519 by the cold key over "bifrost-revoke" ‖ pool_id ‖ nonce_outpoint.
const t_rev_cold_sig: ByteArray =
  #"ddedbcbfcabe7a93e4b12e09b2af3f81e1efef86c8210adf9a6e0d16f65e6304e50692ed336210122b6f6c951ed41f7968f556278501b1dadca6a223adcd520d"

fn t_script_address(hash: ByteArray) -> Address {
  Address { payment_credential: Script(hash), stake_credential: None }
}

// A UTxO holding exactly ADA plus one list NFT — the shape
// linked_list.authenticate_element_utxo_and_get_info demands.
fn t_element_output(
  script_hash: ByteArray,
  policy_id: PolicyId,
  asset_name: ByteArray,
  datum: RegistrationListDatum,
) -> Output {
  Output {
    address: t_script_address(script_hash),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(policy_id, asset_name, 1),
    datum: InlineDatum(datum),
    reference_script: None,
  }
}

fn t_root_datum(link: Option<ByteArray>) -> RegistrationListDatum {
  linked_list.Element { data: linked_list.Root { data: ListRootData }, link }
}

fn t_node_datum(url: ByteArray) -> RegistrationListDatum {
  linked_list.Element {
    data: linked_list.Node {
      data: RegistrationNodeData {
        bifrost_id_pk: t_bifrost_id_pk,
        bifrost_url: url,
      },
    },
    link: None,
  }
}

fn t_anchor_output(policy_id: PolicyId, link: Option<ByteArray>) -> Output {
  t_element_output(
    policy_id,
    policy_id,
    registration_root_key,
    t_root_datum(link),
  )
}

fn t_anchor_input(policy_id: PolicyId, link: Option<ByteArray>) -> Input {
  Input {
    output_reference: OutputReference(t_bootstrap_tx, 1),
    output: t_anchor_output(policy_id, link),
  }
}

fn t_node_output(policy_id: PolicyId, url: ByteArray) -> Output {
  t_element_output(policy_id, policy_id, t_pool_id, t_node_datum(url))
}

fn t_node_input(policy_id: PolicyId, url: ByteArray) -> Input {
  Input {
    output_reference: OutputReference(t_bootstrap_tx, 2),
    output: t_node_output(policy_id, url),
  }
}

// The registrant's own wallet UTxO, whose outpoint both messages commit to.
fn t_wallet_input(txid: ByteArray, index: Int) -> Input {
  Input {
    output_reference: OutputReference(txid, index),
    output: Output {
      address: Address {
        payment_credential: address.VerificationKey(
          #"e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1",
        ),
        stake_credential: None,
      },
      value: assets.from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn t_nonce_input() -> Input {
  t_wallet_input(t_nonce_txid, t_nonce_index)
}

// The identity trie before and after the pool's entry exists. Computed with the
// library rather than pasted, so these stay right if the MPF encoding changes.
fn t_root_without_entry() -> ByteArray {
  mpf.root(mpf.empty)
}

fn t_root_with_entry() -> ByteArray {
  mpf.insert(mpf.empty, t_bifrost_id_pk, t_pool_id, [])
    |> mpf.root
}

fn t_state_output(root: ByteArray) -> Output {
  t_treasury_output(root, t_frost_key, True, t_treasury_address())
}

fn t_state_input(root: ByteArray) -> Input {
  Input {
    output_reference: OutputReference(t_bootstrap_tx, 3),
    output: t_state_output(root),
  }
}

fn t_config_datum(previous_registry: PolicyId) -> config_types.ConfigDatum {
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
    treasury_info_policy_id: t_treasury_policy,
    y_federation: #"aa11",
    federation_one_shot: OutputReference(#"aa12", 12),
    previous_spos_registry_policy_id: previous_registry,
  }
}

fn t_config_ref(previous_registry: PolicyId) -> Input {
  Input {
    output_reference: OutputReference(t_bootstrap_tx, 4),
    output: Output {
      address: t_script_address(t_config_policy),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_config_policy, constants.config_nft_asset_name, 1),
      datum: InlineDatum(t_config_datum(previous_registry)),
      reference_script: None,
    },
  }
}

fn t_mint(quantity: Int) -> Value {
  assets.from_asset(t_registry_policy, t_pool_id, quantity)
}

fn t_mint_registry(policy_id: PolicyId, quantity: Int) -> Value {
  assets.from_asset(policy_id, t_pool_id, quantity)
}

// The validator under test, with its four compile parameters bound.
fn t_mint_validator(
  redeemer: SposRegistryMintRedeemer,
  tx: Transaction,
) -> Bool {
  spo_registry.mint(
    t_bootstrap_tx,
    0,
    t_treasury_policy,
    t_config_policy,
    redeemer,
    t_registry_policy,
    tx,
  )
}

//---- Register --------------------------------------------------------------

// inputs  [0] nonce, [1] anchor, [2] treasury state
// outputs [0] continued anchor, [1] new node, [2] treasury state
fn t_register_tx(nonce: Input, url: ByteArray) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [nonce, t_anchor_input(t_registry_policy, None),
      t_state_input(t_root_without_entry())],
    outputs: [t_anchor_output(t_registry_policy, Some(t_pool_id)),
      t_node_output(t_registry_policy, url),
      t_state_output(t_root_with_entry())],
    mint: t_mint(1),
  }
}

fn t_register_redeemer(nonce_input_index: Int) -> SposRegistryMintRedeemer {
  SposRegistryMintRedeemer.Register {
    cold_vkey: t_cold_vkey,
    cold_sig: t_reg_cold_sig,
    bifrost_sig: t_reg_bifrost_sig,
    nonce_input_index,
    registration_anchor_input_index: 1,
    registration_anchor_output_index: 0,
    treasury_input_index: 2,
    treasury_output_index: 2,
    bifrost_identity_absence_proof: [],
  }
}

test register_happy() {
  t_mint_validator(
    t_register_redeemer(0),
    t_register_tx(t_nonce_input(), t_bifrost_url),
  )
}

// spec [REG-10]: the signatures name ONE outpoint. Spend a different UTxO and
// the message the validator rebuilds is not the message that was signed.
//
// This is the replay the nonce exists to stop. Before rev 5.6 the message
// carried nothing transaction-specific, so this fixture — the same signatures,
// a different transaction — was a VALID registration.
test register_rejects_different_nonce_utxo() fail {
  t_mint_validator(
    t_register_redeemer(0),
    t_register_tx(t_wallet_input(t_other_txid, 1), t_bifrost_url),
  )
}

// And the index must name the input that was signed, not merely some input the
// transaction happens to spend.
test register_rejects_nonce_index_pointing_elsewhere() fail {
  t_mint_validator(
    t_register_redeemer(1),
    t_register_tx(t_nonce_input(), t_bifrost_url),
  )
}

// The rest of the message is still covered: the URL is in the preimage, so a
// node datum that does not match what was signed fails.
test register_rejects_tampered_url() fail {
  t_mint_validator(
    t_register_redeemer(0),
    t_register_tx(t_nonce_input(), "https://attacker.example/bifrost"),
  )
}

//---- Deregister ------------------------------------------------------------

// inputs  [0] nonce, [1] anchor, [2] the node being removed, [3] treasury state
// outputs [0] continued anchor, [1] treasury state
fn t_deregister_tx(nonce: Input) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [nonce, t_anchor_input(t_registry_policy, Some(t_pool_id)),
      t_node_input(t_registry_policy, t_bifrost_url),
      t_state_input(t_root_with_entry())],
    outputs: [t_anchor_output(t_registry_policy, None),
      t_state_output(t_root_without_entry())],
    mint: t_mint(-1),
  }
}

fn t_deregister_redeemer(nonce_input_index: Int) -> SposRegistryMintRedeemer {
  SposRegistryMintRedeemer.Deregister {
    cold_vkey: t_cold_vkey,
    cold_sig: t_rev_cold_sig,
    nonce_input_index,
    registration_input_index: 2,
    registration_anchor_input_index: 1,
    registration_anchor_output_index: 0,
    treasury_input_index: 3,
    treasury_output_index: 1,
    bifrost_identity_removal_proof: [],
  }
}

test deregister_happy() {
  t_mint_validator(t_deregister_redeemer(0), t_deregister_tx(t_nonce_input()))
}

// spec [DRG-6]: the one that matters most. A revocation signature is public
// from the moment the exit lands and "bifrost-revoke" ‖ pool_id is the same
// for every registration of the same cold key, so without the nonce this
// fixture — the identical signature, a later transaction from a stranger's
// wallet — was a valid exit.
test deregister_rejects_different_nonce_utxo() fail {
  t_mint_validator(
    t_deregister_redeemer(0),
    t_deregister_tx(t_wallet_input(t_other_txid, 1)),
  )
}

test deregister_rejects_nonce_index_pointing_elsewhere() fail {
  t_mint_validator(t_deregister_redeemer(1), t_deregister_tx(t_nonce_input()))
}

//---- Migrate ---------------------------------------------------------------

// reference inputs [0] old node, [1] treasury state, [2] Config
// inputs           [0] submitter's wallet, [1] anchor
// outputs          [0] continued anchor, [1] new node
fn t_migrate_tx(
  old_node: Input,
  previous_registry: PolicyId,
  identity_root: ByteArray,
  new_url: ByteArray,
  extra_inputs: List<Input>,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: list.concat(
      [t_wallet_input(t_other_txid, 1), t_anchor_input(t_registry_policy, None)],
      extra_inputs,
    ),
    reference_inputs: [old_node, t_state_input(identity_root),
      t_config_ref(previous_registry)],
    outputs: [t_anchor_output(t_registry_policy, Some(t_pool_id)),
      t_node_output(t_registry_policy, new_url)],
    mint: t_mint(1),
  }
}

fn t_old_node_ref(policy_id: PolicyId, url: ByteArray) -> Input {
  Input {
    output_reference: OutputReference(t_bootstrap_tx, 5),
    output: t_element_output(policy_id, policy_id, t_pool_id, t_node_datum(url)),
  }
}

fn t_migrate_redeemer() -> SposRegistryMintRedeemer {
  SposRegistryMintRedeemer.Migrate {
    old_node_ref_input_index: 0,
    config_ref_input_index: 2,
    treasury_ref_input_index: 1,
    registration_anchor_input_index: 1,
    registration_anchor_output_index: 0,
    bifrost_identity_membership_proof: [],
  }
}

fn t_migrate_happy_tx() -> Transaction {
  t_migrate_tx(
    t_old_node_ref(t_prev_registry_policy, t_bifrost_url),
    t_prev_registry_policy,
    t_root_with_entry(),
    t_bifrost_url,
    [],
  )
}

// spec [MIG-1] to [MIG-6]: no cold signature, no Bifrost signature, and the
// identity root untouched. This is the whole of what an operator's upgrade has
// to do to cross a registry revision.
test migrate_happy() {
  t_mint_validator(t_migrate_redeemer(), t_migrate_happy_tx())
}

// spec [MIG-2]: the old registration goes across VERBATIM. Migration is not an
// opportunity to change what the pool consented to, and nobody signed the new
// URL.
test migrate_rejects_changed_datum() fail {
  t_mint_validator(
    t_migrate_redeemer(),
    t_migrate_tx(
      t_old_node_ref(t_prev_registry_policy, t_bifrost_url),
      t_prev_registry_policy,
      t_root_with_entry(),
      "https://attacker.example/bifrost",
      [],
    ),
  )
}

// spec [MIG-3]: the binding must be in the trie the Treasury state commits to.
// A root that does not contain it is a registration the treasury never knew,
// which is how an unregistered pool would otherwise mint itself a membership
// token.
test migrate_rejects_proof_against_wrong_root() fail {
  t_mint_validator(
    t_migrate_redeemer(),
    t_migrate_tx(
      t_old_node_ref(t_prev_registry_policy, t_bifrost_url),
      t_prev_registry_policy,
      t_root_without_entry(),
      t_bifrost_url,
      [],
    ),
  )
}

// spec [MIG-1]: the old node must sit under the policy Config #13 names. Any
// other list is a list the submitter could have created.
test migrate_rejects_node_under_unnamed_policy() fail {
  t_mint_validator(
    t_migrate_redeemer(),
    t_migrate_tx(
      t_old_node_ref(t_stranger_registry_policy, t_bifrost_url),
      t_prev_registry_policy,
      t_root_with_entry(),
      t_bifrost_url,
      [],
    ),
  )
}

// spec [CFG-10]/[MIG-1]: a zero-length field means no migration is in
// progress, and then this branch has nothing to carry anything across from.
test migrate_rejects_when_no_migration_in_progress() fail {
  t_mint_validator(
    t_migrate_redeemer(),
    t_migrate_tx(
      t_old_node_ref(t_prev_registry_policy, t_bifrost_url),
      "",
      t_root_with_entry(),
      t_bifrost_url,
      [],
    ),
  )
}

// spec [MIG-6]: the Treasury state must not be an input. treasury.ak's
// RegistryUpdate takes any registry mint as its marker without checking the
// root it writes, so a migration that also spent the Treasury state could
// rewrite bifrost_identity_root at will — and this branch, which validates no
// treasury transition, would have nothing to say about it.
test migrate_rejects_spending_the_treasury_state() fail {
  t_mint_validator(
    t_migrate_redeemer(),
    t_migrate_tx(
      t_old_node_ref(t_prev_registry_policy, t_bifrost_url),
      t_prev_registry_policy,
      t_root_with_entry(),
      t_bifrost_url,
      [t_state_input(t_root_with_entry())],
    ),
  )
}

// The Config reference must carry the Config NFT, or #13 is whatever the
// submitter wrote in a datum of their own.
test migrate_rejects_unauthenticated_config() fail {
  let forged =
    Input {
      ..t_config_ref(t_prev_registry_policy),
      output: Output {
        ..t_config_ref(t_prev_registry_policy).output,
        value: assets.from_lovelace(2_000_000),
      },
    }
  let tx = t_migrate_happy_tx()
  t_mint_validator(
    t_migrate_redeemer(),
    Transaction {
      ..tx,
      reference_inputs: [t_old_node_ref(t_prev_registry_policy, t_bifrost_url),
        t_state_input(t_root_with_entry()), forged],
    },
  )
}

// spec [MIG-5]/[REG-6]: the Treasury state reference is located by redeemer
// index, so it must be authenticated by its NFT. Otherwise the membership
// proof runs against a trie the submitter chose, which is the [REG-6] attack
// with a reference input in place of a spent one.
test migrate_rejects_unauthenticated_treasury_reference() fail {
  let decoy =
    Input {
      ..t_state_input(t_root_with_entry()),
      output: t_treasury_output(
        t_root_with_entry(),
        t_frost_key,
        False,
        t_treasury_address(),
      ),
    }
  let tx = t_migrate_happy_tx()
  t_mint_validator(
    t_migrate_redeemer(),
    Transaction {
      ..tx,
      reference_inputs: [t_old_node_ref(t_prev_registry_policy, t_bifrost_url),
        decoy, t_config_ref(t_prev_registry_policy)],
    },
  )
}

// The previous list is not a mint authority: migrating must mint under THIS
// policy, and a transaction that mints nothing here never reaches the branch.
test migrate_rejects_mint_under_previous_policy() fail {
  let tx = t_migrate_happy_tx()
  t_mint_validator(
    t_migrate_redeemer(),
    Transaction { ..tx, mint: t_mint_registry(t_prev_registry_policy, 1) },
  )
}

//----------------------------------------------------------------------------
// Tests: what a registry transaction may touch
//
// spec [REG-11], [DRG-7], [MIG-7]. The spend handler lets any list element be
// spent by any transaction that mints under this policy. Before rev 5.6 every
// such mint carried a cold signature, so the only party who could open that
// door was the pool whose door it was. `Migrate` carries no signature and
// anyone may submit it, which turns the same door into a public one.
//
// The attack these close: a genuine migration for some pool, plus another
// pool's node UTxO as an extra input and its membership NFT paid out to the
// submitter. Every check the branch makes still passes — it validates the
// anchor, the continued anchor and the new node, and looks at nothing else —
// and the list is left dangling, with the victim's predecessor pointing at a
// node that no longer exists. No node can read the list after that, and no
// transaction can repair it.
//----------------------------------------------------------------------------

const t_victim_pool_id: ByteArray =
  #"99999999999999999999999999999999999999999999999999999999"

fn t_victim_node_input(policy_id: PolicyId) -> Input {
  Input {
    output_reference: OutputReference(t_bootstrap_tx, 9),
    output: t_element_output(
      policy_id,
      policy_id,
      t_victim_pool_id,
      t_node_datum(t_bifrost_url),
    ),
  }
}

// The victim's membership token, carried off to the submitter's own address.
fn t_stolen_output(policy_id: PolicyId) -> Output {
  Output {
    address: Address {
      payment_credential: address.VerificationKey(
        #"e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1",
      ),
      stake_credential: None,
    },
    value: assets.from_lovelace(2_000_000)
      |> assets.add(policy_id, t_victim_pool_id, 1),
    datum: NoDatum,
    reference_script: None,
  }
}

// spec [MIG-7]. The one that matters: an unsigned branch anyone can build.
test migrate_rejects_carrying_off_another_pools_node() fail {
  let tx = t_migrate_happy_tx()
  t_mint_validator(
    t_migrate_redeemer(),
    Transaction {
      ..tx,
      inputs: list.concat(tx.inputs, [t_victim_node_input(t_registry_policy)]),
      outputs: list.concat(tx.outputs, [t_stolen_output(t_registry_policy)]),
    },
  )
}

// spec [REG-11]. Signed, so it takes the registrant's own cold key — but a
// pool has no business spending its neighbours' nodes either.
test register_rejects_carrying_off_another_pools_node() fail {
  let tx = t_register_tx(t_nonce_input(), t_bifrost_url)
  t_mint_validator(
    t_register_redeemer(0),
    Transaction {
      ..tx,
      inputs: list.concat(tx.inputs, [t_victim_node_input(t_registry_policy)]),
      outputs: list.concat(tx.outputs, [t_stolen_output(t_registry_policy)]),
    },
  )
}

// spec [DRG-7].
test deregister_rejects_carrying_off_another_pools_node() fail {
  let tx = t_deregister_tx(t_nonce_input())
  t_mint_validator(
    t_deregister_redeemer(0),
    Transaction {
      ..tx,
      inputs: list.concat(tx.inputs, [t_victim_node_input(t_registry_policy)]),
      outputs: list.concat(tx.outputs, [t_stolen_output(t_registry_policy)]),
    },
  )
}

// And the subtler half: leaving a list element OUT of the outputs destroys it
// just as effectively as moving it, so the bound is on both sides.
test migrate_rejects_an_extra_element_output() fail {
  let tx = t_migrate_happy_tx()
  t_mint_validator(
    t_migrate_redeemer(),
    Transaction {
      ..tx,
      outputs: list.concat(tx.outputs, [t_stolen_output(t_registry_policy)]),
    },
  )
}

// spec [REG-11] applied to Bootstrap: (0, 1).
//
// The branch with no test until now, and the one where a mistake is most
// expensive: it runs exactly once per bridge, and getting it wrong means
// redeploying the registry and every script parameterized by it. There is no
// list to spend from yet, so nothing may be spent and exactly the root is
// produced.

fn t_genesis_tx(
  extra_inputs: List<Input>,
  extra_outputs: List<Output>,
) -> Transaction {
  // The one-shot outpoint the validator is parameterized by, which Bootstrap
  // requires the transaction to spend.
  let one_shot =
    Input {
      output_reference: OutputReference(t_bootstrap_tx, 0),
      output: t_wallet_input(t_other_txid, 7).output,
    }
  Transaction {
    ..placeholder,
    inputs: list.concat([one_shot], extra_inputs),
    outputs: list.concat(
      [t_anchor_output(t_registry_policy, None)],
      extra_outputs,
    ),
    mint: assets.from_asset(t_registry_policy, registration_root_key, 1),
  }
}

test bootstrap_happy() {
  t_mint_validator(SposRegistryMintRedeemer.Bootstrap, t_genesis_tx([], []))
}

// A bootstrap has no list to spend from. An input carrying a token of this
// policy at genesis could only be one minted in the same transaction, and the
// singleton mint is the root — so this is the shape that would carry the root
// itself off to a wallet while a second copy sat at the script.
test bootstrap_rejects_an_element_input() fail {
  t_mint_validator(
    SposRegistryMintRedeemer.Bootstrap,
    t_genesis_tx([t_victim_node_input(t_registry_policy)], []),
  )
}

test bootstrap_rejects_a_second_element_output() fail {
  t_mint_validator(
    SposRegistryMintRedeemer.Bootstrap,
    t_genesis_tx([], [t_stolen_output(t_registry_policy)]),
  )
}
