use aiken/collection/list
use bifrost/authorizer
use bifrost/utils.{get_config_as_data_list, safe_list_at}
use cardano/address.{Credential, Script}
use cardano/transaction.{OutputReference, Transaction}

validator general_spend(
  withdraw_script_hash: ByteArray,
  config_policy_id: ByteArray,
  config_asset_name: ByteArray,
) {
  spend(
    datum_opt: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    if datum_opt == None {
      let config =
        get_config_as_data_list(
          safe_list_at(self.reference_inputs, 0),
          config_policy_id,
          config_asset_name,
        )
      expect admin_credential: Credential = utils.safe_list_at(config, 1)
      authorizer.authorize_via_credential(
        admin_credential,
        self.withdrawals,
        self.extra_signatories,
      )
    } else {
      list.any(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(script_hash), _amnt) ->
              script_hash == withdraw_script_hash
            _ -> False
          }
        },
      )
    }
  }

  else(_) {
    fail
  }
}
