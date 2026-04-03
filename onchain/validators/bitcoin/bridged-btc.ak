use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}

pub type Datum {
  owner: VerificationKeyHash,
}

pub type Redeemer {
  msg: ByteArray,
}

validator bridged_btc {
  mint(redeemer: Redeemer, policy_id: PolicyId, self: Transaction) {
    True
  }

  else(_ctx: ScriptContext) {
    False
  }
}
