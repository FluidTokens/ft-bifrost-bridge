# Bifrost documentation

## Architecture overview

Bifrost is an optimistic bridge that leverages Cardano Stake Pools high decentralization level to secure the peg-ins and peg-outs from and to other UTxO blockchains like Bitcoin, Dogecoin and Litecoin.
Because of the limited scripting capabilities of these blockchains, in recent years different bridging alternatives have been proposed. The current most known alternatives are FROST signatures of a small set of external nodes (Stacks), BitVM optimistic behaviour with 1-of-n honesty assumption with limited availability (Cardinal, Citrea) and Watchtower multisignature behaviour (Rosen Bridge).

Bifrost takes inspiration from all these solutions, but this time Cardano is used as a core component to guarantee the security and uncensorability of the user’s actions.

It then becomes easier to connect Cardano, a UTXO blockchain with smart contracts, to other smart contract blockchains and Layer 2s, making Cardano the central component of a safe bridging process.

![General bridge design](./images/Bridging_Design.png)

The Cardano SPOs collectively become the responsible custodians of bridged assets on the original blockchain. For example, SPOs keep and manage the locked BTC on the Bitcoin side, while its bridged version fBTC circulates freely on Cardano.

| Bridge                        | Stacks Frost bridge            | BitVM2                                                  | Rosen Bridge                                            | Bifrost                                                 |
| ----------------------------- | ------------------------------ | ------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------- |
| Security assumption           | Trust in small set of L2 nodes | At least 1 actor must honestly forget his private key   | Trust in a set of nodes from a low marketcap blockchain | Weighted-majority of Cardano SPOs must behave honestly  |
| Peg-in & Peg-out Availability | L2 nodes must be collaborative | Pre-chosen fixed set of operators must be collaborative | Majority of guards must be collaborative                | Weighted-majority of Cardano SPOs must be collaborative |
| Peg-in & Peg-out Granularity  | Any amount                     | Fixed static amounts                                    | Any amount                                              | Any amount                                              |
| Speed in good case            | Minutes                        | Minutes                                                 | Minutes                                                 | 1 Week                                                  |
| Speed in pessimistic case     | Minutes                        | Weeks                                                   | Minutes                                                 | Weeks                                                   |
| Costs                         | Low                            | Medium                                                  | Low                                                     | Medium                                                  |

Bifrost has been built to ensure security and availability, not speed or low costs.
In fact, Bifrost operations may take up to 1 or more Cardano epochs (an epoch is currently equals to 5 days), as coordination and heavy operations must be executed in the correct order.
The peg-ins and peg-outs also have to compensate for the work of all actors involved in Bifrost.
Therefore Bifrost should be used to move big amounts of liquidity in and out of Cardano and not for intra-day retail/small business operations.
Once big amounts of liquidity have been bridged to Cardano, for this type of smaller and frequent peg-ins and peg-outs it is possible to safely use services like FluidToken FluidSwaps, cutting costs and execution time without sacrificing security.

The security of Bifrost is guaranteed by SPOs participation: for a strong and reliable bridge, most of the top SPOs by delegation must participate in the protocol.

## Components

![Bifrost High Level Diagram](./images/Bifrost_HLD.png)
Bifrost setup is made by the following components:

* **Cardano**: the destination blockchain where bridged assets can safely participate in DeFi activities.
* **Source blockchain**: the original blockchain that contains assets to bridge to Cardano, like Bitcoin, Dogecoin and Litecoin.
* **Depositors**: users that lock their assets on the source blockchain to mint them on Cardano.
* **Withdrawers**: users that burn their bridged assets on Cardano to unlock them on the proper source blockchain.
* **Cardano Stake Pool Operators (SPOs)**: Cardano nodes that have delegated stake by Cardano users and that participate in Cardano consensus, guaranteeing its security.
* **Multisig treasury**: a script address on the source blockchain that holds all the bridged assets and it’s protected by a multisignature that only SPOs together can use. Each SPO has a weight equal to its delegation and a specific threshold of SPOs signature must be reached to spend/move the multisig treasury.
* **Watchtowers**: an open and always dynamic set of actors who have visibility on both Cardano and the source blockchain. They compete to post the most truthful source blockchain chain of blocks to the Binocular Oracle on Cardano. They also detect peg-in transactions on the source blockchain and post them as PegInRequest UTxOs on Cardano, and they relay SPO-signed Treasury Movement transactions from Cardano to the source blockchain. Anyone can become a Watchtower at any moment.

Bifrost logic is fully encapsulated in the following solutions:

* **SPOs program**: this code must run along with the usual SPO stack. It gives SPOs the ability to coordinate to sign Bitcoin transactions and the ability to see and interact with the needed Cardano smart contracts.
* **Watchtower program**: watchtowers run this software on top of source blockchain and Cardano nodes. It posts source blockchain block headers to the Binocular Oracle, detects peg-in transactions and posts PegInRequest UTxOs on Cardano, and relays SPO-signed Treasury Movement transactions to the source blockchain.
* Cardano smart contracts:
  * **spos_registry.ak**: SPOs that participate in Bifrost need to register here for the next upcoming epoch. The registry is an on-chain linked list ordered by SPOs edcs key and each node also contains the SPO secp key that will be used to sign source blockchain transactions.
  * **Binocular**: The watchtowers (anyone) post the best chain of blocks here, other watchtowers eventually challenge it by posting a better version and the winner gets rewarded by the end of the availability window.
  * **peg_in.ak**: watchtowers (or anyone) create PegInRequest UTxOs here by minting a unique NFT and providing a Binocular inclusion proof of the source blockchain deposit transaction. The datum contains the depositor's Bitcoin pubkey hash (HASH160), source blockchain txid, output index, deposit amount, and the creator's Cardano pubkey hash. This makes peg-in deposits visible to SPOs for inclusion in the Treasury Movement transaction.
  * **peg_out.ak**: when a withdrawer wants to unlock the bridged assets on the proper source blockchain, he locks his bridged assets at this smart contract along with a freshly minted unique NFT. The datum contains the source blockchain destination address where assets should be sent. SPOs read these UTxOs to include peg-out payments in the Treasury Movement transaction.
  * **treasury.ak**: stores the current Treasury FROST group public keys $Y_{67}$ and $Y_{51}$ and a Merkle Patricia Trie of completed peg-ins as a reference UTxO. The keys correspond to two FROST groups with thresholds ensuring any signing subset controls ≥67% and ≥51% of stake respectively. After each pair of DKGs, the current roster posts the new group public keys here, authenticated by a FROST group signature from the current roster. Depositors and validators read these to derive the current Treasury address. The completed peg-ins trie is updated each time fBTC is minted, preventing double minting. For the first epoch, the initial Treasury public keys are set during protocol bootstrap.
  * **treasury_movement.ak**: SPOs post signed source blockchain Treasury Movement transactions here. The datum contains the serialized signed transaction, the epoch number, and references to the PegInRequest and PegOut UTxOs it covers. Watchtowers monitor this contract and relay the signed transactions to the source blockchain.
  * **bridged_asset.ak**: minting and burning of bridged assets (e.g. fBTC). The depositor mints fBTC by providing: a Binocular inclusion proof that the Treasury Movement transaction (which swept the corresponding peg-in) is confirmed on the source blockchain, a non-inclusion proof against the completed peg-ins Merkle Patricia Trie in `treasury.ak` (preventing double minting), a reference to the PegInRequest UTxO, their Bitcoin x-only public key, and a Schnorr signature proving ownership. The validator verifies HASH160(pubkey) matches the depositor_pubkey_hash in the PegInRequest datum, checks the signature via `verifySchnorrSecp256k1Signature`, verifies the peg-in is not already in the completed trie, and mints fBTC to whatever Cardano address the depositor specifies in the transaction outputs. The minting transaction also inserts the peg-in into the completed peg-ins trie in the Treasury UTxO. Anyone can burn fBTC for a peg-out by providing a Binocular inclusion proof of the Treasury Movement transaction that fulfilled the peg-out, along with a reference to the PegOut UTxO.

## Components relationships

![Bifrost Flow Chart](./images/Bifrost_flow_chart.png)

Watchtowers, who run the watchtower program, challenge each other to be the first to post the best source blockchain chain of valid blocks in the Binocular Oracle smart contract. The winner for each chain is rewarded with some ADA, proportionally for each valid block posted.

Depositors, who want to peg-in, send their source blockchain assets to a unique Taproot address with an OP_RETURN metadata marker identifying the transaction as a Bifrost peg-in. Watchtowers detect these transactions on the source blockchain, and once confirmed, create PegInRequest UTxOs on Cardano (peg_in.ak) by minting an NFT and providing an inclusion proof.

Withdrawers, who want to peg-out, lock their bridged assets (e.g. fBTC) along with a freshly minted NFT at peg_out.ak, specifying their source blockchain destination address in the datum.

SPOs, who register with their delegated stake to join the next epoch in spos_registry.ak, own both a unique edcs key and a secp key. The registration is accepted only if the SPO has a delegated stake bigger than a minimum threshold.

At the end of each epoch, the registered SPOs (that normally also include the old group) verify each other's delegated stake to ensure honesty and participate in a DKG ceremony to generate their new shared multisignature address.

The old SPOs group then constructs a Treasury Movement transaction on the source blockchain. The contents and signing key depend on the available quorum:

**With 67% quorum ($Y_{67}$, normal operation)** — the transaction:

* Spends the current treasury UTxO, sending remaining funds to the new SPOs Treasury address.
* Collects (spends) all confirmed peg-in UTxOs, consolidating them into the treasury (only $Y_{67}$ can sweep peg-in UTxOs — enforced by their Taproot construction).
* Sends the correct amounts from the treasury to the source blockchain addresses that have correctly requested a peg-out.

**With 51% quorum ($Y_{51}$, degraded operation)** — if SPOs cannot collect enough partial signatures for a 67% FROST threshold, they construct a peg-out-only transaction:

* Spends the current treasury UTxO, sending remaining funds to the new Treasury address.
* Sends peg-out fulfillments. Does **not** sweep any peg-in UTxOs (peg-ins roll over to the next epoch).

**With federation key ($Y_{federation}$, emergency)** — if neither 67% nor 51% quorum is reached within the timeout, the federation signs a peg-out-only transaction (same structure as the 51% case).

If the resulting transaction would be too large, SPOs may split it into multiple transactions.

The SPOs sign this transaction using FROST group signing and post the serialized signed transaction to Cardano (treasury_movement.ak). Watchtowers monitor treasury_movement.ak, pick up the signed transaction, and broadcast it to the source blockchain network.

Once the Treasury Movement transaction is confirmed on the source blockchain, the bridging operations can be completed on Cardano:

* For peg-ins: the depositor provides a Binocular inclusion proof of the Treasury Movement transaction, a non-inclusion proof against the completed peg-ins Merkle Patricia Trie in the Treasury UTxO, their Bitcoin x-only public key, and a Schnorr signature proving ownership. This mints the corresponding fBTC to a Cardano address of the depositor's choice, burns the PegInRequest NFT, and inserts the peg-in into the completed peg-ins trie to prevent double minting.
* For peg-outs: anyone can provide a Binocular inclusion proof to burn the locked fBTC and the peg-out NFT, retrieving the min_utxo ADA.

Peg-out completion is fully permissionless. Peg-in completion requires the depositor's action (Schnorr signature), which gives the depositor full control over the Cardano destination address.

### Cardano and Bitcoin transaction flow

![Bifrost UTxO Flow](./images/utxo_flow.png)

## User peg-in flow

Let's use Bitcoin as example.
A user who wants to move his BTC from Bitcoin to Cardano is called a depositor.
These are the steps to execute a correct peg-in:

* Check the status of Bifrost: if the bridge is correctly operational and we are not too near the end of the current Cardano epoch, the peg-in can be done.
* Retrieve the current Treasury key $Y_{67}$ from `treasury.ak` on Cardano (published there after each DKG).
* On Bitcoin, send the amount of BTC to peg-in to a Taproot address derived from $Y_{67}$ and the depositor's timeout refund script (see **Taproot address construction** below). The address has two spending paths: the $Y_{67}$ key path (for SPO sweep — only a 67% weighted-majority can take custody of new BTC) and a script path allowing the depositor to reclaim after ~1 month. The transaction must include an OP_RETURN output containing: `"BFR" || depositor_pubkey_hash (20 bytes)` (23 bytes total). The `depositor_pubkey_hash` is HASH160 of the depositor's Bitcoin x-only public key and is needed by SPOs to reconstruct the Taproot address and compute the tweak for key-path signing.
* Wait for watchtowers to detect the Bitcoin transaction, post the corresponding Bitcoin block to the Binocular Oracle, and create a PegInRequest UTxO on Cardano (peg_in.ak) by minting an NFT and providing a transaction inclusion proof.
* Wait for the SPOs to include this peg-in in the Treasury Movement transaction at the next epoch boundary. The SPOs sign this transaction with FROST and post it to Cardano (treasury_movement.ak). Watchtowers then relay the signed transaction to Bitcoin.
* Once the Treasury Movement transaction is confirmed on Bitcoin, the depositor completes the peg-in on Cardano by providing a Binocular inclusion proof of the Treasury Movement transaction, a non-inclusion proof against the completed peg-ins Merkle Patricia Trie in the Treasury UTxO (preventing double minting), their Bitcoin x-only public key, and a Schnorr signature proving ownership. This mints the correct amount of fBTC to whatever Cardano address the depositor chooses, burns the PegInRequest NFT, and inserts the peg-in into the completed peg-ins trie in the Treasury UTxO.
* If the peg-in was not included in the Treasury Movement transaction (e.g., it arrived too late in the epoch, or only 51%/federation quorum was available — which processes peg-outs only), it rolls over to the next epoch. If the Treasury key has rotated and the peg-in can no longer be swept, the depositor uses the 1-month timeout spending path to reclaim their BTC and can retry with the new Treasury address. Once the depositor has reclaimed on Bitcoin, the PegInRequest creator (typically the watchtower) can close the PegInRequest UTxO on Cardano by providing a Binocular proof that the peg-in UTxO was spent (timeout reclaim), burning the PegIn NFT and reclaiming their min_utxo ADA.

### Taproot address construction

The Treasury address and peg-in addresses use different Taproot trees following BIP341 [4], reflecting the protocol's **tiered security model**: taking custody of new BTC (peg-in sweep) requires a 67% weighted-majority, while returning BTC to users (peg-out fulfillment) and moving the treasury can be done with a 51% majority or federation fallback.

#### Keys

- $Y_{67}$ and $Y_{51}$ are FROST group public keys produced by **separate DKGs** with thresholds ensuring any signing subset controls ≥67% and ≥51% of delegated stake respectively. Both are stored in `treasury.ak`.
- $Y_{federation}$ is a known protocol parameter — a public key controlled by a federation of trusted entities, used only as a last-resort spending path.

#### Treasury Taproot tree

The Treasury address (holding consolidated funds) uses $Y_{67}$ as the key-path internal key, with fallbacks for degraded and emergency operation:

| Path | Key | Condition | Use case |
|------|-----|-----------|----------|
| Key path | $Y_{67}$ | Immediate | Normal operation: peg-ins + peg-outs + treasury move |
| Script leaf 1 | $Y_{51}$ | Immediate | Degraded: peg-outs + treasury move only (no peg-in sweeps) |
| Script leaf 2 | $Y_{federation}$ | After timeout | Emergency: peg-outs + treasury move only (no peg-in sweeps) |

Script leaf 1 ($Y_{51}$ fallback):
```
<Y_51> OP_CHECKSIG
```

Script leaf 2 (federation rescue):
```
<timeout_federation> OP_CHECKSEQUENCEVERIFY OP_DROP <Y_federation> OP_CHECKSIG
```

Merkle tree (2 leaves):
```
     root
    /    \
  Y_51  Y_federation
```

Treasury output key: $Q_{treasury} = Y_{67} + \text{tagged\_hash}(\text{"TapTweak"}, Y_{67} \| \text{merkle\_root}) · G$

This address changes each epoch after DKG, since $Y_{67}$ and $Y_{51}$ are regenerated.

In normal operation (67% quorum), SPOs spend the treasury via key path — a single 64-byte Schnorr signature with no script reveal. In degraded operation (51% quorum) or emergency (federation), the script path is used, revealing the script and control block.

#### Peg-in Taproot tree

The peg-in address is intentionally simpler: **only $Y_{67}$ can sweep peg-in UTxOs**. This is enforced by Bitcoin consensus — $Y_{51}$ and $Y_{federation}$ are not present in the peg-in Taproot tree and literally cannot spend these UTxOs.

| Path | Key | Condition | Use case |
|------|-----|-----------|----------|
| Key path | $Y_{67}$ | Immediate | SPO sweep (67% weighted-majority only) |
| Script leaf | Depositor | After ~30 days (4320 blocks) | Depositor self-refund |

Script leaf (depositor refund, P2PKH-style):
```
OP_DUP OP_HASH160 <depositor_pubkey_hash> OP_EQUALVERIFY OP_CHECKSIGVERIFY <4320> OP_CHECKSEQUENCEVERIFY
```

`depositor_pubkey_hash` is HASH160 of the depositor's Bitcoin x-only public key (20 bytes). 4320 blocks ≈ 30 days. At spend time, the depositor provides their full x-only pubkey in the witness; the script verifies the hash matches before checking the signature.

The peg-in output key $Q$ is:

$Q = Y_{67} + \text{tagged\_hash}(\text{"TapTweak"}, Y_{67} \| \text{leaf\_hash}) · G$

Where:

- $Y_{67}$ is the internal key (67% FROST group x-only public key, from `treasury.ak`).
- The script tree contains a single leaf (depositor refund), so merkle_root = leaf_hash.
- $\text{leaf\_hash} = \text{tagged\_hash}(\text{"TapLeaf"}, \text{0xc0} \| \text{compact\_size}(\text{script\_len}) \| \text{script})$
- $\text{tagged\_hash}(\text{tag}, \text{msg}) = \text{SHA256}(\text{SHA256}(\text{tag}) \| \text{SHA256}(\text{tag}) \| \text{msg})$
- $G$ is the secp256k1 generator point.

The resulting Bitcoin address is `bc1p<bech32m(Q)>`.

**To reconstruct $Q$**, all components are available: $Y_{67}$ from `treasury.ak` and the depositor's pubkey hash from the OP_RETURN (propagated via the PegInRequest datum). The script is fully determined by the 20-byte hash — no secret information is needed.

#### Spending paths and Treasury Movement variants

The contents of the Treasury Movement transaction depend on which signing threshold is reached:

**Key path on both Treasury and peg-in inputs (67% quorum — normal operation):**

SPOs collect all confirmed PegInRequest and PegOut UTxOs from Cardano and construct a full Treasury Movement transaction. The 67% roster controls $Y_{67}$, so SPOs spend the treasury UTxO and all peg-in UTxOs via key path — a single 64-byte FROST Schnorr signature per input, no scripts revealed on Bitcoin. To sign, SPOs compute the tweaked private key: $d = y_{67} + \text{tagged\_hash}(\text{"TapTweak"}, Y_{67} \| \text{leaf\_hash})$, where $y_{67}$ is the FROST group private key (held as shares). For peg-in inputs, computing leaf_hash requires the depositor's pubkey hash — propagated to SPOs via the PegInRequest datum.

**Script path on Treasury, no peg-in inputs (51% quorum — degraded operation):**

If SPOs cannot collect enough partial signatures for the 67% threshold, they construct a peg-out-only Treasury Movement transaction. The 51% roster spends the treasury UTxO via the $Y_{51}$ script leaf (revealing the script and control block). Peg-in UTxOs are not spent — they roll over to the next epoch. This ensures peg-out availability even when the 67% quorum is temporarily unavailable.

**Script path on Treasury, no peg-in inputs (federation — emergency):**

If neither 67% nor 51% quorum is reached within the timeout, the federation signs a peg-out-only Treasury Movement transaction using $Y_{federation}$ (script path with CSV timelock). Same structure as the 51% case.

**Script path on peg-in only (depositor refund):**

After ~30 days (4320 blocks), the depositor reveals the timeout script and control block to reclaim their BTC. This protects depositors if the bridge fails to process their peg-in (e.g., 67% quorum unavailable for multiple epochs, or Treasury key rotated before sweep).

#### Taproot address verification

Plutus V3 does not expose secp256k1 point arithmetic builtins (only `verifySchnorrSecp256k1Signature` and `verifyEcdsaSecp256k1Signature`), so `peg_in.ak` **cannot** reconstruct $Q$ from $Y_{67}$ and the depositor's script on-chain.

Instead, Taproot address correctness is verified **off-chain by SPOs**: before including a peg-in in the Treasury Movement transaction, each SPO independently reconstructs the expected peg-in Taproot address from $Y_{67}$ and the depositor's pubkey hash (read from the PegInRequest datum), and verifies it matches the Bitcoin transaction output. SPOs will not sign a Treasury Movement transaction that spends UTxOs they cannot actually spend via key path.

This design is safe because:

- **No fund risk**: if a PegInRequest references an incorrectly constructed Taproot address, SPOs simply skip it. The depositor reclaims via the timeout path.
- **No theft risk**: fBTC is only minted after the Treasury Movement transaction (which sweeps the peg-in) is confirmed on Bitcoin. A fake PegInRequest that SPOs skip will never lead to fBTC minting.
- **Griefing cost**: creating a fake PegInRequest costs the attacker the NFT minting fee and min_utxo ADA, with no benefit.

## User peg-out flow

Let's use Bitcoin as example.
A user who wants to move his BTC from Cardano to Bitcoin is called a withdrawer.
These are the steps to execute a correct peg-out:

* Check the status of Bifrost: if the bridge is correctly operational and we are not too near the end of the current Cardano epoch, the peg-out can be done.
* On Cardano, lock the correct amount of fBTC plus MIN_ADA at the peg_out.ak spend script, minting a unique NFT. The datum contains the Bitcoin destination address where BTC should be sent.
* Wait for the SPOs to include this peg-out in the Treasury Movement transaction at the next epoch boundary. The SPOs sign this transaction with FROST and post it to Cardano (treasury_movement.ak). Watchtowers then relay the signed transaction to Bitcoin. At this point, the withdrawer has received BTC at their specified Bitcoin address.
* Once the Treasury Movement transaction is confirmed on Bitcoin (at least 6 Bitcoin blocks), anyone can complete the peg-out on Cardano by providing a Binocular inclusion proof of the Treasury Movement transaction. This burns the locked fBTC and the peg-out NFT, returning the MIN_ADA to the withdrawer.
* If for unexpected reasons the Treasury Movement transaction did not include the peg-out payment, the withdrawer can use a Binocular exclusion proof to unlock their fBTC and try again in the next epoch.

## Guaranteeing censor-resistant peg-ins and peg-outs

The main axiom is: When the user uses any bridge, he is already fully trusting the source (ex. Bitcoin) and the destination (ex. Cardano). Every additional component that the bridge uses and that it can't be under direct control of the user is an additional trust assumption.

Bifrost is truly trustless only if it doesn't necessarily add new trust assumptions.
As long as the Cardano SPOs and the watchtowers are collaborative, each peg-in or peg-out is permissionless: no actor exists who can decide if the user is permitted to move his assets between the blockchains.

Therefore, the potential additional trust assumptions in Bifrost are the Cardano SPOs and the watchtowers:

* Even if the user becomes a Cardano SPO, he would be just a small part of the total weight-based set of SPOs. Luckily, the strong majority of the SPOs are always incentivized in behaving correctly and on time, like they do when they participate in block-production consensus on Cardano. In fact, the security of Bifrost directly impacts their revenue model: more assets moved with Bifrost imply more Cardano transactions and an increase of the ADA price caused by the bigger demand to execute these transactions. Cardano SPOs want the bridge to work well because their revenue stream strongly depends on it.
* Watchtowers are an "always open" set of nodes that challenge each other to post on Cardano the best chain of blocks from the source blockchains (ex. from Bitcoin), and also detect and post peg-in requests on Cardano. While the watchtowers earn rewards for doing this job, they could potentially collude and stop posting blocks or peg-in requests, halting the bridge for an unbounded timeframe. In this case the user who wants to peg-in or peg-out can spin up a watchtower himself and post the source blockchain blocks starting from the latest confirmed ones, and create their own PegInRequest UTxOs on Cardano. Because every user is able to become a watchtower at any time, there will be a safe challenge among them to post the correct chain of blocks, resuming the Bifrost operations even in case of collusion. The completion of peg-outs (burning fBTC) is fully permissionless: anyone can submit the required Binocular inclusion proofs to finalize. For peg-ins, the depositor completes the minting themselves by providing a Binocular inclusion proof and a Schnorr signature with their Bitcoin key, choosing their Cardano destination address at mint time. No third party can censor or redirect a depositor's fBTC.

## Flow of Bitcoin over epochs, ceremonies

![Epoch lifecycle Gantt diagram](images/epoch_lifecycle.png)

The diagram above shows two consecutive Cardano epochs with roster handoff from Roster A to Roster B. SPO registration and deregistration is continuous — a registry snapshot is taken at each epoch boundary along with the stake distribution from epoch N−1 (which will become N−2 when the new roster operates). Within each epoch the following phases occur:

1. **Registry Snapshot + Stake Distribution** — at the epoch boundary, the candidate set is locked and stake weights are read from the previous epoch's distribution.
2. **Peg-in / peg-out requests open** — users submit bridging requests during the first ~36 hours of the epoch.
3. **DKG** (new roster, off-chain) — the incoming roster runs distributed key generation to produce group keys $Y_{67}$ and $Y_{51}$, running concurrently with the request window.
4. **Previous-epoch peg-in completion** — peg-ins from the prior epoch's Treasury Movement complete as Bitcoin confirmations arrive (17–40 hours after epoch start).
5. **Peg deadline + Pegs Snapshot** — at the Cardano stability window (3k/f), all bridging requests are frozen for inclusion in the Treasury Movement.
6. **Update Y** — the current roster publishes the new roster's group public keys to `treasury.ak`.
7. **Build Treasury Movement Tx** — the current roster constructs the Bitcoin transaction that moves the treasury to the new Taproot address and fulfils peg-out payments.
8. **FROST signing cascade** — the current roster attempts threshold signing with overlapping quorum levels: 67% signing starts first, 51% fallback begins ~24 hours later, and the federation last-resort begins ~24 hours after that. The first to succeed wins. With 67% quorum the transaction sweeps peg-ins and fulfils peg-outs; with 51% or federation it is peg-out only.
9. **TM submission deadline** — the signed transaction must be posted to `treasury_movement.ak` before the epoch ends.
10. **New peg requests** — after the pegs snapshot, new requests accumulate for the next epoch's batch.

## Flow of SPOs on Cardano

todo

## How to join Bifrost as SPO

todo

## Why Mithril is not necessary

todo

## Why Frost

todo

## SPO Program

It's the program that Cardano SPOs must run and it allows signature aggregation. Being based on the FROST protocol requires:
1. registration of SPOs to participate in the protocol
2. formation of a roster of Cardano SPOs and distributed key generation (every epoch)
3. group signing.
We describe each in detail.

### SPO Registration

#### 1. Overview

Before participating in Bifrost, each SPO must complete a **one-time registration** that binds their Cardano pool identity to a long-term Bifrost identity key, and post a **security deposit**. This registration uses the SPO's cold key exactly once, after which all protocol operations use the Bifrost identity key. This design keeps cold keys offline except for initial registration and revocation.

#### 2. Keys

##### 2.1 SPO Identity (Cardano Layer)

- **`pool_id`**: unique stake pool identifier, derived as `pool_id = blake2b_224(cold_vkey)`.
- **`cold_vkey` / `cold_skey`**: long-term Ed25519 keypair. Used **only** for initial Bifrost registration and revocation. Must be kept on an air-gapped offline machine per Cardano security guidelines.

##### 2.2 Bifrost Identity

- **`bifrost_id_pk` / `bifrost_id_sk`**: long-term Secp256k1 identity keypair for Bifrost protocol operations.
- Self-generated by the SPO.
- Used for roster participation, DKG coordination, and encryption of DKG shares (via ECDH).

##### 2.3 Bifrost URL

- **`bifrost_url`**: endpoint URL where the SPO publishes DKG data and receives protocol messages.

#### 3. On-Chain Objects

##### 3.1 Bifrost Membership Token

- **Minting Policy**: `BifrostMembershipPolicy`
- **TokenName**: `pool_id`
- Exactly **one token per SPO** (enforced by minting policy).
- The token serves as the on-chain badge of Bifrost participation.

##### 3.2 Registry Linked-List

All registered SPOs are tracked using an **on-chain ordered linked-list**. Each node in the list represents a registered SPO and is stored as an individual UTxO at the registry script address. The list is ordered by SPO key, ensuring uniqueness and enabling efficient insertion and removal.

- **Node Value**: Bifrost Membership Token + minimum deposit amount in ADA.
- **Node Datum**:
```json
{ key              :: ByteArray       -- SPO key (ordering key)
, next             :: ByteArray | Null -- key of the next node, or null for the tail
, data             ::
    { bifrost_id_pk :: ByteArray
    , bifrost_url   :: ByteArray
    }
}
```

**Operations:**
- **Prepend/Insert**: A new node is inserted in sorted order by verifying it is correctly positioned between its neighbors. Corresponds to `ordered.prepend` in the on-chain code.
- **Remove**: A node is removed by relinking its neighbors. Corresponds to `ordered.remove` in the on-chain code.

**Spending Conditions**: Each node UTxO can be spent by either:
1. **SPO withdrawal**: via `bifrost_id_sk` Secp256k1 signature, valid only at epoch boundary (enforced via Cardano validity intervals).
2. **Roster banning**: via FROST group signature from the current roster, for banning misbehaving participants.

The membership script uses `verifySchnorrSecp256k1Signature` for both conditions.

The on-chain linked-list implementation uses the `aiken_design_patterns/linked_list/ordered` module [8].

#### 4. Registration Message and Signature

The SPO's cold key signs a message binding their Bifrost identity:

```
"bifrost-spo" || bifrost_id_pk || bifrost_url
```

Where:
- `"bifrost-spo"` is a 10-byte ASCII domain separator.
- `bifrost_id_pk` is the 33-byte compressed Secp256k1 public key.
- `bifrost_url` is the variable-length URL encoded as UTF-8 bytes.

#### 5. Registration Transaction

A **registration tx** performs the following:

1. **Redeemer**: contains `cold_vkey`, `cold_sig`, `prepended_node_output_index`, and `anchor_node_output_index`.
2. **Input**: Anchor node UTxO from the linked-list (the node after which the new node will be inserted).
3. **Mint**: exactly one Bifrost Membership Token with `TokenName = pool_id`.
4. **Outputs**:
   - New linked-list node UTxO at registry script address with:
     - Bifrost Membership Token + minimum deposit in ADA
     - Datum containing `bifrost_id_pk`, `bifrost_url`, and linked-list pointers (correctly ordered between neighbors)
   - Updated anchor node UTxO with its `next` pointer updated to reference the new node

#### 6. On-Chain Verification

The minting policy verifies:

1. `pool_id == blake2b_224(cold_vkey)` — proves the cold key owns this pool.
2. `verifyEd25519Signature(cold_vkey, "bifrost-spo" || bifrost_id_pk || bifrost_url, cold_sig)` — proves cold key authorized this Bifrost identity binding.
3. Exactly one token minted with `TokenName = pool_id`.
4. Output datum matches the signed message content.
5. **Linked-list ordering**: verifies the new node is correctly positioned between its neighbors (the new key is greater than the anchor's key and less than the anchor's previous `next` key), preventing duplicate registration.
6. **Linked-list state transition**: verifies the anchor node's `next` pointer is correctly updated to reference the new node.
7. **Security deposit**: verifies the Membership UTxO contains sufficient ADA.

#### 7. Revocation

An SPO's membership can end through voluntary revocation or roster-initiated banning.

##### 7.1 Voluntary Revocation

The SPO's cold key signs an explicit revocation message:

```
"bifrost-revoke" || pool_id
```

Where:
- `"bifrost-revoke"` is a 14-byte ASCII domain separator.
- `pool_id` is the 28-byte pool identifier.

**Transaction**:
1. **Redeemer**: contains `cold_vkey`, `cold_sig`, `removed_node_input_index`, and `anchor_node_input_index`.
2. **Validity interval**: must fall within the epoch boundary window.
3. Spends the Membership UTxO (returning the security deposit to the SPO).
4. Burns the Bifrost Membership Token.
5. Removes the node from the linked-list by updating the anchor node's `next` pointer to skip the removed node.

**On-chain verification**:
1. `pool_id == blake2b_224(cold_vkey)` — proves the cold key owns this pool.
2. `verifyEd25519Signature(cold_vkey, "bifrost-revoke" || pool_id, cold_sig)` — proves cold key authorized revocation.
3. **Validity interval**: transaction validity falls within the epoch boundary window.
4. Exactly one token burned with `TokenName = pool_id`.
5. **Linked-list removal**: verifies the anchor node's `next` pointer is correctly updated to skip the removed node, maintaining list ordering.
6. Security deposit returned to SPO.

After exit, the SPO may re-register with a new Bifrost identity.

##### 7.2 Banning (Exponential Timeout)

The protocol supports **temporary banning** of SPOs who misbehave during DKG or signing rounds. A banned SPO retains their Membership Token and deposit but is excluded from participating in roster formation for a time-limited period.

**Exponential timeout**: Each successive ban doubles the exclusion duration. For example, a first ban may last 1 epoch, a second ban 2 epochs, a fourth 4 epochs, and so on. This escalating penalty discourages repeated misbehavior while allowing recovery from occasional failures.

**Ban initiation**: The current roster initiates a ban via FROST group signature.

**Ban expiry**: Once the ban period elapses, the SPO automatically becomes eligible for roster participation again without needing to re-register.

> **Note**: The exact behavior of the ban list is still under discussion and may be refined in future iterations.

#### 8. Security Properties

- **Cold key minimization**: The cold key is used only twice—once for registration, once for revocation (if needed). All other protocol operations use `bifrost_id_sk`.
- **Air-gapped signing**: Both registration and revocation messages can be constructed offline and signed on an air-gapped machine.
- **Sybil resistance**: One membership token per `pool_id` enforced by minting policy.
- **Economic security**: Security deposits create financial accountability for misbehavior.
- **No expiration**: Membership tokens remain valid indefinitely until explicitly revoked.



### Distributed Key Generation (DKG)

#### 1. Overview

The FROST Distributed Key Generation (DKG) process runs **entirely off-chain** using SPOs' `bifrost_url` endpoints. Two separate DKGs are run each epoch, producing group public keys $Y_{67}$ and $Y_{51}$ with thresholds ensuring any signing subset controls ≥67% and ≥51% of delegated stake respectively. Each DKG also produces individual signing shares $s_i$ for each participant. Upon successful completion, the **current roster** constructs and signs a Treasury Movement transaction that moves the treasury to the new Taproot address derived from both group keys (see **Taproot address construction**), and posts the signed transaction to Cardano at `treasury_movement.ak` for watchtowers to relay to the source blockchain. No DKG result is posted on Cardano.

**Prerequisite**: SPOs must complete SPO Registration (see previous section) before participating in DKG.

#### 2. Epoch Binding

Each DKG instance is bound to a Cardano epoch. The candidate set is determined by the on-chain registry linked-list state at the end of the previous epoch, ensuring all SPOs have the same view of registered participants.

#### 3. Threshold Calculation

The threshold `t` is computed to guarantee that **any** subset of `t` signers controls stake above the security threshold. Since the worst case is the `t` SPOs with the smallest stakes, we define:

```
t = min { k : combined_stake(bottom k SPOs by stake) > security_threshold }
```

Where:
- `security_threshold` is a protocol parameter (e.g., 51% of total delegated stake among Bifrost SPOs).
- SPOs are ranked by their delegated stake at the epoch boundary.
- `t` is the minimum number of SPOs such that even the weakest `t` SPOs exceed the threshold.

This ensures that **any** subset of `t` signers collectively controls sufficient stake to authorize bridge operations, regardless of which specific SPOs participate in a signing session.

#### 4. Candidate Set and Ordering

##### 4.1 Candidate Enumeration

All SPOs with valid Bifrost Membership Tokens (present in the registry linked-list) are candidates for the DKG.

##### 4.2 Canonical Ordering

Candidates are ordered **lexicographically by `bifrost_id_pk`** (32-byte comparison). Each participant is assigned an index $i = 1..n$ based on their position in this ordering.

##### 4.3 Candidate Information

For each candidate $P_i$, the following information is retrieved:
- `pool_id` — from Membership UTxO.
- `bifrost_id_pk` — from Membership UTxO datum.
- `bifrost_url` — from Membership UTxO datum.
- `delegated_stake` — queried from Cardano ledger state.

#### 5. Round 0: Initialization

Each SPO $P_i$ performs the following initialization steps:

1. Determine the current epoch.
2. Retrieve the registry linked-list state from the end of the previous epoch.
3. Enumerate all candidates from the linked-list.
4. Query delegated stake for each candidate.
5. Compute threshold $t$ as described in Section 3.
6. Order candidates lexicographically by `bifrost_id_pk` and assign indices.
7. Verify own participation (own `pool_id` is in the candidate set).

#### 6. Round 1: Commitments and Proofs of Knowledge

Each SPO $P_i$ performs the following steps per FROST specification [2]:

1. Construct a random polynomial $f_i(x)$ of degree $t-1$ over the Secp256k1 scalar field.
2. Compute proof of knowledge $σ_i$ of the degree-zero coefficient $a_{i0}$.
3. Compute public commitment $C_i = [φ_{i0}, ..., φ_{i(t-1)}]$ where $φ_{ij} = a_{ij} · G$.

##### 6.1 Round 1 Payload

Each $P_i$ publishes their Round 1 data at:

```
<bifrost_url>/dkg/<epoch>/round1/<pool_id>.json
```

**Payload structure**:

```json
{
  "commitment": ["<hex, 33 bytes>", ...],
  "sigma_i": "<hex, 64 bytes>"
}
```

Where:
- `commitment` is an array of $t$ compressed Secp256k1 points (33 bytes each).
- `sigma_i` is the Schnorr proof of knowledge (challenge || response, 64 bytes).

##### 6.2 Round 1 Verification

Each $P_i$ fetches Round 1 payloads from all other participants and verifies that $σ_i$ is a valid proof of knowledge for $φ_{l0}$.

If verification fails for any participant $P_l$, the process proceeds to **Misbehavior Handling** (Section 9).

#### 7. Round 2: Secret Share Distribution

Each SPO $P_i$ computes and distributes secret shares to all other participants.

##### 7.1 Share Computation

For each participant $P_l$ (where $l ≠ i$), compute the secret share $(l, f_i(l))$.

##### 7.2 Share Encryption

For each recipient $P_l$:

1. Generate ephemeral Secp256k1 keypair $(e_i, E_i)$.
2. Compute shared secret: `ss = ECDH(e_i, bifrost_id_pk_l)`.
3. Derive symmetric key: `k = HKDF(ss, info = "bifrost-dkg-share")`.
4. Encrypt share: `ciphertext = f_i(l) XOR k` (32 bytes).

The share is a 32-byte Secp256k1 scalar, encrypted with the derived key.

##### 7.3 Round 2 Payload

Each $P_i$ publishes their Round 2 data at:

```
<bifrost_url>/dkg/<epoch>/round2/<pool_id>.json
```

**Payload structure**:

```json
{
  "shares": [
    {
      "recipient_pool_id": "<hex, 28 bytes>",
      "ephemeral_pk": "<hex, 33 bytes>",
      "ciphertext": "<hex, 32 bytes>"
    }
  ]
}
```

Where:
- `recipient_pool_id` identifies the intended recipient.
- `ephemeral_pk` is the compressed Secp256k1 ephemeral public key $E_i$.
- `ciphertext` is the XOR-encrypted share.
- The `shares` array contains $n-1$ entries (one per other participant).

##### 7.4 Round 2 Decryption and Verification

Each recipient $P_l$:

1. Fetch Round 2 payload from each sender $P_i$.
2. Find the entry where `recipient_pool_id == pool_id_l`.
3. Compute shared secret: `ss = ECDH(bifrost_id_sk_l, ephemeral_pk)`.
4. Derive key `k = HKDF(ss, info = "bifrost-dkg-share")` and decrypt: `f_i(l) = ciphertext XOR k`.
5. Verify the share against sender's Round 1 commitment:

   $f_i(l) · G = \sum_{j=0}^{t-1} (l^j · φ_{ij})$

If verification fails for any share from $P_i$, the process proceeds to **Misbehavior Handling** (Section 9).

#### 8. Finalization

Upon successful verification of all shares, each $P_i$:

1. Computes their long-lived private signing share: $s_i = \sum_{l=1}^{n} f_l(i)$

2. Computes their public verification share: $Y_i = s_i · G$

3. Computes the group public key: $Y = \sum_{l=1}^{n} φ_{l0}$

All participants arrive at the same group public key $Y$.

The above steps are run **twice** — once with a threshold $t_{67}$ (producing $Y_{67}$) and once with $t_{51}$ (producing $Y_{51}$). The two DKGs can run concurrently with the same candidate set.

4. Derives the Bitcoin Treasury Taproot address from $Y_{67}$, $Y_{51}$, and $Y_{federation}$ (see **Taproot address construction**).

5. The **current roster** publishes the new group public keys $Y_{67}$ and $Y_{51}$ on Cardano at `treasury.ak`, authenticated by a FROST group signature from the current roster. This makes the new Treasury address publicly verifiable on-chain, allowing depositors to look up the correct Treasury keys and derive the Treasury and peg-in Taproot addresses.

#### 9. Misbehavior Handling

If any participant $P_m$ misbehaves (invalid proof of knowledge in Round 1, or invalid share in Round 2), the current roster **bans** them (Section 7.2) with an exponential timeout and restarts DKG.

##### 9.1 DKG Restart

After the ban transaction is confirmed on Cardano:

1. Banned SPOs are excluded from the candidate set for this epoch's DKG.
2. Threshold $t$ is recomputed with the reduced candidate set.
3. DKG restarts from Round 0.

**Note**: Banning temporarily excludes the SPO with an exponentially increasing timeout, allowing them to rejoin after the ban expires.

#### 10. Treasury Handoff

Upon successful DKG completion and publication of the new Treasury public keys $Y_{67}$ and $Y_{51}$ to `treasury.ak`:

1. The **new roster** derives the Bitcoin Treasury Taproot address from $Y_{67}$, $Y_{51}$, and $Y_{federation}$ (see **Taproot address construction**).
2. The **current roster** reads all confirmed PegInRequest UTxOs and pending PegOut UTxOs from Cardano.
3. The **current roster** attempts to construct and sign the Treasury Movement transaction using the tiered signing process (see **Spending paths and Treasury Movement variants**):
   - First, attempt to collect 67% partial signatures ($Y_{67}$) for a full Treasury Movement (peg-ins + peg-outs + treasury move to new address).
   - If 67% quorum is not reached, attempt to collect 51% partial signatures ($Y_{51}$) for a peg-out-only Treasury Movement (no peg-in sweeps, treasury move to new address).
   - If neither quorum is reached within the timeout, the federation signs a peg-out-only Treasury Movement using $Y_{federation}$.
   - If the resulting transaction would be too large, it is split into multiple transactions.
4. The signed transaction is posted to Cardano at `treasury_movement.ak`.
5. Watchtowers pick up the signed transaction from Cardano and broadcast it to the Bitcoin network.

Once the Treasury Movement transaction is confirmed on Bitcoin, the epoch transition is complete. The new roster now controls the treasury. Anyone can then complete pending peg-outs on Cardano using Binocular inclusion proofs. If the Treasury Movement included peg-in sweeps (67% case), pending peg-ins can also be completed. Otherwise, un-swept peg-ins roll over to the next epoch.

#### 11. Security Properties

- **Off-chain execution**: No DKG data is posted on Cardano; only the signed Treasury Movement transaction (posted to `treasury_movement.ak`) and the resulting source blockchain transaction are publicly visible.
- **Threshold security**: Any $t$ signers control stake above the security threshold.
- **Misbehavior accountability**: Fraudulent SPOs can be identified and excluded.
- **Current roster authority**: Only the current roster can authorize exclusions, preventing new roster self-dealing.
- **Replay resistance**: Each DKG is bound to a unique epoch number.
- **Single curve**: Using Secp256k1 throughout eliminates curve conversion complexity.

### Group signing

In what follows we summarize the *preprocess* and signing stages according to the FROST documentation [2], closely following their notation, and emphasizing special considerations relevant to SPO-based FROST groups.

#### Preprocess

Each SPO $P_i$ in the roster performs this stage prior to signing.
1. Samples random single-use nonces $(d_{ij}, e_{ij})$.
2. Derives commitment shares $(D_{ij}, E_{ij})$.
3. Stores $((d_{ij}, D_{ij}), (e_{ij}, E_{ij}))$ for later use in signing operations.
4. With $L_i$ the list of $(D_{ij}, E_{ij})$, publishes $(i, L_i)$ as datum attached to UTxO with participation token.

### Signing mechanism

Each SPO $P_i$ in the subset participating in signing performs these steps.
1. Receives message $m$ to be signed and queries from blockchain the list $B$ of triads $(i, D_i, E_i)$ corresponding to SPOs in the subset.
2. Each $P_i$ then computes the set of binding values, the group commitment $R$ and the challenge.
3. Each $P_i$ computes their response (signing share) $z_i$ using their long-lived secret share $s_i$.
4. Each $P_i$ verifies the validity of each response $z_i$, identifying and reporting misbehaving participants. If a misbehaving participant exists, process is aborted; otherwise continue.
5. Each $P_i$ can compute the group's response (the sum of $z_i$'s), arriving to the same signature $σ = (R, z)$, which they can publish along with message $m$.

## SPOs communication

One of the most critical parts of Bifrost is the communication among SPOs and their consensus.

For ZK proofs we will use **Plonkup**; see [5]. We have a complete implementation of Plonkup, as can be seen in repositories [6] and [7].

## Watchtowers and source blockchain (eg. Bitcoin) State Verification

### Watchtower Architecture

Watchtowers are permissionless participants who maintain Bitcoin blockchain state on Cardano. They serve as the critical link between the Bitcoin and Cardano networks, ensuring that Bifrost has accurate, up-to-date information about the Bitcoin blockchain.
Watchtowers use Binocular, a technology stack previously created and now improved on Bifrost.

**Key Design Principles:**

* **Permissionless Participation**: Anyone can become a watchtower at any time without registration, bonding, or approval. This ensures the system cannot be censored or controlled by a small group.
* **Competitive Model**: Multiple watchtowers compete to submit the most accurate chain of blocks. If one watchtower submits invalid or stale data, others can immediately challenge with the correct chain.
* **Economic Incentives**: Watchtowers are rewarded for posting valid blocks, creating a natural incentive for honest and timely participation.

### Core Watchtower Responsibilities

1. **Monitor Bitcoin Network**: Watchtowers continuously track the Bitcoin blockchain for new blocks as they are mined.

2. **Submit Block Headers**: When new Bitcoin blocks are found, watchtowers submit the 80-byte block headers to Binocular Oracle smart contract on Cardano. These headers contain all information needed to verify Bitcoin consensus rules.

3. **Compete for Accuracy**: Multiple watchtowers naturally compete to submit the most accurate chain. If a watchtower submits headers from an invalid or weaker fork, other watchtowers can challenge by submitting the correct chain with higher cumulative proof-of-work.

4. **Maintain Oracle Liveness**: Watchtowers ensure the Oracle never becomes stale by continuously updating it with the latest Bitcoin state. This is essential for timely peg-in and peg-out processing.

### Bifrost-Specific Watchtower Duties

Beyond maintaining general Bitcoin state, watchtowers perform specialized duties for the Bifrost bridge. The architecture has the following key constraints: SPO programs have access to Cardano chain state but not to Bitcoin chain state; watchtowers have access to Bitcoin chain state but not to SPO programs or SPO private keys. Cardano serves as the shared data layer between both parties.

**Peg-in Detection and Posting**

* Monitor the Bitcoin network for peg-in transactions by scanning for OP_RETURN outputs with the `"BFR"` prefix.
* Each peg-in transaction sends BTC to a unique Taproot address ($Y_{67}$ key path spend OR depositor timeout script path refund; see **Taproot address construction**) and includes an OP_RETURN output: `"BFR" || depositor_pubkey_hash (20 bytes)` (23 bytes total). The depositor_pubkey_hash is HASH160 of the depositor's Bitcoin x-only public key and is needed by SPOs to reconstruct the Taproot tweak for key-path signing. Only $Y_{67}$ (67% weighted-majority) can sweep peg-in UTxOs — $Y_{51}$ and $Y_{federation}$ are not in the peg-in Taproot tree. Because each peg-in goes to a unique Taproot address (derived from the depositor's pubkey hash), watchtowers cannot track peg-ins by address alone — the OP_RETURN metadata is what makes them identifiable.
* Once a peg-in transaction reaches the required confirmation threshold (100 Bitcoin blocks plus 200 minutes of Binocular challenge period), watchtowers create a PegInRequest UTxO on Cardano (peg_in.ak) by:
  * Minting a unique PegIn NFT.
  * Providing a transaction inclusion proof consisting of: the raw Bitcoin transaction data, a Merkle proof linking the transaction to the block's Merkle root, and a reference to the confirmed block in the Binocular Oracle.
  * Setting the datum with: depositor's Bitcoin pubkey hash (HASH160, extracted from the OP_RETURN), Bitcoin txid, output index, BTC amount, the Taproot output key $Q$ the peg-in was sent to, and the creator's Cardano pubkey hash (for PegInRequest closure authorization).
* The on-chain `peg_in.ak` validator verifies: (1) the Merkle proof is valid against the referenced block in Binocular, (2) the block has sufficient confirmations, (3) the OP_RETURN metadata matches the datum. Taproot address correctness is **not** verified on-chain (Plutus V3 lacks secp256k1 point arithmetic builtins); instead, SPOs verify off-chain before including the peg-in in the Treasury Movement transaction (see **Taproot address verification**).

**Treasury Movement Relay**

* Monitor Cardano's treasury_movement.ak for new signed Bitcoin transactions posted by SPOs.
* Pick up the serialized signed Bitcoin transaction from the UTxO datum.
* Broadcast the transaction to the Bitcoin network.
* This is a permissionless action: any watchtower (or any user) can relay the transaction.

**Peg-out Completion (Optional)**

* Once the Treasury Movement transaction is confirmed on Bitcoin, watchtowers can complete peg-outs on Cardano by providing Binocular inclusion proofs. However, this is not exclusive to watchtowers — anyone can perform peg-out completion with the right proofs, ensuring censorship resistance.
* For peg-out completion: provide a Binocular inclusion proof showing the Treasury Movement transaction paid the correct amount to the correct Bitcoin address, burn the locked fBTC and the peg-out NFT, and return the MIN_ADA to the withdrawer.
* Peg-in completion (minting fBTC) is performed by the depositor directly, not by watchtowers — the depositor must provide their Bitcoin x-only public key and a Schnorr signature to authorize minting to their chosen Cardano address (see **bridged_asset.ak**).

**Anomaly Detection**

* Continuously verify that Treasury BTC balance matches or exceeds circulating fBTC supply.
* Alert the system if invariants are violated.
* Trigger failover mechanisms if SPO signing stalls or quorum is lost.

### Binocular Oracle

The Binocular Oracle is the on-chain component that stores and validates Bitcoin blockchain state on Cardano. It provides trustless verification without requiring trust in any external party. For complete technical details, see the [Binocular Whitepaper](https://github.com/lantr-io/binocular/blob/main/pdfs/Whitepaper.pdf) [1].

**Bitcoin Consensus Validation**
The Oracle validates all Bitcoin consensus rules directly on-chain:

* Proof-of-Work verification (block hash meets difficulty target)
* Difficulty adjustment validation (every 2016 blocks)
* Timestamp constraints (greater than median-time-past, less than 2 hours in future)
* Chain continuity (each block references valid parent)

**Fork Management**
The Oracle maintains a tree of competing Bitcoin forks and automatically selects the canonical chain based on cumulative chainwork (total proof-of-work). This mirrors exactly how Bitcoin Core selects the best chain, ensuring the Oracle always reflects Bitcoin's true state.

**Confirmation Tracking**
Blocks progress through multiple stages:

* Initially added to the forks tree when submitted
* Tracked for confirmation depth (distance from chain tip)
* Only blocks with 100+ confirmations are considered for finality

**Transaction Inclusion Proofs**
For Bifrost operations, the Oracle provides data for Watchtowers to construct proofs that:

* Prove a specific transaction exists within a confirmed block
* Prove the block is part of the confirmed chain
* Enable trustless verification of peg-in deposits and peg-out completions

### Challenge Period Mechanism

To prevent pre-computed attacks and ensure security, blocks are not immediately finalized when submitted:

1. **Submission**: A watchtower submits new Bitcoin block headers to the Oracle
2. **Challenge Window**: A 200-minute window opens during which any other watchtower can submit a competing fork with higher chainwork
3. **Resolution**: The Oracle automatically selects the chain with the highest cumulative proof-of-work
4. **Finalization**: After the challenge period expires and the block has 100+ confirmations, it becomes "confirmed" and can be used for peg-in proofs

This mechanism ensures that even if a malicious watchtower pre-computes a short fork, honest watchtowers have ample time to submit the correct chain.

### Security: 1-Honest-Watchtower Assumption

Bifrost's watchtower design relies on a minimal trust assumption: only one honest watchtower needs to exist for the system to function correctly.

**Why This Works:**

* If all active watchtowers collude to censor or submit invalid data, any user can spin up their own watchtower
* The permissionless design means no one can prevent new watchtowers from joining
* Honest watchtowers are economically incentivized to challenge invalid submissions

**Censorship Resistance:**

* A user wanting to peg-in or peg-out can always become a watchtower themselves
* They can then submit the necessary Bitcoin blocks and proofs for their own transactions
* This ensures Bifrost remains operational even in adversarial conditions

This 1-of-n honesty assumption is significantly stronger than typical bridge trust models that require trusting a majority or specific set of operators.

## References

[1] Nemish, Alexander. "Binocular: A Trustless Bitcoin Oracle for Cardano." 2025. <https://github.com/lantr-io/binocular/blob/main/pdfs/Whitepaper.pdf>

[2] Komlo, C. and Goldberg, I. "FROST: Flexible Round-Optimized Schnorr Threshold Signatures." RFC 9591, IETF, 2024. <https://datatracker.ietf.org/doc/rfc9591/>

[3] Wuille, P. et al. "BIP340: Schnorr Signatures for secp256k1." Bitcoin Improvement Proposal, 2020. <https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki>

[4] Wuille, P. et al. "BIP341: Taproot: SegWit version 1 spending rules." Bitcoin Improvement Proposal, 2020. <https://github.com/bitcoin/bips/blob/master/bip-0341.mediawiki>

[5] Pearson, Luke et. al., *Plonkup: Reconciling Plonk with plookup* (2022).

[6] *zkFold Symbolic* (github repository): https://github.com/zkFold/symbolic/tree/main/symbolic-base/src/ZkFold/Protocol/Plonkup

[7] *zkFold-Cardano* (github repository): https://github.com/zkFold/zkfold-cardano/tree/main/zkfold-cardano/src/ZkFold/Cardano

[8] *Bifrost On-Chain Validators* (Aiken): https://github.com/FluidTokens/ft-bifrost-bridge/tree/main/onchain/validators
