use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Credential}
use cardano/assets.{Value}
use cardano/transaction.{Input}

pub type AuthorizationMethod {
  CardanoSignature { hash: ByteArray }
  CardanoSpendScript { hash: ByteArray }
  CardanoWithdrawScript { hash: ByteArray }
  CardanoMintScript { hash: ByteArray }
  CardanoTokenOwnership { policy_id: ByteArray, asset_name: ByteArray }
}

pub type Authorization {
  CardanoSignatureAuth {
    hash: ByteArray,
    extra_signatories: List<VerificationKeyHash>,
  }
  CardanoSpendScriptAuth { hash: ByteArray, inputs: List<Input> }
  CardanoWithdrawScriptAuth {
    hash: ByteArray,
    withdrawals: Pairs<Credential, Int>,
  }
  CardanoMintScriptAuth { hash: ByteArray, mint: Value }
  CardanoTokenOwnershipAuth {
    policy_id: ByteArray,
    asset_name: ByteArray,
    inputs: List<Input>,
    ref_inputs: List<Input>,
    withdrawals: Pairs<Credential, Int>,
  }
}

// Binocular oracle ChainState datum
pub type ChainState {
  confirmed_blocks_root: ByteArray,
  ctx: Data,
  pending: Data,
}
