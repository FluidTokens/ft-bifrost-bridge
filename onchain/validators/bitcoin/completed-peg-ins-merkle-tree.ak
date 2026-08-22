use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use bifrost/constants
use bifrost/types/completed_peg_ins.{CompletedPegInsTrieDatum}
use bifrost/types/config
use bifrost/types/peg_in.{
  Close, CompletePegIn, NeverSwept, PegInWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Credential, Inline, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, Withdraw,
  find_input, placeholder,
}

pub type SpendRedeemer {
  config_ref_input_index: Int,
  peg_in_withdraw_redeemer_index: Int,
}

validator completed_peg_ins_merkle_tree_validator(
  configNFTPolicyId: ByteArray,
  one_shot_input_ref: OutputReference,
) {
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    let is_one_shot_spent =
      option.is_some(find_input(self.inputs, one_shot_input_ref))

    expect [completed_peg_ins_merkle_tree_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    //Exactly one token of this policy, quantity 1, with the constant name
    expect [Pair(minted_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))
    let correct_asset_name =
      minted_asset_name == constants.completed_peg_ins_root_asset_name

    //The minted NFT sits in that same output. The peg-in flow authenticates
    //the trie by this NFT (spec §Complete peg-in: "same NFT, same address"),
    //so a genesis that pays the NFT anywhere else leaves the trie UTxO at
    //this script unauthenticated and puts the real trie, with a root the
    //NFT holder chooses, wherever the NFT goes next. The bridge state
    //bootstrap makes the same check (spec [BSS-5]).
    let output_carries_the_nft =
      quantity_of(
        completed_peg_ins_merkle_tree_output.value,
        policy_id,
        constants.completed_peg_ins_root_asset_name,
      ) == 1

    let output_has_correct_datum =
      completed_peg_ins_merkle_tree_output.datum == InlineDatum(
        CompletedPegInsTrieDatum {
          root: #"0000000000000000000000000000000000000000000000000000000000000000",
        },
      )

    let output_goes_to_this_script =
      completed_peg_ins_merkle_tree_output.address == Address {
        payment_credential: Script(policy_id),
        stake_credential: None,
      }

    and {
      is_one_shot_spent,
      correct_asset_name,
      output_carries_the_nft,
      output_has_correct_datum,
      output_goes_to_this_script,
    }
  }

  spend(
    _datumOpt: Option<Data>,
    redeemer: SpendRedeemer,
    _own_ref: OutputReference,
    self: Transaction,
  ) {
    let config_fields =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        configNFTPolicyId,
        constants.config_nft_asset_name,
      )
    let peg_in_withdraw_script_hash =
      config.get_peg_in_script_hash(config_fields)
    let peg_in_withdraw_redeemer =
      utils.safe_list_at(
        self.redeemers,
        redeemer.peg_in_withdraw_redeemer_index,
      )
    expect
      peg_in_withdraw_redeemer.1st == Withdraw(
        Script(peg_in_withdraw_script_hash),
      )
    expect peg_in_redeemer: PegInWithdrawRedeemer = peg_in_withdraw_redeemer.2nd

    and {
      when peg_in_redeemer.action_type is {
        CompletePegIn { .. } -> True
        _ -> False
      },
      list.any(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(script_hash), _amnt) ->
              script_hash == peg_in_withdraw_script_hash
            _ -> False
          }
        },
      ),
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t_config_policy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const t_cpi_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_peg_in_script_hash: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

const t_other_script_hash: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const t_empty_root: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

const t_nonempty_root: ByteArray =
  #"0101010101010101010101010101010101010101010101010101010101010101"

fn t_one_shot_ref() -> OutputReference {
  OutputReference {
    transaction_id: #"0101010101010101010101010101010101010101010101010101010101010101",
    output_index: 0,
  }
}

fn t_dummy_own_ref() -> OutputReference {
  OutputReference {
    transaction_id: #"2222222222222222222222222222222222222222222222222222222222222222",
    output_index: 0,
  }
}

fn t_wallet_address() -> Address {
  Address {
    payment_credential: Script(
      #"ff999999999999999999999999999999999999999999999999999999",
    ),
    stake_credential: None,
  }
}

fn t_one_shot_input() -> Input {
  Input {
    output_reference: t_one_shot_ref(),
    output: Output {
      address: t_wallet_address(),
      value: assets.from_lovelace(5_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

//The genesis trie output at the policy's own script address. `with_nft`
//False is the guard test: the datum and address are right, the NFT is not
//there.
fn t_trie_output(with_nft: Bool, root: ByteArray) -> Output {
  let base = assets.from_lovelace(2_000_000)
  let value =
    if with_nft {
      base |> assets.add(t_cpi_policy, constants.completed_peg_ins_root_asset_name, 1)
    } else {
      base
    }
  Output {
    address: Address {
      payment_credential: Script(t_cpi_policy),
      stake_credential: None,
    },
    value,
    datum: InlineDatum(CompletedPegInsTrieDatum { root }),
    reference_script: None,
  }
}

//Where the NFT goes in the guard test: a plain wallet output, no datum.
fn t_nft_elsewhere_output() -> Output {
  Output {
    address: t_wallet_address(),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_cpi_policy, constants.completed_peg_ins_root_asset_name, 1),
    datum: NoDatum,
    reference_script: None,
  }
}

fn t_genesis_mint() -> assets.Value {
  assets.from_asset(
    t_cpi_policy,
    constants.completed_peg_ins_root_asset_name,
    1,
  )
}

fn t_mint(tx: Transaction) -> Bool {
  completed_peg_ins_merkle_tree_validator.mint(
    t_config_policy,
    t_one_shot_ref(),
    Void,
    t_cpi_policy,
    tx,
  )
}

//The first eight ConfigDatum fields, in the real order (spec §Config datum;
//the full datum has thirteen). The spend handler reads ONE field: index 6,
//the peg-in withdraw script hash. The rest are placeholders of the right
//Data kind.
fn t_config_datum_data() -> Data {
  builtin.constr_data(
    0,
    [
      //update_auth
      builtin.constr_data(1, []),
      //params
      builtin.constr_data(0, []),
      //bridged_token_policy
      builtin.b_data(#"aa222222222222222222222222222222222222222222222222222222"),
      //completed_peg_ins_policy
      builtin.b_data(t_cpi_policy),
      //bridge_state_policy
      builtin.b_data(#"aa444444444444444444444444444444444444444444444444444444"),
      //tm_script_hash
      builtin.b_data(#"aa333333333333333333333333333333333333333333333333333333"),
      //peg_in_script_hash: the one field this validator reads
      builtin.b_data(t_peg_in_script_hash),
      //peg_out_script_hash
      builtin.b_data(#"aa555555555555555555555555555555555555555555555555555555"),
    ],
  )
}

fn t_config_ref_input(with_nft: Bool) -> Input {
  let base = assets.from_lovelace(2_000_000)
  let value =
    if with_nft {
      base |> assets.add(t_config_policy, constants.config_nft_asset_name, 1)
    } else {
      base
    }
  Input {
    output_reference: OutputReference {
      transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_config_policy),
        stake_credential: None,
      },
      value,
      datum: InlineDatum(t_config_datum_data()),
      reference_script: None,
    },
  }
}

//A peg-in withdraw redeemer whose action is CompletePegIn. The proofs and
//indexes are dummies: this validator only reads the constructor.
fn t_complete_peg_in_redeemer() -> Data {
  let redeemer =
    PegInWithdrawRedeemer {
      config_ref_input_index: 0,
      action_type: CompletePegIn {
        recipient: t_wallet_address(),
        fbtc_output_index: 0,
        depositor_signature: #"",
        completed_peg_in_utxos_input_index: 0,
        completed_peg_in_utxos_output_index: 0,
        added_peg_in_to_completed_peg_ins_inclusion_proof: [],
        peg_in_in_completed_peg_ins_exclusion_proof: [],
        bridge_state_ref_input_index: 1,
        sweeping_tm_input_0: #"",
        peg_in_swept_membership_proof: [],
      },
    }
  let data: Data = redeemer
  data
}

//A peg-in withdraw redeemer whose action is Close: the one other action the
//peg-in withdraw handler runs, and the one this validator must refuse.
fn t_close_redeemer() -> Data {
  let redeemer =
    PegInWithdrawRedeemer {
      config_ref_input_index: 0,
      action_type: Close {
        burnt_peg_in_nft_asset_name: "",
        proof: NeverSwept {
          bridge_state_ref_input_index: 1,
          spi_exclusion_proof: [],
        },
      },
    }
  let data: Data = redeemer
  data
}

fn t_spend_tx(
  withdraw_script_hash: ByteArray,
  peg_in_redeemer: Data,
  withdrawals: Pairs<Credential, Int>,
) -> Transaction {
  Transaction {
    ..placeholder,
    reference_inputs: [t_config_ref_input(True)],
    redeemers: [Pair(Withdraw(Script(withdraw_script_hash)), peg_in_redeemer)],
    withdrawals: withdrawals,
  }
}

fn t_spend(tx: Transaction) -> Bool {
  completed_peg_ins_merkle_tree_validator.spend(
    t_config_policy,
    t_one_shot_ref(),
    None,
    SpendRedeemer { config_ref_input_index: 0, peg_in_withdraw_redeemer_index: 0 },
    t_dummy_own_ref(),
    tx,
  )
}

// --- mint: the genesis of the singleton ------------------------------------

test mint_genesis_happy_path() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output(True, t_empty_root)],
      mint: t_genesis_mint(),
    }
  t_mint(tx)
}

//The guard under test: the datum and the address are right, the NFT is paid
//to a wallet. Before the guard this genesis was accepted.
test mint_rejects_nft_paid_elsewhere() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output(False, t_empty_root), t_nft_elsewhere_output()],
      mint: t_genesis_mint(),
    }
  t_mint(tx)
}

test mint_rejects_missing_one_shot() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [],
      outputs: [t_trie_output(True, t_empty_root)],
      mint: t_genesis_mint(),
    }
  t_mint(tx)
}

test mint_rejects_wrong_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output(True, t_empty_root)],
      mint: assets.from_asset(t_cpi_policy, "NOT-CPI", 1),
    }
  t_mint(tx)
}

test mint_rejects_two_tokens() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output(True, t_empty_root)],
      mint: assets.from_asset(
        t_cpi_policy,
        constants.completed_peg_ins_root_asset_name,
        2,
      ),
    }
  t_mint(tx)
}

test mint_rejects_second_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output(True, t_empty_root)],
      mint: t_genesis_mint() |> assets.add(t_cpi_policy, "junk", 1),
    }
  t_mint(tx)
}

test mint_rejects_nonempty_root() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output(True, t_nonempty_root)],
      mint: t_genesis_mint(),
    }
  t_mint(tx)
}

test mint_rejects_staked_script_address() fail {
  let staked =
    Output {
      ..t_trie_output(True, t_empty_root),
      address: Address {
        payment_credential: Script(t_cpi_policy),
        stake_credential: Some(Inline(Script(t_other_script_hash))),
      },
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [staked],
      mint: t_genesis_mint(),
    }
  t_mint(tx)
}

test mint_rejects_two_script_outputs() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output(True, t_empty_root), t_trie_output(False, t_empty_root)],
      mint: t_genesis_mint(),
    }
  t_mint(tx)
}

//The pinned genesis root is the empty MPF, as the peg-in reader decodes it
//(spec §Bootstrap step 5: "initialized to the empty root").
test genesis_datum_decodes_to_the_empty_trie() {
  t_trie_output(True, t_empty_root)
    |> utils.get_mpf_from_output
    |> mpf.is_empty
}

// --- spend: forwarded to the peg-in withdraw handler -----------------------

test spend_complete_peg_in_happy_path() {
  let tx =
    t_spend_tx(
      t_peg_in_script_hash,
      t_complete_peg_in_redeemer(),
      [Pair(Script(t_peg_in_script_hash), 0)],
    )
  t_spend(tx)
}

test spend_rejects_close_action() fail {
  let tx =
    t_spend_tx(
      t_peg_in_script_hash,
      t_close_redeemer(),
      [Pair(Script(t_peg_in_script_hash), 0)],
    )
  t_spend(tx)
}

test spend_rejects_foreign_withdraw_script() fail {
  let tx =
    t_spend_tx(
      t_other_script_hash,
      t_complete_peg_in_redeemer(),
      [Pair(Script(t_other_script_hash), 0)],
    )
  t_spend(tx)
}

test spend_rejects_missing_withdrawal() fail {
  let tx = t_spend_tx(t_peg_in_script_hash, t_complete_peg_in_redeemer(), [])
  t_spend(tx)
}

test spend_rejects_config_without_nft() fail {
  let tx =
    Transaction {
      ..t_spend_tx(
        t_peg_in_script_hash,
        t_complete_peg_in_redeemer(),
        [Pair(Script(t_peg_in_script_hash), 0)],
      ),
      reference_inputs: [t_config_ref_input(False)],
    }
  t_spend(tx)
}
