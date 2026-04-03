use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/types/general.{AuthorizationMethod}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{AssetName, PolicyId, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, OutputReference, Transaction}

pub type PegOutDatum {
  ownerAuth: AuthorizationMethod,
}

pub type ActionType {
  Cancel
  CompletePegOut
}

pub type PegOutWithdrawRedeemer {
  actionType: ActionType,
}

validator peg_out(
  bridged_token_policy_id: PolicyId,
  bridged_token_asset_name: AssetName,
) {
  withdraw(
    redeemer: PegOutWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let spendScriptCredential = Script("TODO")
    let peg_out_inputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == spendScriptCredential
        },
      )
    when redeemer.actionType is {
      Cancel { .. } ->
        //Every PegOut must be properly authorized and excluded from the Treasury Movement tx
        utils.indexed_all(
          peg_out_inputs,
          fn(index, input) {
            expect InlineDatum(input_datum) = input.output.datum
            expect datum: PegOutDatum = input_datum
            let peg_out_exclusion_proven = True
            let user_authorized =
              authorize_action(
                create_auth(
                  datum.ownerAuth,
                  self.inputs,
                  self.reference_inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              )
            and {
              user_authorized,
              peg_out_exclusion_proven,
            }
          },
        )
      CompletePegOut { .. } -> {
        let bridged_token_spent_amount =
          list.foldr(
            peg_out_inputs,
            0,
            fn(input, result) {
              result + quantity_of(
                input.output.value,
                bridged_token_policy_id,
                bridged_token_asset_name,
              )
            },
          )
        let all_bridged_tokens_burnt =
          quantity_of(
            self.mint,
            bridged_token_policy_id,
            bridged_token_asset_name,
          ) == bridged_token_spent_amount
        and {
          //Every PegOut must be properly authorized and included in the Treasury Movement tx
          utils.indexed_all(
            peg_out_inputs,
            fn(index, input) {
              expect InlineDatum(input_datum) = input.output.datum
              expect datum: PegOutDatum = input_datum
              let peg_out_inclusion_proven = True
              let user_authorized =
                authorize_action(
                  create_auth(
                    datum.ownerAuth,
                    self.inputs,
                    self.reference_inputs,
                    self.withdrawals,
                    self.extra_signatories,
                    self.mint,
                  ),
                )
              and {
                user_authorized,
                peg_out_inclusion_proven,
              }
            },
          ),
          //All the pegged out tokens must be burnt
          all_bridged_tokens_burnt,
        }
      }
    }
  }

  spend(
    datumOpt: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    let withdrawScriptHash = "TODO"
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

  else(_ctx: ScriptContext) {
    False
  }
}
