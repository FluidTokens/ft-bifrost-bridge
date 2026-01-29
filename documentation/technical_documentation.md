# Bifrost documentation

## Architecture overview

Bifrost is an optimistic bridge that leverages Cardano Stake Pools high decentralization level to secure the peg-ins and peg-outs from and to other UTxO blockchains like Bitcoin, Dogecoin and Litecoin.
Because of the limited scripting capabilities of these blockchains, in recent years different bridging alternatives have been proposed. The current most known alternatives are FROST signatures of a small set of external nodes (Stacks), BitVM optimistic behaviour with 1-of-n honesty assumption with limited availability (Cardinal, Citrea) and Watchtower multisignature behaviour (Rosen Bridge).

Bifrost takes inspiration from all these solutions, but this time Cardano is used as a core component to guarantee the security and uncensorability of the user’s actions.

It then becomes easier to connect Cardano, a UTXO blockchain with smart contracts, to other smart contract blockchains and Layer 2s, making Cardano the central component of a safe bridging process.

![General bridge design](./images/Bridging_Design.png)

The Cardano SPOs collectively become the responsible custodians of bridged assets on the original blockchain. For example, SPOs keep and manage the locked BTC on the Bitcoin side, while its bridged version bBTC circulates freely on Cardano.

Bridge | Stacks Frost bridge | BitVM2 | Rosen Bridge | Bifrost |
--- | --- | --- | --- |--- |
Security assumption | Trust in small set of L2 nodes | At least 1 actor must honestly forget his private key | Trust in a set of nodes from a low marketcap blockchain | Weighted-majority of Cardano SPOs must behave honestly |
Peg-in & Peg-out Availability | L2 nodes must be collaborative | Pre-chosen fixed set of operators must be collaborative | Majority of guards must be collaborative | Weighted-majority of Cardano SPOs must be collaborative |
Peg-in & Peg-out Granularity | Any amount | Fixed static amounts | Any amount | Any amount |
Speed in good case | Minutes | Minutes | Minutes | 1 Week |
Speed in pessimistic case | Minutes | Weeks | Minutes | Weeks |
Costs | Low | Medium | Low | Low | Medium |

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
* **Watchtowers**: an open and always dynamic set of actors who have visibility on both Cardano and the source blockchain. Their only duty is to compete to post the most truthful source blockchain chain of blocks. This allows Cardano to know what’s happening on the source blockchain. Anyone can become a Watchtower at any moment.

Bifrost logic is fully encapsulated in the following solutions:

* **SPOs program**: this code must run along with the usual SPO stack. It gives SPOs the ability to coordinate to sign Bitcoin transactions and the ability to see and interact with the needed Cardano smart contracts.
* **Watchtower program**: watchtowers run this software on top of source blockchain and Cardano nodes to be able to properly post the best chain of blocks to Cardano.
* Cardano smart contracts:
  * **spos_registry.ak**: SPOs that participate in Bifrost need to register here for the next upcoming epoch. The registry is a on-chain linked list ordered by SPOs edcs key and each node also contains the SPO secp key that will be used to sign source blockchain transactions.
  * **watchtower.ak**: The watchtowers (anyone) post the best chain of blocks here, other watchtowers eventually challenge it by posting a better version and the winner gets rewarded by the end of the availability window.
  * **peg_in.ak**: when a depositor wants to bridge his assets, he starts by minting a unique NFT and by locking it here. Burning this NFT plus the proof that the source blockchain locking transaction happened, allow the depositor to mint the bridged assets on Cardano
  * **peg_out.ak**: when a withdrawer wants to unlock the bridged assets on the proper source blockchain, he starts the peg-out process sending his bridged assets to this smart contract along with a freshly minted unique NFT in the same eUTxO. A proof that the source blockchain unlocking transaction happened, allows the withdrawer to burn this eUTxO and retrieve the min_utxo locked ADA.
  * **bridged_asset.ak**: At the end of peg-ins, it allows to mint the bridged version of the source blockchain assets; at the end of peg-outs it allows to burn these bridged assets.

## Components relationships

Watchtowers, who run the watchtower program, challenge each other to be the first to post the best source blockchain chain of valid blocks in the Watchtower smart contract. The winner for each chain is rewarded with some ADA, proportionally for each valid block posted.

Depositors, who want to peg-in, mint the proper NFT in peg_in.ak, send their source blockchain assets to the treasury address and wait for the epoch to end.

Withdrawers, who want to peg-out, mint the proper NFT, send it along their bridged assets to peg_out.ak and wait for the epoch to end.

SPOs, who register with their delegated stake to join the next epoch in spos_registry.ak, own both a unique edcs key and a secp key. The registration is accepted only if the SPO has a delegated stake bigger than a minimum threshold.

At the end of each epoch, the registered SPOs (that normally also include the old group) verify each other’s delegated stake to ensure honesty and participate in a ceremony to generate their new shared multisignature address.

The old SPOs group then transfers ownership of the source blockchain treasury to the new SPOs group executing a source blockchain transaction from the old SPOs Treasury address to the new one.

This transaction also aggregates all the peg-in transactions to always keep the treasury in one single UTxO.

This transaction also sends the correct amount of the treasury to the source blockchain addresses that have correctly requested a peg-out.

At this point the depositors can burn their peg_in.ak NFT and mint their bridged assets, while the withdrawers can burn their bridged assets locked and the NFT in the peg_out.ak to earn the min_utxo ADA attached to each eUTxO.

## User peg-in flow

Let's use Bitcoin as example.
A user who wants to move his BTC from Bitcoin to Cardano is called a depositor.
These are the steps to execute a correct peg-in:

* Check the status of Bifrost: if the bridge is correctly operational and we are not too near the end of the current Cardano epoch, the peg-in can be done.
* Retrieve the current Bitcoin Treasury Address that is controlled by the Cardano SPOs.
* On Cardano, mint a unique peg_in.ak NFT and send it to the peg_in.ak spend script, putting in the datum the current Bitcoin Treasury Address.
* On Bitcoin, send to the Bitcoin Treasury Address the amount of BTC to peg-in in a single Output adding in the transaction metadata the asset name of the peg_in.ak NFT.
* Wait for the watchtowers to post on Cardano the Bitcoin block that contains the Bitcoin transaction (at least 100 Bitcoin blocks must have passed, ~12  hours).
* Create a ZK proof of the Bitcoin transaction and use it to complete the Cardano peg-in request, minting the correct amount of fBTC and burning the peg-in NFT.

## User peg-out flow

Let's use Bitcoin as example.
A user who wants to move his BTC from Cardano to Bitcoin is called a withdrawer.
These are the steps to execute a correct peg-out:

* Check the status of Bifrost: if the bridge is correctly operational and we are not too near the end of the current Cardano epoch, the peg-in can be done.
* Retrieve the current Bitcoin Treasury Address that is controlled by the Cardano SPOs.
* On Cardano, mint a unique peg_out.ak NFT and send it, along with the correct number of fBTC, to the peg_out.ak spend script, putting in the datum the current Bitcoin Treasury Address.
* Wait for the watchtowers to post the Treasury Movement transaction of the next Epoch, that includes the refunds for the withdrawers (at least 8 Bitcoin blocks must have passed). At this point, you have received your BTC on Bitcoin from the Bitcoin Treasury with a utxo that contains your peg_out.ak NFT AssetName in the transaction metadata.
* Create a ZK proof of the refund and use it to complete the Cardano peg-out request, burning the peg_out.ak NFT and the 30 fBTC.

## Guaranteeing censor-resistant peg-ins and peg-outs

The main axiom is: When the user uses any bridge, he is already fully trusting the source (ex. Bitcoin) and the destination (ex. Cardano). Every additional component that the bridge uses and that it can't be under direct control of the user is an additional trust assumption.

Bifrost is truly trustless only if it doesn't necessarily add new trust assumptions.
As long as the Cardano SPOs and the watchtowers are collaborative, each peg-in or peg-out is permissionless: no actor exists who can decide if the user is permitted to move his assets between the blockchains.

Therefore, the potential additional trust assumptions in Bifrost are the Cardano SPOs and the watchtowers:

* Even if the user becomes a Cardano SPO, he would be just a small part of the total weight-based set of SPOs. Luckily, the strong majority of the SPOs are always incentivized in behaving correctly and on time, like they do when they participate in block-production consensus on Cardano. In fact, the security of Bifrost directly impacts their revenue model: more assets moved with Bifrost imply more Cardano transactions and an increase of the ADA price caused by the bigger demand to execute these transactions. Cardano SPOs want the bridge to work well because their revenue stream strongly depends on it.
* Watchtowers are an "always open" set of nodes that challenge each other to post on Cardano the best chain of block from the source blockchains (ex. from Bitcoin). While the watchtowers earn rewards for doing this job, they could potentially collude and stop the posting of new blocks, halting the bridge for an unbounded timeframe. In these case the user that wants to peg-in or peg-out can spin up a watchtower himself and posting the source blockchains blocks starting from the latest confirmed ones. Because every user is able to become a watchtower any time, there will be now a safe challenge among them to post the correct chain of blocks, resuming the Bifrost operations even in case of collusion.

## Flow of Bitcoin over epochs, cerimonies

todo

## Flow of SPOs on Cardano

todo

## How to join Bifrost as SPO

todo

## Why Mithril is not necessary

todo

## Why Frost

todo

## SPO Program
Signature aggregation based on the FROST protocol requires: a) registration of SPOs to participate in the protocol, b) formation of a roster of Cardano SPOs and distributed key generation (every epoch), and c) group signing.  We describe each in detail.

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

##### 3.2 Membership UTxO

Each registered SPO has a membership UTxO at the membership script address containing:
- **Value**: Bifrost Membership Token (with `TokenName = pool_id`) + minimum deposit amount in ADA (protocol parameter).
- **Datum**:
```json
{ bifrost_id_pk :: ByteArray
, bifrost_url   :: ByteArray
}
```
- **Spending Conditions**: The UTxO can be spent by either:
  1. **SPO withdrawal**: via `bifrost_id_sk` Secp256k1 signature, valid only at epoch boundary (enforced via Cardano validity intervals).
  2. **Roster slashing**: via FROST group signature from the current roster, for slashing misbehaving participants.

The membership script uses `verifySchnorrSecp256k1Signature` for both conditions.

##### 3.3 Registry State UTxO (Patricia Merkle Tree)

A single global UTxO that tracks all registered `pool_id` values using a **Patricia Merkle Tree (PMT)**. This ensures membership token uniqueness is cryptographically enforced.

- **Value**: Registry thread token (NFT) to ensure uniqueness.
- **Datum**:
```json
{ pmt_root :: ByteArray   -- 32-byte root hash of the Patricia Merkle Tree
}
```

**PMT Structure:**
- Keys: `pool_id` (28 bytes, used directly as the PMT key).
- Values: empty (presence in tree is sufficient; binding data stored in individual Membership UTxOs).
- The PMT provides $O(\log n)$ proofs of membership and non-membership.

The PMT implementation uses the Haskell Merkle Patricia Forestry library [8]. On-chain verification is implemented in Aiken [9].

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

1. **Redeemer**: contains `cold_vkey`, `cold_sig`, and `pmt_non_membership_proof`.
2. **Input**: Registry State UTxO (consumed to update PMT root).
3. **Mint**: exactly one Bifrost Membership Token with `TokenName = pool_id`.
4. **Outputs**:
   - Membership UTxO at membership script address with:
     - Bifrost Membership Token + minimum deposit in ADA
     - Datum containing `bifrost_id_pk` and `bifrost_url`
   - Updated Registry State UTxO with:
     - New `pmt_root` after inserting `pool_id`

#### 6. On-Chain Verification

The minting policy verifies:

1. `pool_id == blake2b_224(cold_vkey)` — proves the cold key owns this pool.
2. `verifyEd25519Signature(cold_vkey, "bifrost-spo" || bifrost_id_pk || bifrost_url, cold_sig)` — proves cold key authorized this Bifrost identity binding.
3. Exactly one token minted with `TokenName = pool_id`.
4. Output datum matches the signed message content.
5. **PMT non-membership proof**: verifies `pool_id` is not already in the tree (prevents duplicate registration).
6. **PMT insertion proof**: verifies new `pmt_root` is the valid result of inserting `pool_id` into the old tree.
7. **Security deposit**: verifies the Membership UTxO contains sufficient ADA.

#### 7. Revocation

An SPO's membership can end through voluntary revocation or roster-initiated slashing. Both paths consume the Membership UTxO, burn the token, and update the PMT.

##### 7.1 Voluntary Revocation

The SPO's cold key signs an explicit revocation message:

```
"bifrost-revoke" || pool_id
```

Where:
- `"bifrost-revoke"` is a 14-byte ASCII domain separator.
- `pool_id` is the 28-byte pool identifier.

**Transaction**:
1. **Redeemer**: contains `cold_vkey`, `cold_sig`, and `pmt_membership_proof`.
2. **Validity interval**: must fall within the epoch boundary window.
3. Spends the Membership UTxO (returning the security deposit to the SPO).
4. Burns the Bifrost Membership Token.
5. Consumes the Registry State UTxO and outputs it with new `pmt_root` after removing `pool_id`.

##### 7.2 Slashing

The current roster signs a slashing message:

```
"bifrost-slash" || pool_id
```

Where:
- `"bifrost-slash"` is a 13-byte ASCII domain separator.
- `pool_id` is the 28-byte pool identifier of the misbehaving SPO.

**Transaction**:
1. **Inputs**: Membership UTxO(s) of misbehaving SPO(s) + Registry State UTxO.
2. **Redeemer**: FROST group signature over the slashing message.
3. Burns the Bifrost Membership Token(s).
4. **Outputs**:
   - Slashed ADA deposits sent to the treasury.
   - Updated Registry State UTxO with new `pmt_root` after removing slashed `pool_id`(s).

##### 7.3 On-Chain Verification

The membership script verifies one of two authorization paths:

**Path A — Voluntary Revocation**:
1. `pool_id == blake2b_224(cold_vkey)` — proves the cold key owns this pool.
2. `verifyEd25519Signature(cold_vkey, "bifrost-revoke" || pool_id, cold_sig)` — proves cold key authorized revocation.
3. **Validity interval**: transaction validity falls within the epoch boundary window.
4. Security deposit returned to SPO.

**Path B — Slashing**:
1. `verifySchnorrSecp256k1Signature(current_roster_pk, "bifrost-slash" || pool_id, frost_signature)` — proves the current roster authorized slashing.
2. Security deposit sent to treasury.

**Common verification (both paths)**:
1. Exactly one token burned with `TokenName = pool_id`.
2. **PMT membership proof**: verifies `pool_id` exists in the tree.
3. **PMT deletion proof**: verifies new `pmt_root` is the valid result of removing `pool_id` from the old tree.

After exit, the SPO may re-register with a new Bifrost identity.

#### 8. Security Properties

- **Cold key minimization**: The cold key is used only twice—once for registration, once for revocation (if needed). All other protocol operations use `bifrost_id_sk`.
- **Air-gapped signing**: Both registration and revocation messages can be constructed offline and signed on an air-gapped machine.
- **Sybil resistance**: One membership token per `pool_id` enforced by minting policy.
- **Economic security**: Security deposits create financial accountability for misbehavior.
- **No expiration**: Membership tokens remain valid indefinitely until explicitly revoked.



### Distributed Key Generation (DKG)

#### 1. Overview

The FROST Distributed Key Generation (DKG) process runs **entirely off-chain** using SPOs' `bifrost_url` endpoints. The DKG produces a group public key `Y` and individual signing shares `s_i` for each participant. Upon successful completion, the **current roster** signs a Bitcoin transaction moving the treasury to the new address derived from `Y`. No DKG result is posted on Cardano.

**Prerequisite**: SPOs must complete SPO Registration (see previous section) before participating in DKG.

#### 2. Epoch Binding

Each DKG instance is bound to a Cardano epoch. The candidate set is determined by the PMT root at the end of the previous epoch, ensuring all SPOs have the same view of registered participants.

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

All SPOs with valid Bifrost Membership Tokens (present in the PMT) are candidates for the DKG.

##### 4.2 Canonical Ordering

Candidates are ordered **lexicographically by `bifrost_id_pk`** (32-byte comparison). Each participant is assigned an index `i = 1..n` based on their position in this ordering.

##### 4.3 Candidate Information

For each candidate `P_i`, the following information is retrieved:
- `pool_id` — from Membership UTxO.
- `bifrost_id_pk` — from Membership UTxO datum.
- `bifrost_url` — from Membership UTxO datum.
- `delegated_stake` — queried from Cardano ledger state.

#### 5. Round 0: Initialization

Each SPO `P_i` performs the following initialization steps:

1. Determine the current epoch.
2. Retrieve the PMT root from the end of the previous epoch.
3. Enumerate all candidates from the PMT.
4. Query delegated stake for each candidate.
5. Compute threshold `t` as described in Section 3.
6. Order candidates lexicographically by `bifrost_id_pk` and assign indices.
7. Verify own participation (own `pool_id` is in the candidate set).

#### 6. Round 1: Commitments and Proofs of Knowledge

Each SPO `P_i` performs the following steps per FROST specification [2]:

1. Construct a random polynomial `f_i(x)` of degree `t-1` over the Secp256k1 scalar field.
2. Compute proof of knowledge `sigma_i` of the degree-zero coefficient `a_{i0}`.
3. Compute public commitment `C_i = [phi_{i0}, ..., phi_{i(t-1)}]` where `phi_{ij} = a_{ij} * G`.

##### 6.1 Round 1 Payload

Each `P_i` publishes their Round 1 data at:

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
- `commitment` is an array of `t` compressed Secp256k1 points (33 bytes each).
- `sigma_i` is the Schnorr proof of knowledge (challenge || response, 64 bytes).

##### 6.2 Round 1 Verification

Each `P_i` fetches Round 1 payloads from all other participants and verifies that `sigma_i` is a valid proof of knowledge for `phi_{l0}`.

If verification fails for any participant `P_l`, the process proceeds to **Misbehavior Handling** (Section 9).

#### 7. Round 2: Secret Share Distribution

Each SPO `P_i` computes and distributes secret shares to all other participants.

##### 7.1 Share Computation

For each participant `P_l` (where `l ≠ i`), compute the secret share `(l, f_i(l))`.

##### 7.2 Share Encryption

For each recipient `P_l`:

1. Generate ephemeral Secp256k1 keypair `(e_i, E_i)`.
2. Compute shared secret: `ss = ECDH(e_i, bifrost_id_pk_l)`.
3. Derive symmetric key: `k = HKDF(ss, info = "bifrost-dkg-share")`.
4. Encrypt share: `ciphertext = f_i(l) XOR k` (32 bytes).

The share is a 32-byte Secp256k1 scalar, encrypted with the derived key.

##### 7.3 Round 2 Payload

Each `P_i` publishes their Round 2 data at:

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
- `ephemeral_pk` is the compressed Secp256k1 ephemeral public key `E_i`.
- `ciphertext` is the XOR-encrypted share.
- The `shares` array contains `n-1` entries (one per other participant).

##### 7.4 Round 2 Decryption and Verification

Each recipient `P_l`:

1. Fetch Round 2 payload from each sender `P_i`.
2. Find the entry where `recipient_pool_id == pool_id_l`.
3. Compute shared secret: `ss = ECDH(bifrost_id_sk_l, ephemeral_pk)`.
4. Derive key `k = HKDF(ss, info = "bifrost-dkg-share")` and decrypt: `f_i(l) = ciphertext XOR k`.
5. Verify the share against sender's Round 1 commitment:
   ```
   f_i(l) * G == sum_{j=0}^{t-1} (l^j * phi_{ij})
   ```

If verification fails for any share from `P_i`, the process proceeds to **Misbehavior Handling** (Section 9).

#### 8. Finalization

Upon successful verification of all shares, each `P_i`:

1. Computes their long-lived private signing share:
   ```
   s_i = sum_{l=1}^{n} f_l(i)
   ```

2. Computes their public verification share:
   ```
   Y_i = s_i * G
   ```

3. Computes the group public key:
   ```
   Y = sum_{l=1}^{n} phi_{l0}
   ```

4. Derives the Bitcoin treasury address from `Y` (Taproot address).

All participants arrive at the same group public key `Y`.

#### 9. Misbehavior Handling

If any participant `P_m` misbehaves (invalid proof of knowledge in Round 1, or invalid share in Round 2), the current roster slashes them via **Membership Exit** (Section 7.2) and restarts DKG.

##### 9.1 DKG Restart

After the slashing transaction is confirmed on Cardano:

1. Excluded SPOs are removed from the candidate set for this epoch's DKG.
2. Threshold `t` is recomputed with the reduced candidate set.
3. DKG restarts from Round 0.

**Note**: Slashing fully removes the misbehaving SPO from Bifrost (token burned, removed from PMT). They must complete a new registration to participate again.

#### 10. Treasury Handoff

Upon successful DKG completion:

1. The **new roster** derives the Bitcoin Taproot address from group public key `Y`.
2. The **current roster** constructs a Bitcoin transaction that:
   - Spends the current treasury UTxO.
   - Sends all funds to the new treasury address.
   - Includes peg-out fulfillments as additional outputs (if any pending).
3. The current roster performs FROST group signing on this transaction.
4. The signed transaction is broadcast to the Bitcoin network.

This completes the epoch transition. The new roster now controls the treasury.

#### 11. Security Properties

- **Off-chain execution**: No DKG data is posted on Cardano; only the treasury handoff (Bitcoin tx) is publicly visible.
- **Threshold security**: Any `t` signers control stake above the security threshold.
- **Misbehavior accountability**: Fraudulent SPOs can be identified and excluded.
- **Current roster authority**: Only the current roster can authorize exclusions, preventing new roster self-dealing.
- **Replay resistance**: Each DKG is bound to a unique epoch number.
- **Single curve**: Using Secp256k1 throughout eliminates curve conversion complexity.

### Group signing


In what follows we summarize the *preprocess* and signing stages according to the FROST documentation [2], closely following their notation, and emphasizing special considerations relevant to SPO-based FROST groups.

#### Preprocess

Each SPO `P_i` in the roster performs this stage prior to signing.
1. Samples random single-use nonces `(d_{ij}, e_{ij})`.
2. Derives commitment shares `(D_{ij}, E_{ij})`.
3. Stores `((d_{ij}, D_{ij})`, `(e_{ij}, E_{ij}))` for later use in signing operations.
4. With `L_i` the list of `(D_{ij}, E_{ij})`, publishes `(i, L_i)` as datum attached to UTxO with participation token.

### Signing mechanism

Each SPO `P_i` in the subset participating in `signing` performs these steps.
1. Receives message `m` to be signed and queries from blockchain the list `B` of triads `(i, D_i, E_i)` corresponding to SPO’s in the subset.
2. Each `P_i` then computes the set of binding values, the group commitment `R` and the challenge.
3. Each `P_i` computes their response (signing share) `z_i` using their long-lived secret share `s_i`.
4. Each `P_i` verifies the validity of each response `z_i`, identifying and reporting misbehaving participants.  If a misbehaving participant exists, process is aborted; otherwise continue.
5. Each `P_i` can compute the group’s response (the sum of `z_i`‘s.), arriving to the same signature `sigma = (R, z)`, which they can publish along with message `m`.

## SPOs communication

The main algorithms have been chosen: eventual ZK proof algorithms needed, consensus among SPOs and communication among SPOs.

For ZK proofs we will use **Plonkup**; see [5].  We have a complete implementation of Plonkup, as can be seen in repositories [6] and [7].

## Watchtowers and Bitcoin State Verification (Lantr)

### Watchtower Architecture

Watchtowers are permissionless participants who maintain Bitcoin blockchain state on Cardano. They serve as the critical link between the Bitcoin and Cardano networks, ensuring that BiFrost has accurate, up-to-date information about the Bitcoin blockchain.

**Key Design Principles:**

* **Permissionless Participation**: Anyone can become a watchtower at any time without registration, bonding, or approval. This ensures the system cannot be censored or controlled by a small group.
* **Competitive Model**: Multiple watchtowers compete to submit the most accurate chain of blocks. If one watchtower submits invalid or stale data, others can immediately challenge with the correct chain.
* **Economic Incentives**: Watchtowers are rewarded for posting valid blocks, creating a natural incentive for honest and timely participation.

### Core Watchtower Responsibilities

1. **Monitor Bitcoin Network**: Watchtowers continuously track the Bitcoin blockchain for new blocks as they are mined.

2. **Submit Block Headers**: When new Bitcoin blocks are found, watchtowers submit the 80-byte block headers to the Binocular Oracle smart contract on Cardano. These headers contain all information needed to verify Bitcoin consensus rules.

3. **Compete for Accuracy**: Multiple watchtowers naturally compete to submit the most accurate chain. If a watchtower submits headers from an invalid or weaker fork, other watchtowers can challenge by submitting the correct chain with higher cumulative proof-of-work.

4. **Maintain Oracle Liveness**: Watchtowers ensure the Oracle never becomes stale by continuously updating it with the latest Bitcoin state. This is essential for timely peg-in and peg-out processing.

### BiFrost-Specific Watchtower Duties

Beyond maintaining general Bitcoin state, watchtowers perform specialized duties for the BiFrost bridge:

**Deposit Detection**

* Monitor the Treasury Taproot address for incoming Bitcoin transactions
* Match detected deposits to pending PegInRequest UTxOs on Cardano
* Track transaction confirmations as blocks are added

**Proof Submission for Peg-ins**

* Once a Bitcoin deposit transaction reaches the required confirmation threshold (100 Bitcoin blocks plus 200 minutes of challenge period), watchtowers construct Merkle proofs
* These proofs demonstrate: (1) the transaction exists in a specific block, and (2) that block is confirmed in the Binocular Oracle
* Submitting valid proofs triggers fBTC minting for the depositor

**Peg-out Monitoring**

TODO

**Anomaly Detection**

* Continuously verify that Treasury BTC balance matches or exceeds circulating fBTC supply
* Alert the system if invariants are violated
* Trigger failover mechanisms if SPO signing stalls or quorum is lost
* TODO

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
For BiFrost operations, the Oracle provides data for Watchtowers to construct proofs that:

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

BiFrost's watchtower design relies on a minimal trust assumption: only one honest watchtower needs to exist for the system to function correctly.

**Why This Works:**

* If all active watchtowers collude to censor or submit invalid data, any user can spin up their own watchtower
* The permissionless design means no one can prevent new watchtowers from joining
* Honest watchtowers are economically incentivized to challenge invalid submissions

**Censorship Resistance:**

* A user wanting to peg-in or peg-out can always become a watchtower themselves
* They can then submit the necessary Bitcoin blocks and proofs for their own transactions
* This ensures BiFrost remains operational even in adversarial conditions

This 1-of-n honesty assumption is significantly weaker than typical bridge trust models that require trusting a majority or specific set of operators.

## References

[1] Nemish, Alexander. "Binocular: A Trustless Bitcoin Oracle for Cardano." 2025. <https://github.com/lantr-io/binocular/blob/main/pdfs/Whitepaper.pdf>

[2] Komlo, C. and Goldberg, I. "FROST: Flexible Round-Optimized Schnorr Threshold Signatures." RFC 9591, IETF, 2024. <https://datatracker.ietf.org/doc/rfc9591/>

[3] Wuille, P. et al. "BIP340: Schnorr Signatures for secp256k1." Bitcoin Improvement Proposal, 2020. <https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki>

[4] Wuille, P. et al. "BIP341: Taproot: SegWit version 1 spending rules." Bitcoin Improvement Proposal, 2020. <https://github.com/bitcoin/bips/blob/master/bip-0341.mediawiki>

[5] Pearson, Luke et. al., *Plonkup: Reconciling Plonk with plookup* (2022).

[6] *zkFold Symbolic* (github repository): https://github.com/zkFold/symbolic/tree/main/symbolic-base/src/ZkFold/Protocol/Plonkup

[7] *zkFold-Cardano* (github repository): https://github.com/zkFold/zkfold-cardano/tree/main/zkfold-cardano/src/ZkFold/Cardano

[8] *Haskell Merkle Patricia Forestry* (github repository): https://github.com/zkFold/haskell-merkle-patricia-forestry

[9] *Bifrost On-Chain Validators* (Aiken): https://github.com/FluidTokens/ft-bifrost-bridge/tree/main/onchain/validators
