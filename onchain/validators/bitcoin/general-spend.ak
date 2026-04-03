use aiken/collection/list
use bifrost/authorizer
use bifrost/utils.{get_config_as_data_list, safe_list_at}
use cardano/address.{Credential, Script}
use cardano/transaction.{OutputReference, Transaction}

validator general_spend(
  withdrawScriptHash: ByteArray,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  spend(
    datumOpt: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    if datumOpt == None {
      let config =
        get_config_as_data_list(
          safe_list_at(self.reference_inputs, 0),
          configNFTPolicyId,
          configNFTAssetName,
        )
      expect adminCredential: Credential = utils.safe_list_at(config, 1)
      authorizer.authorize_via_credential(
        adminCredential,
        self.withdrawals,
        self.extra_signatories,
      )
    } else {
      list.any(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(scriptHash), _amnt) -> scriptHash == withdrawScriptHash
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
