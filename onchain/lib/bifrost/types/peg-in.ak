use aiken/merkle_patricia_forestry as mpf
use bifrost/types/general.{AuthorizationMethod}
use cardano/address.{Address}
use cardano/assets.{AssetName}
use cardano/transaction.{OutputReference}

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
  new_peg_in_request: PegInRequest,
}

pub type ActionType {
  Cancel { burnt_peg_in_nft_asset_name: AssetName }
  // B1 (full wiring): instead of re-proving the Treasury Movement inline, completion *references*
  // the Confirmed TM UTxO (authenticated by the TM NFT) and reads `btc_txid` + `swept_peg_in_utxo_ids`
  // from its datum. Depositor authorization is embedded here (the former `owner_auth` withdraw
  // delegation to binocular's PegInDepositorAuthValidator is gone): a BIP340 Schnorr signature over
  // sha2_256("BFR-mint-v1" ‖ btc_txid ‖ peg_in_utxo_id ‖ recipient) with the datum's
  // `user_source_chain_pub_key`, plus recipient-binding of the minted fBTC.
  CompletePegIn {
    //Depositor-chosen fBTC destination; bound into both the signed message and the fBTC output
    recipient: Address,
    //Index of the output paying `peg_in_amount` fBTC to `recipient`
    fbtc_output_index: Int,
    //Depositor's BIP340 Schnorr signature authorizing this recipient + TM
    depositor_signature: ByteArray,
    //Index of the input containing the completed_peg_ins merkle tree
    completed_peg_in_utxos_input_index: Int,
    //Index of the output containing the completed_peg_ins merkle tree
    completed_peg_in_utxos_output_index: Int,
    //Inclusion proof to insert the newly completed PegIn
    added_peg_in_to_completed_peg_ins_inclusion_proof: mpf.Proof,
    //Proof that the PegIn is not yet included in the merkle tree of completed PegIns
    peg_in_in_completed_peg_ins_exclusion_proof: mpf.Proof,
  }
}

pub type PegInWithdrawRedeemer {
  config_ref_input_index: Int,
  //Type of action with the relative additional data
  action_type: ActionType,
}
