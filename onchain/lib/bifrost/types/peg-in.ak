use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use aiken/primitive/bytearray
use aiken_design_patterns/stake_validator
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/types/general.{AuthorizationMethod}
use bifrost/utils
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/assets.{AssetName, PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Output, OutputReference, Transaction, find_input,
}

pub type PegInDatum {
  //Auth that can then spend this utxo
  owner_auth: AuthorizationMethod,
  //PegInRequest tx to be parsed
  source_chain_peg_in_raw_tx: ByteArray,
  //PegInRequest tx index in the block
  source_chain_peg_in_raw_tx_index: Int,
  //Utxo ID of the PegIn in the Taproot address
  peg_in_utxo_id: ByteArray,
  //The utxo id of the Treasury on the source chain
  source_chain_treasury_utxo_id: ByteArray,
  //Amount of tokens to PegIn
  peg_in_amount: Int,
  //Pubkey used by the user to start the PegIn on the source chain
  user_source_chain_pub_key: ByteArray,
}

pub type PegInRequest {
  expected_datum: PegInDatum,
  //The block header containing the PegInRequests tx
  block_header: ByteArray,
  //Proof that the passed block header belongs to the source chain
  block_header_in_source_chain_inclusion_proof: mpf.Proof,
  //Proof that the PegInRequest belongs to the block header
  tx_in_block_header_inclusion_proof: List<ByteArray>,
}

pub type PegInMintRedeemer {
  //Input spent during the minting (= creation of the PegInRequests)
  input_ref: OutputReference,
  //One or more PegInRequests that must be created on Cardano
  new_peg_in_requests: List<PegInRequest>,
}

pub type InputCompletePegIn {
  //The actual block header containing the Treasury Movement tx
  block_header: ByteArray,
  //Proof that the passed block header belongs to the source chain
  block_header_in_source_chain_inclusion_proof: mpf.Proof,
  //Treasury Movement tx to be parsed
  treasury_movement_raw_tx: ByteArray,
  //Treasury Movement tx index in the block
  treasury_movement_tx_index: Int,
  //Proof that the Treasury Movement tx is included in the block header
  treasury_movement_tx_inclusion_proof: List<ByteArray>,
  //Proof that the PegIn tx is not yet included in the merkle tree of completed PegIns
  peg_in_in_completed_peg_ins_exclusion_proof: mpf.Proof,
}

pub type ActionType {
  Cancel { burnt_peg_in_nft_asset_names: List<AssetName> }
  CompletePegIn {
    //Multiple PegIns can be completed in one tx
    per_input_complete_peg_in_info: List<InputCompletePegIn>,
    //Index of the input containing the completed_peg_ins merkle tree
    completed_peg_in_utxos_input_index: Int,
    //Index of the output containing the completed_peg_ins merkle tree
    completed_peg_in_utxos_output_index: Int,
    //List of inclusion proofs to insert all the newly completed PegIns
    added_peg_ins_to_completed_peg_ins_inclusion_proofs: List<mpf.Proof>,
    //Redeemer index of the withdraw script that checks for treasury movement and PegIn spent
    tmtilaspisvsh_withdraw_redeemer_index: Int,
  }
}

pub type PegInWithdrawRedeemer {
  config_ref_input_index: Int,
  //Type of action with the relative additional data
  action_type: ActionType,
}
