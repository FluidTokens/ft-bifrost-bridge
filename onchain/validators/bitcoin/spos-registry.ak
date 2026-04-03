use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}

pub type Datum {
  owner: VerificationKeyHash,
}

pub type Redeemer {
  msg: ByteArray,
}

validator spo_registry {
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
