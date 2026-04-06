use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash, blake2b_224}
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
  source_chain_raw_peg_in_tx: Data,
  //The utxo id of the Treasury on the source chain
  source_chain_treasury_utxo_id: Data,
  //Amount of tokens to PegIn
  peg_in_amount: Data,
}

pub type PegInRequest {
  //Auth that can then spend this utxo
  owner_auth: AuthorizationMethod,
  //PegInRequest tx to be parsed
  source_chain_raw_peg_in_tx: Data,
  //The utxo id of the Treasury on the source chain
  source_chain_treasury_utxo_id: Data,
  //Amount of tokens to PegIn
  peg_in_amount: Data,
  //The block header containing the PegInRequests tx TODO Correct type
  block_header: Data,
  //Proof that the passed block header belongs to the source chain
  block_header_in_source_chain_inclusion_proof: mpf.Proof,
  //Block header mpf root is contained in the datum of this reference input
  block_header_merkle_tree_ref_input_index: Int,
  //Proof that the PegInRequest belongs to the block header
  peg_in_request_tx_in_block_header_inclusion_proof: mpf.Proof,
}

pub type PegInMintRedeemer {
  //Input spent during the minting (= creation of the PegInRequests)
  input_ref: OutputReference,
  config_ref_input_index: Int,
  //The source chain (eg. Bitcoin) blocks mpf root is contained in the datum of this reference input
  source_chain_merkle_tree_ref_input_index: Int,
  //One or more PegInRequests that must be created on Cardano
  new_peg_in_requests: List<PegInRequest>,
}

pub type InputCompletePegIn {
  //The actual block header containing the Treasury Movement tx TODO Correct type
  block_header: Data,
  //Block header mpf root is contained in the datum of this reference input
  block_header_merkle_tree_ref_input_index: Int,
  //Proof that the passed block header belongs to the source chain
  block_header_in_source_chain_inclusion_proof: mpf.Proof,
  //Treasury Movement tx to be parsed
  treasury_movement_raw_tx: Data,
  //Proof that the Treasury Movement tx is included in the block header
  treasury_movement_tx_inclusion_proof: mpf.Proof,
  //Proof that the PegIn tx is not yet included in the merkle tree of completed PegIns
  peg_in_in_completed_peg_ins_exclusion_proof: mpf.Proof,
}

pub type ActionType {
  Cancel { burnt_peg_in_nft_asset_names: List<AssetName> }
  CompletePegIn {
    //Multiple PegIns can be completed in one tx
    per_input_complete_peg_in_info: List<InputCompletePegIn>,
    //Index of the input containing the completed_peg_ins merkle tree
    completed_peg_in_txs_input_index: Int,
    //Index of the output containing the completed_peg_ins merkle tree
    completed_peg_in_txs_output_index: Int,
    //List of inclusion proofs to insert all the newly completed PegIns
    added_peg_ins_to_completed_peg_ins_inclusion_proofs: List<mpf.Proof>,
    //Redeemer index of the withdraw script that checks for treasury movement and PegIn spent
    tmtilaspisvsh_withdraw_redeemer_index: Int,
  }
}

pub type PegInWithdrawRedeemer {
  config_ref_input_index: Int,
  //The source chain (eg. Bitcoin) blocks mpf root is contained in the datum of this reference input
  source_chain_merkle_tree_ref_input_index: Int,
  //Type of action with the relative additional data
  action_type: ActionType,
}
