use aiken/builtin
use aiken/collection/dict.{to_pairs}
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use bifrost/types/general.{
  Authorization, AuthorizationMethod, CardanoMintScript, CardanoMintScriptAuth,
  CardanoSignature, CardanoSignatureAuth, CardanoSpendScript,
  CardanoSpendScriptAuth, CardanoWithdrawScript, CardanoWithdrawScriptAuth,
}
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{Lovelace, Value, quantity_of, tokens}
use cardano/transaction.{Input, Output}

pub fn create_auth(
  method: AuthorizationMethod,
  transaction_inputs: List<Input>,
  withdrawals: Pairs<Credential, Lovelace>,
  extra_signatories: List<VerificationKeyHash>,
  transaction_mint: Value,
) {
  when method is {
    CardanoSignature { hash } ->
      CardanoSignatureAuth { hash, extra_signatories }
    CardanoSpendScript { hash } ->
      CardanoSpendScriptAuth { hash, transaction_inputs }
    CardanoWithdrawScript { hash } ->
      CardanoWithdrawScriptAuth { hash, withdrawals }
    CardanoMintScript { hash } ->
      CardanoMintScriptAuth { hash, transaction_mint }
  }
}

pub fn authorize_action(auth: Authorization) -> Bool {
  when auth is {
    // If the authorization method is PubKey, validate using the provided signature.
    CardanoSignatureAuth { hash, extra_signatories } ->
      list.has(extra_signatories, hash)
    // If the authorization method is SpendScript, ensure the Utxo is present in the transaction inputs.
    CardanoSpendScriptAuth { hash, transaction_inputs } -> {
      let auth_cred = Script(hash)
      list.any(
        transaction_inputs,
        fn(input) {
          let Input { output, .. } = input
          let Output { address: out_address, .. } = output
          let Address { payment_credential: out_payment_credential, .. } =
            out_address
          out_payment_credential == auth_cred
        },
      )
    }
    // If the authorization method is WithdrawScript, validate the presence of a withdrawal in the transaction.
    CardanoWithdrawScriptAuth { hash, withdrawals } -> {
      let credential = Script(hash)
      pairs.has_key(withdrawals, credential)
    }
    // If the authorization method is MintScript, ensure the minted tokens meet the policy ID requirements and have a non-zero quantity.
    CardanoMintScriptAuth { hash, transaction_mint } -> {
      let fst_token_quantity =
        transaction_mint
          |> tokens(hash)
          |> to_pairs
          |> builtin.head_list
          |> builtin.snd_pair
      fst_token_quantity != 0
    }
  }
}

pub fn authorize_via_credential(
  validating_credential: Credential,
  withdrawals: Pairs<Credential, Lovelace>,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  when validating_credential is {
    VerificationKey(pubkey_hash) ->
      authorize_action(CardanoSignatureAuth(pubkey_hash, extra_signatories))
    Script(script_hash) ->
      authorize_action(CardanoWithdrawScriptAuth(script_hash, withdrawals))
  }
}

pub fn authorize_via_credential_script(
  validating_credential: Credential,
  withdrawals: Pairs<Credential, Lovelace>,
  transaction_inputs: List<Input>,
) -> Bool {
  expect Script(script_hash) = validating_credential

  or {
    authorize_action(CardanoWithdrawScriptAuth(script_hash, withdrawals)),
    authorize_action(CardanoSpendScriptAuth(script_hash, transaction_inputs)),
  }
}

//True if the tx has a ref_input with the NFT inside and the owner:
//- signed the tx if it's a wallet
//- is a withdraw script in the withdrawals if it's a script
pub fn authorize_via_nft_ownership(
  nft_policy_id: ByteArray,
  nft_asset_name: ByteArray,
  reference_inputs: List<Input>,
  transaction_inputs: List<Input>,
  withdrawals: Pairs<Credential, Lovelace>,
) -> Bool {
  when
    reference_inputs
      |> list.find(
          fn(inp) {
            quantity_of(inp.output.value, nft_policy_id, nft_asset_name) >= 1
          },
        )
  is {
    Some(Input {
      output: Output { address: Address { payment_credential, .. }, .. },
      ..
    }) ->
      payment_credential
        |> authorize_via_credential_script(withdrawals, transaction_inputs)
    _ -> False
  }
}
