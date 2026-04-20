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

validator treasury_movement {
  mint(_redeemer: Redeemer, _policy_id: PolicyId, _self: Transaction) {
    True
  }

  spend(
    _datum: Option<Datum>,
    _redeemer: Redeemer,
    _own_ref: OutputReference,
    _self: Transaction,
  ) {
    True
  }

  else(_ctx: ScriptContext) {
    False
  }
}
