use aiken/merkle_patricia_forestry.{Proof}
use cardano/address.{Address}
use cardano/assets.{AssetName, PolicyId}

pub type BlockInfo {
  /// The current block height. Note that counting starts at 0.
  block_height: Int,
  /// The current block hash.
  block_hash: Int,
  /// The current block target. Logic around how we handle target is similar to https://learnmeabitcoin.com/technical/mining/target/#code.
  block_target: Int,
  /// The current block time.
  block_time: Int,
  /// The time of the block when last target adjustment occurred.
  block_time_of_last_target_adjustment: Int,
}

pub type OracleState {
  block_info: BlockInfo,
  /// The NFT that is used to track the oracle. We don't parameterize contract with this rather have it in datum and don't allow it to be changed against updates.
  nft_cs: PolicyId,
  nft_tn: AssetName,
  /// When updating the oracle state, we require for at least this many headers to give confidence that this block cannot be reverted.
  next_header_required: Int,
  /// We store the address of this UTxO in datum to save some costs.
  address: Address,
  // TODO: Insert header as value instead of empty bytearray if it doesn't account to increased cost.
  /// `MerklePatriciaForestry` representing the block headers, keys are block hashes corresponding to these block headers and values are empty bytearrays.
  merkle_patricia_forestry: ByteArray,
}

pub type UpdateOracleState {
  /// The block header to update the oracle state with.
  block_header: ByteArray,
  /// The subsequent headers for satisfying the `next_header_required` requirement count.
  subsequent_headers: List<ByteArray>,
  /// Proof of insertion for `block_header` to update the `merkle_patricia_forestry`.
  proof: Proof,
}
