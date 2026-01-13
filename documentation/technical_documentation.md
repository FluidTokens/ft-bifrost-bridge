# Bifrost documentation
## Architecture overview
Bifrost is an optimistic bridge that leverages Cardano Stake Pools high decentralization level to secure the peg-ins and peg-outs from and to other UTxO blockchains like Bitcoin, Dogecoin and Litecoin.
Because of the limited scripting capabilities of these blockchains, in recent years different bridging alternatives have been proposed. The current most known alternatives are FROST signatures of a small set of external nodes (Stacks), BitVM optimistic behaviour with 1-of-n honesty assumption with limited availability (Cardinal, Citrea) and Watchtower multisignature behaviour (Rosen Bridge).

Bifrost takes inspiration from all these solutions, but this time Cardano is used as a core component to guarantee the security and uncensorability of the user’s actions.

It then becomes easier to connect Cardano, a UTXO blockchain with smart contracts, to other smart contract blockchains and Layer 2s, making Cardano the central component of a safe bridging process.

The Cardano SPOs collectively become the responsible custodians of bridged assets on the original blockchain. For example, SPOs keep and manage the locked BTC on the Bitcoin side, while its bridged version bBTC circulates freely on Cardano.

Bifrost has been built to ensure security and availability, not speed or low costs.
In fact, Bifrost operations may take up to 1 or more Cardano epochs (an epoch is currently equals to 5 days), as coordination and heavy operations must be executed in the correct order.
The peg-ins and peg-outs also have to compensate for the work of all actors involved in Bifrost.
Therefore Bifrost should be used to move big amounts of liquidity in and out of Cardano and not for intra-day retail/small business operations.
Once big amounts of liquidity have been bridged to Cardano, for this type of smaller and frequent peg-ins and peg-outs it is possible to safely use services like FluidToken FluidSwaps, cutting costs and execution time without sacrificing security.

The security of Bifrost is guaranteed by SPOs participation: for a strong and reliable bridge, most of the top SPOs by delegation must participate in the protocol.

## Components
Bifrost setup is made by the following components:
* Cardano: the destination blockchain where bridged assets can safely participate in DeFi activities.
* Source blockchain: the original blockchain that contains assets to bridge to Cardano, like Bitcoin, Dogecoin and Litecoin.
* Depositors: users that lock their assets on the source blockchain to mint them on Cardano.
* Withdrawers: users that burn their bridged assets on Cardano to unlock them on the proper source blockchain.
* Cardano Stake Pool Operators (SPOs): Cardano nodes that have delegated stake by Cardano users and that participate in Cardano consensus, guaranteeing its security.
* Multisig treasury: a script address on the source blockchain that holds all the bridged assets and it’s protected by a multisignature that only SPOs together can use. Each SPO has a weight equal to its delegation and a specific threshold of SPOs signature must be reached to spend/move the multisig treasury.
* Watchtowers: an open and always dynamic set of actors who have visibility on both Cardano and the source blockchain. Their only duty is to compete to post the most truthful source blockchain chain of blocks. This allows Cardano to know what’s happening on the source blockchain. Anyone can become a Watchtower at any moment.

Bifrost logic is fully encapsulated in the following solutions:
* SPOs program: this code must run along with the usual SPO stack. It gives SPOs the ability to coordinate to sign Bitcoin transactions and the ability to see and interact with the needed Cardano smart contracts.
* Watchtower program: watchtowers run this software on top of source blockchain and Cardano nodes to be able to properly post the best chain of blocks to Cardano.
* Cardano smart contracts:
    * spos_registry.ak: SPOs that participate in Bifrost need to register here for the next upcoming epoch. The registry is a on-chain linked list ordered by SPOs edcs key and each node also contains the SPO secp key that will be used to sign source blockchain transactions.
    * watchtower.ak: The watchtowers (anyone) post the best chain of blocks here, other watchtowers eventually challenge it by posting a better version and the winner gets rewarded by the end of the availability window.
    * peg_in.ak: when a depositor wants to bridge his assets, he starts by minting a unique NFT and by locking it here. Burning this NFT plus the proof that the source blockchain locking transaction happened, allow the depositor to mint the bridged assets on Cardano
    * peg_out.ak: when a withdrawer wants to unlock the bridged assets on the proper source blockchain, he starts the peg-out process sending his bridged assets to this smart contract along with a freshly minted unique NFT in the same eUTxO. A proof that the source blockchain unlocking transaction happened, allows the withdrawer to burn this eUTxO and retrieve the min_utxo locked ADA. 
    * bridged_asset.ak: At the end of peg-ins, it allows to mint the bridged version of the source blockchain assets; at the end of peg-outs it allows to burn these bridged assets.

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
