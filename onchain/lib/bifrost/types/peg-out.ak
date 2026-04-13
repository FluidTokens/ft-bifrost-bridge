use aiken/merkle_patricia_forestry as mpf
use bifrost/types/general.{AuthorizationMethod}

pub type PegOutDatum {
  //Auth that can then spend this utxo
  owner_auth: AuthorizationMethod,
  //The address that will receive the pegged-out tokens on the source chain
  source_chain_destination_address: ByteArray,
  //The utxo id of the Treasury on the source chain
  source_chain_treasury_utxo_id: ByteArray,
}

pub type InputCancel {
  //The actual block header containing the Treasury Movement tx TODO Correct type
  block_header: ByteArray,
  //Proof that the passed block header belongs to the source chain
  block_header_in_source_chain_inclusion_proof: mpf.Proof,
  //Treasury Movement tx to be parsed
  treasury_movement_raw_tx: ByteArray,
  //Treasury Movement tx index in the block
  treasury_movement_tx_index: Int,
  //Proof that the Treasury Movement tx is included in the block header
  treasury_movement_tx_inclusion_proof: List<ByteArray>,
}

pub type InputCompletePegOut {
  //The actual block header containing the Treasury Movement tx TODO Correct type
  block_header: ByteArray,
  //Proof that the passed block header belongs to the source chain
  block_header_in_source_chain_inclusion_proof: mpf.Proof,
  //Treasury Movement tx to be parsed
  treasury_movement_raw_tx: ByteArray,
  //Treasury Movement tx index in the block
  treasury_movement_tx_index: Int,
  //Proof that the Treasury Movement tx is included in the block header
  treasury_movement_tx_inclusion_proof: List<ByteArray>,
  //Treasury Movement PegOut utxo id on the source chain
  peg_out_utxo_id: ByteArray,
  //Proof that the PegOut tx is not yet included in the merkle tree of completed PegOuts
  peg_out_in_completed_peg_outs_exclusion_proof: mpf.Proof,
}

pub type ActionType {
  Cancel {
    //Multiple PegOuts can be cancelled in one tx
    per_input_cancel_info: List<InputCancel>,
    //Redeemer index of the withdraw script that checks for treasury movement and PegOut NOT produced
    tmtilasponpvsh_withdraw_redeemer_index: Int,
  }
  CompletePegOut {
    //Multiple PegOuts can be completed in one tx
    per_input_complete_peg_out_info: List<InputCompletePegOut>,
    //Index of the input containing the completed_peg_outs merkle tree
    completed_peg_outs_input_index: Int,
    //Index of the output containing the completed_peg_outs merkle tree
    completed_peg_outs_output_index: Int,
    //List of inclusion proofs to insert all the newly completed PegOuts
    added_peg_out_to_completed_peg_outs_inclusion_proofs: List<mpf.Proof>,
    //Redeemer index of the withdraw script that checks for treasury movement and PegOut produced
    tmtilaspopvsh_withdraw_redeemer_index: Int,
  }
}

pub type PegOutWithdrawRedeemer {
  config_ref_input_index: Int,
  //Type of action with the relative additional data
  action_type: ActionType,
}
