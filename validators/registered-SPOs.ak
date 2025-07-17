use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken_design_patterns/linked_list/ordered.{NodeDatum}
use bifrost/constants
use bifrost/types/registered_spos.{
  Deinit, Deregister, Init, Register, RegisteredSposDatum,
  RegisteredSposMintRedeemer, RegisteredSposSpendRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, PolicyId, flatten, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, Transaction, find_input,
}

validator mint(config_policy_id: PolicyId, config_asset_name: ByteArray) {
  mint(
    redeemer: RegisteredSposMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    when redeemer is {
      Init -> {
        expect
          Pair(config_asset_name, 1) == utils.get_singleton_asset_with_policy(
            self.mint,
            config_policy_id,
          )
        Pair(constants.registered_spos_asset_name, 1) == utils.get_singleton_asset_with_policy(
          self.mint,
          policy_id,
        )
      }
      Deinit -> {
        expect
          Pair(config_asset_name, -1) == utils.get_singleton_asset_with_policy(
            self.mint,
            config_policy_id,
          )
        Pair(constants.registered_spos_asset_name, -1) == utils.get_singleton_asset_with_policy(
          self.mint,
          policy_id,
        )
      }
      Register { .. } -> todo
      Deregister { .. } -> todo
    }
  }

  else(_) {
    fail
  }
}

validator spend(
  registered_operators_policy_id: PolicyId,
  active_operators_policy_id: PolicyId,
  scheduler_policy_id: PolicyId,
) {
  spend(
    opt_datum: Option<RegisteredSposDatum>,
    redeemer: RegisteredSposSpendRedeemer,
    inputOutRef: OutputReference,
    self: Transaction,
  ) {
    expect Some(datum) = opt_datum
    expect Some(input) =
      list.find(
        self.inputs,
        fn(a_input) { a_input.output_reference == inputOutRef },
      )
    when redeemer is {
      _ -> todo
    }
  }

  else(_) {
    fail
  }
}
